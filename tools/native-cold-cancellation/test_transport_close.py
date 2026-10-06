"""Bounded failure observations using real owned FDs; no child or SDK."""
import errno
import json
import os
from pathlib import Path
import tempfile

from interactive_process import Owners


class FailingClose:
    closed = False

    def __init__(self, descriptor):
        self.descriptor = descriptor
        self.attempts = 0

    def fileno(self):
        return self.descriptor

    def close(self):
        self.attempts += 1
        raise OSError(errno.EIO, "controlled close failure before actual close")


def require_closed(descriptor):
    try:
        os.fstat(descriptor)
    except OSError as error:
        assert error.errno == errno.EBADF
    else:
        raise AssertionError("owned fixture FD not closed")


def main():
    with tempfile.TemporaryDirectory(prefix="arktrace-close-observation-") as temporary:
        path = Path(temporary).resolve() / "owned"
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
        fixture = FailingClose(descriptor)
        owners = Owners()
        owners.bind_object("stdin", fixture)
        owners.capture("stdin")
        for _ in range(100):
            owners.close("stdin")
        owners.close_all()
        assert fixture.attempts == 1 and len(owners.receipts) == 1
        failure = owners.receipts[0]
        assert failure["actualCloseSucceeded"] is False and failure["closedEBADF"] is False
        assert os.fstat(descriptor).st_ino == path.stat().st_ino
        # Explicit caller fixture cleanup, not an inferred transport success.
        os.close(descriptor)
        require_closed(descriptor)
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        owners = Owners()
        owners.bind_fd("stdoutLog", descriptor)
        owners.close("stdoutLog")
        require_closed(descriptor)
        for _ in range(100):
            owners.close("stdoutLog")
        owners.close_all()
        assert len(owners.receipts) == 1 and owners.receipts[0]["closedEBADF"] is True
    print(json.dumps({"caseCount": 2, "failedCloseRepeatedCalls": 101,
                      "actualFailingCloseMethodAttempts": 1, "failedResourceFactsRetained": 1,
                      "failedCloseStillUnproven": True, "normalCloseRepeatedCalls": 101,
                      "normalResourceFactsRetained": 1, "normalCloseFreshEBADF": True,
                      "callerFixtureCleanupFreshEBADF": True, "newChildProcesses": 0,
                      "EngineCalls": 0, "actualSDKCloseFailureReproduced": False,
                      "wholeMacOSAcceptance": False}, sort_keys=True))


if __name__ == "__main__":
    main()
