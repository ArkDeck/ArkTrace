#!/usr/bin/env python3
"""Copy only verified fixed native tools into the Xcode-owned App bundle."""
import argparse
import os
from pathlib import Path
import shutil
from prepare_macos_native_app import regular, require, validate_inputs


def physical_build_path(path):
    # Xcode's Foundation paths shorten these root-owned macOS aliases. Only
    # normalize the verified system prefix; never resolve a staged/output link.
    for alias in ("/tmp", "/var", "/etc"):
        if str(path).startswith(alias + "/"):
            prefix = Path(alias)
            target = "/private" + alias
            require(prefix.is_symlink() and prefix.lstat().st_uid == 0 and
                    (prefix.parent / os.readlink(prefix)).absolute() == Path(target), "untrusted build path alias")
            return Path(target + str(path)[len(alias):])
    return path


def copy(inputs, bundle):
    inputs, bundle = physical_build_path(inputs), physical_build_path(bundle)
    validate_inputs(inputs)
    require(bundle.is_absolute() and bundle.suffix == ".app", "absolute App output required")
    require(not any(p.is_symlink() for p in (bundle, *bundle.parents)), "App output links forbidden")
    mapping = {"Helpers/arktrace-host-process": "Contents/Helpers/arktrace-host-process",
               "Helpers/trace_streamer": "Contents/Helpers/trace_streamer",
               "TraceStreamer/manifest.json": "Contents/Resources/TraceStreamer/manifest.json",
               "ArkTraceRuntime/manifest.json": "Contents/Resources/ArkTraceRuntime/manifest.json"}
    for source, relative in mapping.items():
        target = bundle / relative
        require(not any(p.is_symlink() for p in (target, *target.parents)), "App destination links forbidden")
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            regular(target)
            target.unlink()
        shutil.copyfile(inputs / source, target)
        target.chmod(0o555 if source.startswith("Helpers/") else 0o444)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    args = parser.parse_args()
    copy(args.inputs, args.bundle)
