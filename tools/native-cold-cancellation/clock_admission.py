"""Conservative freshness admission from one actual IPC clock handshake.

The interval is an observation, not proof of clock equivalence or later drift.
Swift-to-Swift cancellation duration remains the consumer's separate metric.
"""
import time

from hash_budget import HashBudget
from ownership import OwnershipError
from protocol import CLOCK


class ClockAdmission:
    def __init__(self, hash_budget):
        if type(hash_budget) is not HashBudget:
            raise OwnershipError("clock operation budget required")
        self.budget = hash_budget
        self.started_ns = None
        self.received_ns = None
        self.offset_lower_ns = None
        self.offset_upper_ns = None

    def begin(self):
        self.budget.checkpoint()
        if self.started_ns is not None:
            raise OwnershipError("clock handshake already started")
        self.started_ns = time.monotonic_ns()
        return self.started_ns

    def receive(self, decoded_calibration):
        self.budget.checkpoint()
        received = time.monotonic_ns()
        if (self.started_ns is None or self.received_ns is not None or
                type(decoded_calibration) is not dict or
                decoded_calibration.get("event") != "clock.calibration" or
                decoded_calibration.get("clockID") != CLOCK):
            raise OwnershipError("single decoded clock calibration required")
        swift = decoded_calibration.get("monotonicNs")
        if (type(swift) is not int or not 0 <= swift < 1 << 64 or
                not 0 <= received - self.started_ns <= 100_000_000):
            raise OwnershipError("clock handshake exceeded freshness bound")
        self.received_ns = received
        self.offset_lower_ns = self.started_ns - swift
        self.offset_upper_ns = received - swift
        self.budget.checkpoint()

    def progress_age_upper_ns(self, decoded_progress):
        self.budget.checkpoint()
        if (self.received_ns is None or type(decoded_progress) is not dict or
                decoded_progress.get("event") != "open.progress" or
                decoded_progress.get("stage") != "parsing" or
                decoded_progress.get("clockID") != CLOCK):
            raise OwnershipError("calibrated decoded parsing progress required")
        swift = decoded_progress.get("monotonicNs")
        if type(swift) is not int or not 0 <= swift < 1 << 64:
            raise OwnershipError("typed progress clock required")
        age = time.monotonic_ns() - (swift + self.offset_lower_ns)
        self.budget.checkpoint()
        if not 0 <= age <= 100_000_000:
            raise OwnershipError("parsing progress freshness unavailable")
        return age

    def receipt(self):
        self.budget.checkpoint()
        return {"pythonClock": "Python.time.monotonic_ns", "swiftClock": CLOCK,
                "queuedHandshakeNs": self.started_ns, "receivedHandshakeNs": self.received_ns,
                "offsetLowerNs": self.offset_lower_ns, "offsetUpperNs": self.offset_upper_ns,
                "clockEquivalenceProven": False, "futureDriftProven": False}
