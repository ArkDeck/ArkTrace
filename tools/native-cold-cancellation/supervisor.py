"""One bounded, explicitly pinned current SDK acceptance operation.

No shell, signal, shared-cache recovery, device, or GUI action is provided.
The caller registers an original absolute deadline before creating the packet.
"""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import stat
import threading
import time

from controller import Controller
from hash_budget import HashBudget, HashPolicy
from kernel_observer import KernelObserver
from namespace_guard import open_owned_namespace
from ownership import digest, identity
from protocol import Decoder, canonical_nonce, unique_pairs
from source_guard import open_owned_source
from wire_preflight import WireBudget

PACKET_KEYS = {"schemaVersion", "mode", "nonce", "consumer", "consumerSHA256",
               "swiftSource", "swiftSourceSHA256", "bridge", "bridgeSHA256",
               "sdkLibrary", "sdkLibrarySHA256", "input", "evidenceDirectory"}
INPUT_KEYS = {"namespace", "source", "expectedSourceByteCount", "expectedSourceDevice",
              "expectedSourceInode", "helper", "helperSHA256", "parser", "parserIdentity",
              "publisher", "controlNonce"}


class AdmissionError(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise AdmissionError(code)


def absolute_path(value):
    require(type(value) is str and "\0" not in value and value.startswith("/") and
            len(os.fsencode(value)) <= 4096 and os.path.normpath(value) == value and
            "//" not in value and not value.endswith("/"), "packet_path_invalid")
    return value


def sha256(value):
    require(type(value) is str and len(value) == 64 and all(char in "0123456789abcdef" for char in value),
            "packet_digest_invalid")
    return value


def read_document(path, budget, cancelled):
    absolute_path(path)
    info = os.lstat(path)
    require(0 < info.st_size <= 65536, "packet_byte_limit")
    with open_owned_source(path, info.st_size, info.st_dev, info.st_ino, hash_budget=budget) as held:
        data = bytearray()
        while len(data) < info.st_size:
            amount = budget.next_read_size(len(data), info.st_size)
            block = os.read(held.descriptor, amount)
            budget.charge_read(len(block), amount)
            budget.checkpoint()
            require(bool(block), "packet_changed_during_read")
            data.extend(block)
        held.revalidate()
    wire = WireBudget(budget.policy.absolute_deadline_ns, cancelled)
    wire.scan(bytes(data))
    decoded = json.loads(data, object_pairs_hook=unique_pairs,
                         parse_constant=lambda _: (_ for _ in ()).throw(AdmissionError("packet_nonfinite")))
    wire.check_decoded(decoded)
    return decoded, hashlib.sha256(data).hexdigest()


def validate_packet(packet):
    require(type(packet) is dict and set(packet) == PACKET_KEYS, "packet_shape_invalid")
    require(type(packet["schemaVersion"]) is int and packet["schemaVersion"] == 1,
            "packet_schema_invalid")
    require(packet["mode"] in ("guard", "normal") and type(packet["mode"]) is str,
            "packet_mode_invalid")
    require(canonical_nonce(packet["nonce"]), "packet_nonce_invalid")
    for field in ("consumer", "swiftSource", "bridge", "sdkLibrary", "input", "evidenceDirectory"):
        absolute_path(packet[field])
    for field in ("consumerSHA256", "swiftSourceSHA256", "bridgeSHA256", "sdkLibrarySHA256"):
        sha256(packet[field])


def pin(path, expected, budget):
    actual, held = digest(path, hash_budget=budget)
    require(actual == expected, "artifact_pin_mismatch")
    return {"sha256": actual, "identity": list(held)}, held


class GuardReader:
    def __init__(self, nonce, budget, cancelled):
        self.decoder = Decoder(nonce, mode="guard", absolute_deadline_ns=budget.policy.absolute_deadline_ns,
                               cancelled=cancelled)
        self.buffer = bytearray()
        self.records = 0
        self.result = None
        self.input_result = None

    def stdout(self, chunk, port):
        require(type(chunk) is bytes and 0 < len(chunk) <= 8192, "guard_quantum_invalid")
        self.buffer.extend(chunk)
        while b"\n" in self.buffer:
            newline = self.buffer.index(10)
            require(newline <= 65536 and self.records < 256, "guard_record_limit")
            line = bytes(self.buffer[:newline])
            del self.buffer[:newline + 1]
            record = self.decoder.feed(line)
            self.records += 1
            if record["event"] == "protocol.guard.result":
                self.result = record
            if record["event"] == "protocol.guard.inputResult":
                self.input_result = record
        require(len(self.buffer) <= 65536, "guard_line_limit")

    def tick(self, port):
        # Guard producer generates no Engine/open/cancel operation or controls.
        self.decoder._checkpoint()

    def finish(self):
        require(not self.buffer, "guard_unterminated_tail")
        terminal = self.decoder.finish()
        require(self.result is not None and self.result["passed"] is True and
                self.input_result is not None and self.input_result["passed"] is True, "guard_incomplete")
        return {"terminal": terminal, "records": self.records, "protocolCases": self.result["caseCount"],
                "inputCases": self.input_result["caseCount"], "EngineCalls": 0, "TaskCancelCalls": 0,
                "actualCancellationValidated": False}


def execute(packet, budget, cancelled, validate_only, report):
    validate_packet(packet)
    report.update({"schemaVersion": 1, "mode": packet["mode"], "nonce": packet["nonce"],
              "originalDeadlineNs": budget.policy.absolute_deadline_ns,
              "passed": False, "actualConsumerLaunched": False,
              "wholeMacOSAcceptance": False, "pins": {}})
    identities = {}
    for name, path_field, digest_field in (("consumer", "consumer", "consumerSHA256"),
                                         ("swiftSource", "swiftSource", "swiftSourceSHA256"),
                                         ("bridge", "bridge", "bridgeSHA256"),
                                         ("sdk", "sdkLibrary", "sdkLibrarySHA256")):
        report["pins"][name], identities[name] = pin(packet[path_field], packet[digest_field], budget)
    require(identities["consumer"][3] & 0o111 != 0, "consumer_not_executable")
    folder = Path(packet["evidenceDirectory"])
    info = folder.lstat()
    require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == os.getuid(),
            "private_evidence_directory_required")
    for name in ("producer.stdout.log", "producer.stderr.log", "supervisor-report.json"):
        require(not os.path.lexists(folder / name), "evidence_output_exists")
    with ExitStack() as held:
        if packet["mode"] == "normal":
            inputs, report["inputSHA256"] = read_document(packet["input"], budget, cancelled)
            require(type(inputs) is dict and set(inputs) == INPUT_KEYS, "normal_input_shape")
            require(inputs["controlNonce"] == packet["nonce"], "normal_nonce_mismatch")
            for key in ("namespace", "source", "helper", "parser"):
                absolute_path(inputs[key])
            for key in ("expectedSourceByteCount", "expectedSourceDevice", "expectedSourceInode"):
                require(type(inputs[key]) is int and 0 < inputs[key] < 1 << 64, "normal_source_identity_invalid")
            require(type(inputs["parserIdentity"]) is dict, "normal_parser_identity_invalid")
            executable_pins = {"consumer": {"path": packet["consumer"], "sha256": packet["consumerSHA256"]},
                               "helper": {"path": inputs["helper"], "sha256": sha256(inputs["helperSHA256"])},
                               "parser": {"path": inputs["parser"], "sha256": sha256(inputs["parserIdentity"].get("binarySHA256"))}}
            for role in ("helper", "parser"):
                spec = executable_pins[role]
                report["pins"][role], _ = pin(spec["path"], spec["sha256"], budget)
            namespace = held.enter_context(open_owned_namespace(inputs["namespace"], hash_budget=budget))
            namespace.require_empty()
            source = held.enter_context(open_owned_source(inputs["source"], inputs["expectedSourceByteCount"],
                inputs["expectedSourceDevice"], inputs["expectedSourceInode"], hash_budget=budget))
            report["sourceIdentity"] = list(source.identity)
            report["sourceContentReadByPreflight"] = False
            observer = KernelObserver(packet["bridge"], packet["bridgeSHA256"], executable_pins, budget)
            controller = Controller(packet["nonce"], observer, source, identities["consumer"],
                                    namespace.require_empty, budget, cancelled)
            stdout, tick = controller.on_stdout_bytes, controller.on_tick
            argv = [packet["consumer"], packet["input"]]
        else:
            namespace = held.enter_context(open_owned_namespace(packet["input"], hash_budget=budget))
            from protocol_fixtures import admit
            report["guardFixtures"] = admit(namespace, packet["input"], budget)
            controller = GuardReader(packet["nonce"], budget, cancelled)
            stdout, tick = controller.stdout, controller.tick
            argv = [packet["consumer"], "--protocol-guard", packet["nonce"], packet["input"]]
        if validate_only:
            report.update(preflightPassed=True, actualConsumerLaunched=False, EngineCalls=0, TaskCancelCalls=0)
            return report
        from interactive_process import run_interactive
        from bounded_log_pin import pin as pin_log
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
        result = run_interactive(str(folder), "producer", argv, environment,
                                 budget.policy.absolute_deadline_ns, 131072, 8192, stdout, tick)
        # Only the bounded typed projection reaches JSON serialization. A
        # rejected receipt stays unknown; raw dictionaries are not a fallback.
        report["transport"] = None
        report["actualConsumerLaunched"] = result.direct_child is not None
        if packet["mode"] == "normal":
            report["admissionWorkerJoined"] = controller.finish_worker()
            report["controllerObservations"] = controller.diagnostics()
            require(report["admissionWorkerJoined"], "admission_worker_unjoined")
            if controller.witness is not None:
                report["terminalKernelIdentities"] = observer.terminal_identities(controller.witness)
            report["namespaceAfter"] = namespace.cleanup_snapshot()
        from receipt_contract import validate_interactive_receipt
        typed_transport = validate_interactive_receipt(result.receipt,
            absolute_deadline_ns=budget.policy.absolute_deadline_ns, cancelled=cancelled)
        report["transportReceiptContractValidated"] = True
        from receipt_report import project_receipt
        report["transport"] = project_receipt(typed_transport,
            absolute_deadline_ns=budget.policy.absolute_deadline_ns, cancelled=cancelled)
        report["transportReceiptProjectionValidated"] = True
        report["logs"] = {stream: pin_log(folder / ("producer." + stream + ".log"), hash_budget=budget,
                            max_log_file_bytes=limit) for stream, limit in (("stdout", 131072), ("stderr", 8192))}
        report["producer"] = controller.finish()
        report["passed"] = report["transport"]["passed"] is True
        if packet["mode"] == "normal":
            report["passed"] = (report["passed"] and report["producer"]["measuredCancellationPassed"] and
                report["producer"]["publicRetainedResultBytesZero"] and report["admissionWorkerJoined"] and
                report["namespaceAfter"]["cleanupLayoutClean"] and
                len(report.get("terminalKernelIdentities", [])) == 3 and
                all(row["absence_observed"] for row in report["terminalKernelIdentities"]))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packet")
    parser.add_argument("--deadline-ns", required=True, type=int)
    parser.add_argument("--validate-only", action="store_true")
    options = parser.parse_args()
    cancellation = threading.Event()
    cancelled = cancellation.is_set
    budget = HashBudget(HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024, 65536,
                                  options.deadline_ns), cancelled)
    packet = None
    output_identity = None
    report = {"schemaVersion": 1, "passed": False, "wholeMacOSAcceptance": False,
              "originalDeadlineNs": options.deadline_ns}
    try:
        packet, packet_sha = read_document(options.packet, budget, cancelled)
        validate_packet(packet)
        with open_owned_namespace(packet["evidenceDirectory"], hash_budget=budget) as output_namespace:
            info = os.fstat(output_namespace.descriptor)
            output_identity = (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
        execute(packet, budget, cancelled, options.validate_only, report)
        report["packetSHA256"] = packet_sha
    except Exception as error:
        report.update(passed=False,
                      failureCode=getattr(error, "code", None) or "supervisor_admission_or_execution_failed")
    report["observedHashReadBytes"] = budget.bytes_read_total
    report["observedHashReadCalls"] = budget.read_calls
    report["finishedMonotonicNs"] = time.monotonic_ns()
    encoded = (json.dumps(report, sort_keys=True, indent=2) + "\n").encode()
    require(len(encoded) <= 65536, "report_byte_limit")
    if output_identity is not None:
        directory = os.open(packet["evidenceDirectory"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            info = os.fstat(directory)
            require((info.st_dev, info.st_ino, info.st_mode, info.st_uid) == output_identity,
                    "report_directory_changed")
            descriptor = os.open("supervisor-report.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                 os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
            with os.fdopen(descriptor, "wb") as output:
                output.write(encoded)
        finally:
            os.close(directory)
    print(encoded.decode(), end="")
    return 0 if report.get("passed") or options.validate_only and report.get("preflightPassed") else 2


if __name__ == "__main__":
    raise SystemExit(main())
