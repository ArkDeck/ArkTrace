#!/usr/bin/env python3
"""Use a disposable APFS image for real cross-volume and ENOSPC acceptance.

Creates/ejects only this invocation's image under a private temporary directory.
Never formats or resizes an existing disk. Runs on macOS 27 with diskutil image.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def command(arguments, timeout=60):
    result = subprocess.run(arguments, capture_output=True, timeout=timeout)
    if result.returncode:
        sys.stderr.write(result.stdout.decode(errors="replace")[:16384])
        sys.stderr.write(result.stderr.decode(errors="replace")[:16384])
        result.check_returncode()
    return result


def main():
    if sys.platform != "darwin":
        raise SystemExit("native APFS acceptance requires macOS; no simulated PASS")
    command([sys.executable, str(ROOT / "scripts/run-cargo.py"), "build", "-p", "arktrace-platform", "--example", "macos_volume_probe"])
    # An attach timeout can leave a mounted image. Preserve its parent until a
    # positive eject, rather than recursive deletion through the mount point.
    base = Path(tempfile.mkdtemp(prefix="arktrace-apfs-acceptance-")).resolve()
    image, mount = base / "test-image.raw", base / "image-mount"
    host = base / "host"
    host.mkdir(mode=0o700)
    mounted = False
    attach_started = False
    try:
        command(["/usr/sbin/diskutil", "image", "create", "blank", "--size", "64m", "--fs", "APFS", "--volumeName", "ArkTraceFilePortTest", str(image)])
        attach_started = True
        # A newly created image has a root-owned volume root. Bootstrap our
        # user-owned child on this image only, then remount with owners enforced
        # before any platform admission or probe. No sudo/chown is needed.
        command(["/usr/sbin/diskutil", "image", "attach", "--nobrowse", "--mountOptions", "noowners", "--mountPoint", str(mount), str(image)])
        mounted = True
        volume = mount / "owned"
        volume.mkdir(mode=0o700)
        command([sys.executable, str(ROOT / "scripts/run-cargo.py"), "run", "-p", "arktrace-platform", "--example", "macos_volume_probe", "--", str(host), str(volume), "reject-ignored-ownership"])
        command(["/usr/sbin/diskutil", "eject", str(mount)])
        mounted = False
        command(["/usr/sbin/diskutil", "image", "attach", "--nobrowse", "--mountOptions", "owners", "--mountPoint", str(mount), str(image)])
        mounted = True
        info = plistlib.loads(command(["/usr/sbin/diskutil", "info", "-plist", str(mount)]).stdout)
        assert Path(info["MountPoint"]).resolve() == mount
        assert info["FilesystemType"] == "apfs", "actual APFS filesystem required"
        assert mount.stat().st_dev != host.stat().st_dev
        assert info.get("GlobalPermissionsEnabled") is True, "owner permissions must be enforced on the mounted test image"
        assert volume.stat().st_uid == os.geteuid()
        probe = command([sys.executable, str(ROOT / "scripts/run-cargo.py"), "run", "-p", "arktrace-platform", "--example", "macos_volume_probe", "--", str(host), str(volume)], timeout=120)
        report = json.loads(probe.stdout)
        assert report["passed"] is True
        assert report["cleanupResidueCount"] == 0 and report["rawBytesUnchanged"] is True
        report["ownershipDisabledRootRefused"] = True
    finally:
        if mounted or (mount.exists() and mount.stat().st_dev != base.stat().st_dev):
            command(["/usr/sbin/diskutil", "eject", str(mount)])
        elif attach_started:
            raise RuntimeError(f"attach state unconfirmed; preserved owned image for recovery: {base}")
        import shutil
        shutil.rmtree(base)
    report["ownedTemporaryRootRemoved"] = not base.exists()
    assert report["ownedTemporaryRootRemoved"] is True
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
