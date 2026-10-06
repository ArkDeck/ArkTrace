"""Owner-scoped process observations for the real SDK cancellation supervisor.

Only the direct Popen and its bounded descendants are enumerated. Repeated
snapshots do not claim atomicity, native wait statuses, or complete peak RSS.
"""
import ctypes as C
import errno
import os
import subprocess
import time

from child_count import decode_count
from ownership import KernelOwnership, OwnershipError, Row, digest, identity


class KernelObserver:
    def __init__(self, bridge_path, bridge_sha256, executable_pins, hash_budget):
        self.hash_budget = hash_budget
        actual, self.bridge_identity = digest(bridge_path, hash_budget=hash_budget)
        if actual != bridge_sha256:
            raise OwnershipError("observer bridge pin mismatch")
        self.bridge_path = bridge_path
        self.bridge_sha256 = bridge_sha256
        self.executable_pins = executable_pins
        self.bridge = C.CDLL(bridge_path, use_errno=True)
        self.bridge.pf_identity_detail.argtypes = [C.c_int, C.POINTER(Row), C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.bridge.pf_identity_detail.restype = C.c_int
        self.bridge.pf_abi_fact.argtypes = [C.c_int]
        self.bridge.pf_abi_fact.restype = C.c_uint64
        facts = [2, C.sizeof(Row), Row.pid.offset, Row.ppid.offset, Row.pgid.offset,
                 Row.state.offset, Row.sec.offset, Row.usec.offset, Row.rss.offset,
                 Row.status.offset, 5, Row.rss_status.offset, Row.error.offset,
                 Row.rss_error.offset, C.alignment(Row)]
        if C.sizeof(Row) != 56 or [self.bridge.pf_abi_fact(i) for i in range(15)] != facts:
            raise OwnershipError("observer ABI mismatch")
        self.bridge.arktrace_memory.argtypes = [C.c_int, C.POINTER(C.c_uint64), C.POINTER(C.c_uint64),
                                               C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.bridge.arktrace_memory.restype = C.c_int
        self.bridge.arktrace_rusage_fact.argtypes = [C.c_int]
        self.bridge.arktrace_rusage_fact.restype = C.c_uint64
        self.rusage_facts = tuple(self.bridge.arktrace_rusage_fact(i) for i in range(4))
        if self.rusage_facts[0] != 2 or not (0 < self.rusage_facts[2] < self.rusage_facts[3] < self.rusage_facts[1] <= 4096):
            raise OwnershipError("resource ABI unavailable")
        self.libproc = C.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_listchildpids.argtypes = [C.c_int, C.c_void_p, C.c_int]
        self.libproc.proc_listchildpids.restype = C.c_int
        self.libproc.proc_pidpath.argtypes = [C.c_int, C.c_void_p, C.c_uint32]
        self.libproc.proc_pidpath.restype = C.c_int
        self.enumerations = []

    def checkpoint(self):
        self.hash_budget.checkpoint()
        if identity(self.bridge_path) != self.bridge_identity:
            raise OwnershipError("observer bridge changed")

    def children(self, pid):
        self.checkpoint()
        if type(pid) is not int or not 0 < pid <= 2147483647:
            raise OwnershipError("positive PID required")
        if len(self.enumerations) >= 1024:
            raise OwnershipError("enumeration record budget")
        array = (C.c_int32 * 8)()
        before = time.monotonic_ns()
        C.set_errno(0)
        count = self.libproc.proc_listchildpids(pid, array, C.sizeof(array))
        error = C.get_errno()
        after = time.monotonic_ns()
        self.checkpoint()
        result = decode_count(count, error, array)
        self.enumerations.append({"parentPID": pid, "before_ns": before, "after_ns": after,
                                  "raw_count": count, "raw_errno": error, "capacity": 8,
                                  "children": result})
        return result

    def discover(self, child):
        self.checkpoint()
        if type(child) is not subprocess.Popen or child.poll() is not None:
            raise OwnershipError("live direct child required")
        helpers = self.children(child.pid)
        if len(helpers) != 1:
            return None
        parsers = self.children(helpers[0])
        if len(parsers) != 1:
            return None
        if self.children(parsers[0]):
            raise OwnershipError("unexpected parser descendants")
        return helpers[0], parsers[0]

    def consumer_bootstrap(self, child, pinned_path, pinned_identity):
        """Authenticate the direct consumer before permitting Engine.create.

        Executable bytes are pinned by the caller before spawn. This checks
        their same held/path identity and actual kernel path, not stdout.
        """
        self.checkpoint()
        if type(child) is not subprocess.Popen or child.poll() is not None:
            raise OwnershipError("live direct consumer required")

        def observe(pid):
            row, raw, error = Row(), C.c_int(), C.c_int()
            result = self.bridge.pf_identity_detail(pid, C.byref(row), C.byref(raw), C.byref(error))
            self.checkpoint()
            if (result != 0 or raw.value <= 0 or error.value != 0 or row.status != 0 or
                    row.pid != pid or row.state == 5 or row.sec == 0 or row.usec >= 1_000_000):
                raise OwnershipError("bootstrap kernel birth unavailable")
            return (row.pid, row.ppid, row.pgid, row.sec, row.usec)

        before = observe(child.pid)
        if before[1] != os.getpid() or before[2] != child.pid:
            raise OwnershipError("direct consumer parent/group mismatch")
        buffer = C.create_string_buffer(4096)
        raw = self.libproc.proc_pidpath(child.pid, buffer, len(buffer))
        self.checkpoint()
        if raw <= 0 or os.fsdecode(buffer.value) != pinned_path or identity(pinned_path) != pinned_identity:
            raise OwnershipError("bootstrap kernel executable mismatch")
        if observe(child.pid) != before or child.poll() is not None:
            raise OwnershipError("bootstrap consumer birth changed")
        return {"kernelBirth": list(before), "kernelExecutablePathMatched": True,
                "executableIdentityMatched": True, "completeForestProven": False}

    def exact_tree(self, witness):
        self.checkpoint()
        if type(witness) is not KernelOwnership or not witness.revalidate():
            return False
        _, root, helper, parser = witness.pids
        expected = ([helper], [parser], [])
        actual = tuple(self.children(pid) for pid in (root, helper, parser))
        self.checkpoint()
        return actual == expected and witness.revalidate()

    def admit(self, child):
        descendants = self.discover(child)
        if descendants is None:
            return None
        witness = KernelOwnership.admit(child, *descendants, self.bridge_path,
                                        self.bridge_sha256, self.executable_pins,
                                        hash_budget=self.hash_budget)
        if not self.exact_tree(witness):
            raise OwnershipError("complete enumerated tree changed")
        return witness

    def memory(self, witness, maximum_total_bytes):
        if type(maximum_total_bytes) is not int or not 0 < maximum_total_bytes <= 1073741824:
            raise OwnershipError("memory policy required")
        if not self.exact_tree(witness):
            raise OwnershipError("resource birth admission changed")
        observations = []
        for pid in witness.pids[1:]:
            self.checkpoint()
            resident, footprint = C.c_uint64(), C.c_uint64()
            raw, error = C.c_int(), C.c_int()
            before = time.monotonic_ns()
            result = self.bridge.arktrace_memory(pid, C.byref(resident), C.byref(footprint),
                                                 C.byref(raw), C.byref(error))
            after = time.monotonic_ns()
            self.checkpoint()
            if result != 0 or raw.value != 0 or error.value != 0:
                raise OwnershipError("resource observation unavailable")
            observations.append({"pid": pid, "before_ns": before, "after_ns": after,
                                 "resident_bytes": resident.value, "physical_footprint_bytes": footprint.value,
                                 "raw_return": raw.value, "raw_errno": error.value})
        if not self.exact_tree(witness):
            raise OwnershipError("resource birth changed after sample")
        resident = sum(row["resident_bytes"] for row in observations)
        footprint = sum(row["physical_footprint_bytes"] for row in observations)
        if max(resident, footprint) > maximum_total_bytes:
            raise OwnershipError("sampled memory budget exceeded")
        return {"observations": observations, "sum_resident_bytes": resident,
                "sum_physical_footprint_bytes": footprint, "ceiling_bytes": maximum_total_bytes,
                "complete_peak_proven": False, "atomic_snapshot_proven": False}

    def terminal_identities(self, witness):
        """Report only individually observed absence, with original births kept.

        proc_pidinfo failure without ESRCH is unknown, including an opaque
        zombie/permission failure. It cannot certify waitpid reaping.
        """
        self.checkpoint()
        records = []
        for original in witness.rows[1:]:
            self.checkpoint()
            row, raw, error = Row(), C.c_int(), C.c_int()
            before = time.monotonic_ns()
            result = self.bridge.pf_identity_detail(original[0], C.byref(row), C.byref(raw), C.byref(error))
            after = time.monotonic_ns()
            self.checkpoint()
            records.append({"pid": original[0], "registered_birth": list(original),
                            "before_ns": before, "after_ns": after, "raw_return": raw.value,
                            "raw_errno": error.value, "bridge_return": result,
                            "absence_observed": result == -1 and raw.value == 0 and error.value == errno.ESRCH,
                            "native_wait_status_proven": False})
        return records
