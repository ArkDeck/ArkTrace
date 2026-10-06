#!/usr/bin/env python3
"""Compile the exact App button and run isolated native responder regressions.

The Swift harness explicitly simulates window admission flags. Actual App sheet,
keyboard focus and VoiceOver acceptance remain separate desktop checks.
"""
import os
from pathlib import Path
import subprocess


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    cache = Path(os.environ.get("ARKTRACE_XCODE_CACHE_ROOT",
                 str(Path.home() / "Library/Caches/com.arkdeck.ArkTrace/Xcode/Shared")))
    if not cache.is_absolute() or cache.resolve().is_relative_to(repo):
        raise SystemExit("native focus regression requires an external absolute cache")
    build = cache / "NativeFocusButtonRegression"
    build.mkdir(parents=True, exist_ok=True)
    output = build / "native-focus-button-regression"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        "-warnings-as-errors", "-module-name", "ArkTraceNativeFocusButtonRegression",
        "-target", "arm64-apple-macos26.0", "-module-cache-path", str(cache / "ModuleCache"),
        str(repo / "Apps/ArkTraceApp/Inspector/InspectorFocusButton.swift"),
        str(repo / "scripts/native-focus-button/Regression.swift"), "-o", str(output),
    ], check=True, timeout=180)
    subprocess.run([str(output)], check=True, timeout=15)


if __name__ == "__main__":
    main()
