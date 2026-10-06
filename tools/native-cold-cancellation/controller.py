"""MAIN-owned typed IPC orchestration, separate from byte transport.

The one daemon admission worker does cooperative bounded executable hashing.
Callbacks never wait for it; an unjoined worker is reported, not hidden. No
signal is issued here. A failed transport closes input for SDK-owned cleanup.
"""
import os
import queue
import subprocess
import threading
import time

from clock_admission import ClockAdmission
from kernel_observer import KernelObserver
from protocol import Decoder
from source_guard import HeldSource


class SupervisorError(ValueError):
    pass


class Controller:
    def __init__(self, nonce, observer, source, consumer_identity,
                 namespace_preflight, hash_budget, cancelled):
        if (type(source) is not HeldSource or source.budget is not hash_budget or
                type(observer) is not KernelObserver or observer.hash_budget is not hash_budget or
                not callable(cancelled) or not callable(namespace_preflight)):
            raise SupervisorError("shared_source_admission_required")
        self.nonce = nonce
        self.observer = observer
        self.source = source
        self.consumer_identity = consumer_identity
        self.namespace_preflight = namespace_preflight
        self.budget = hash_budget
        self.decoder = Decoder(nonce, absolute_deadline_ns=hash_budget.policy.absolute_deadline_ns,
                               cancelled=cancelled)
        self.clock = ClockAdmission(hash_budget)
        self.buffer = bytearray()
        self.offered_bytes = 0
        self.record_count = 0
        self.failure_code = None
        self.bootstrap = None
        self.progress = None
        self.result = None
        self.retained = None
        self.terminal_command = None
        self.witness = None
        self.memory = None
        self.cancel_admission = None
        self.attempts = 0
        self.worker = None
        self.outcome = None

    def fail(self, code):
        if self.failure_code is None:
            self.failure_code = code
        raise SupervisorError(code)

    def check(self, port):
        # Import only when the reviewed transport has been integrated.
        from interactive_process import ControlPort
        self.budget.checkpoint()
        if (type(port) is not ControlPort or type(port.direct_child) is not subprocess.Popen or
                port.absolute_deadline_ns != self.budget.policy.absolute_deadline_ns):
            self.fail("owned_transport_original_deadline_required")

    def on_stdout_bytes(self, chunk, port):
        self.check(port)
        try:
            if type(chunk) is not bytes or not 0 < len(chunk) <= 8192:
                self.fail("stdout_quantum_invalid")
            self.offered_bytes += len(chunk)
            if self.offered_bytes > 131072:
                self.fail("stdout_stream_limit")
            self.buffer.extend(chunk)
            while b"\n" in self.buffer:
                self.budget.checkpoint()
                newline = self.buffer.index(10)
                if newline > 65536 or self.record_count >= 256:
                    self.fail("stdout_record_limit")
                line = bytes(self.buffer[:newline])
                del self.buffer[:newline + 1]
                record = self.decoder.feed(line)
                self.record_count += 1
                self.event(record, port)
                self.budget.checkpoint()
            if len(self.buffer) > 65536:
                self.fail("stdout_line_limit")
            self.budget.checkpoint()
        except Exception:
            if self.failure_code is None:
                self.failure_code = "stdout_protocol_admission_failed"
            raise

    def event(self, record, port):
        event = record["event"]
        if event == "consumer.bootstrap":
            if record["pid"] != port.direct_child.pid or record["parentPID"] != os.getpid():
                self.fail("bootstrap_direct_child_mismatch")
            spec = self.observer.executable_pins["consumer"]
            self.bootstrap = self.observer.consumer_bootstrap(port.direct_child, spec["path"], self.consumer_identity)
            self.clock.begin()
            port.send_control("calibrate", self.nonce)
        elif event == "clock.calibration":
            self.clock.receive(record)
            self.source.revalidate()
            self.namespace_preflight()
            port.send_control("start", self.nonce)
        elif event == "open.progress":
            self.progress = record if record["stage"] == "parsing" else None
        elif event == "open.returned" and self.terminal_command is None:
            self.failure_code = self.failure_code or "open_finished_before_cancel_admission"
            port.send_control("join", self.nonce)
            self.terminal_command = "join"
        elif event == "retained.beforeShutdown":
            self.retained = record
        elif event == "consumer.result":
            self.result = record

    def start_worker(self, child):
        self.attempts += 1
        self.outcome = queue.Queue(maxsize=1)

        def admission():
            try:
                witness = self.observer.admit(child)
                memory = None if witness is None else self.observer.memory(witness, 512 * 1024 * 1024)
                result = (witness, memory, None)
            except Exception:
                result = (None, None, "kernel_resource_admission_failed")
            self.outcome.put_nowait(result)

        self.worker = threading.Thread(target=admission, name="arktrace-cancel-admission", daemon=True)
        self.worker.start()

    def on_tick(self, port):
        self.check(port)
        try:
            if self.terminal_command is not None or self.progress is None:
                return
            if self.worker is None:
                self.start_worker(port.direct_child)
                return
            if self.worker.is_alive():
                return
            self.worker.join(timeout=0)
            witness, memory, failure = self.outcome.get_nowait()
            if failure is not None:
                self.fail(failure)
            if witness is None:
                if self.attempts >= 8:
                    self.fail("bounded_descendant_discovery_exhausted")
                self.worker = None
                return
            self.witness, self.memory = witness, memory
            self.source.revalidate()
            if not self.observer.exact_tree(witness):
                self.fail("cancel_tree_changed")
            age = self.clock.progress_age_upper_ns(self.progress)
            command = self.decoder.authorize_cancel(witness)
            if command != "cancel:" + self.nonce + "\n":
                self.fail("cancel_command_mismatch")
            # Kernel revalidation must not make an earlier freshness sample
            # authoritative after it has aged out.
            age = self.clock.progress_age_upper_ns(self.progress)
            admitted = time.monotonic_ns()
            port.send_control("cancel", self.nonce)
            self.terminal_command = "cancel"
            self.cancel_admission = {"beforeQueueMonotonicNs": admitted,
                                     "parsingAgeUpperNs": age,
                                     "registeredKernelBirths": [list(row) for row in witness.rows],
                                     "directOwnedGroups": list(witness.pids[1:]),
                                     "stdoutGrantedKernelAuthority": False}
            self.budget.checkpoint()
        except Exception:
            if self.failure_code is None:
                self.failure_code = "cancel_admission_failed"
            if self.terminal_command is None:
                self.decoder.cancel_authorized = False
            raise

    def diagnostics(self):
        """Already observed bounded facts; no new IO or time authority."""
        return {"recordCount": self.record_count, "decoderInvalid": self.decoder.invalid,
                "lastStage": self.decoder.stage, "failureCode": self.failure_code,
                "terminalCommand": self.terminal_command, "bootstrap": self.bootstrap,
                "cancelAdmission": self.cancel_admission, "resourceSample": self.memory,
                "acceptedConsumerResult": self.result, "acceptedRetainedRecord": self.retained,
                "workerAttempts": self.attempts, "completeForestProven": False,
                "completePeakRSSProven": False, "wholeMacOSAcceptance": False}

    def finish_worker(self):
        if self.worker is None:
            return True
        remaining = max(0, (self.budget.policy.absolute_deadline_ns - time.monotonic_ns()) / 1_000_000_000)
        self.worker.join(timeout=remaining)
        return not self.worker.is_alive()

    def finish(self):
        self.budget.checkpoint()
        if self.buffer:
            self.fail("stdout_unterminated_tail")
        terminal = self.decoder.finish()
        measured = (self.terminal_command == "cancel" and self.cancel_admission is not None and
                    self.result is not None and self.result["passed"] is True)
        retained_zero = self.retained is not None and self.retained["bytes"] == 0
        return {"terminal": terminal, "measuredCancellationPassed": measured,
                "publicRetainedResultBytesZero": retained_zero, "recordCount": self.record_count,
                "failureCode": self.failure_code, "terminalCommand": self.terminal_command,
                "bootstrap": self.bootstrap, "clock": self.clock.receipt(),
                "cancelAdmission": self.cancel_admission, "resourceSample": self.memory,
                "privateCountsProven": False, "completeForestProven": False,
                "completePeakRSSProven": False, "wholeMacOSAcceptance": False}
