#!/usr/bin/env python3
"""Patch llamafu 0.1.0 Android Gradle settings for the EMIS build.

The current native build references pthread_atfork. Android exposes that API
from API 23, while llamafu 0.1.0 defaults its CMake target to API 21. Align the
plugin's minSdk and NDK with the host app before Gradle configures CMake.
"""
from pathlib import Path
import os
import re
import sys

NDK_VERSION = "28.2.13676358"
MIN_SDK = 23
pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))
plugin_files = list((pub_cache / "hosted").glob("*/llamafu-0.1.0/android/build.gradle"))
if not plugin_files:
    print(f"ERROR: llamafu-0.1.0/android/build.gradle not found under {pub_cache}", file=sys.stderr)
    sys.exit(2)

for gradle_file in plugin_files:
    text = gradle_file.read_text(encoding="utf-8")
    original = text

    if not re.search(r"(?m)^\s*(?:def|String)\s+kotlin_version\s*=", text):
        text = "def kotlin_version = '2.4.0'\n" + text

    android_match = re.search(r"(?m)^\s*android\s*\{", text)
    if not android_match:
        raise RuntimeError(f"No android {{}} block in {gradle_file}")

    manifest = gradle_file.parent / "src/main/AndroidManifest.xml"
    manifest_text = manifest.read_text(encoding="utf-8") if manifest.exists() else ""
    package_match = re.search(r"\bpackage\s*=\s*['\"]([^'\"]+)['\"]", manifest_text)
    namespace = package_match.group(1) if package_match else "com.cognisoc.llamafu"

    if not re.search(r"(?m)^\s*namespace\s+['\"]", text):
        text = re.sub(r"(?m)(^\s*android\s*\{)", lambda m: m.group(1) + f"\n    namespace '{namespace}'", text, count=1)

    # Pin the plugin module itself. Pinning only :app does not control a
    # library module that has its own Android configuration.
    if re.search(r"(?m)^\s*ndkVersion\s+['\"]", text):
        text = re.sub(r"(?m)^\s*ndkVersion\s+['\"][^'\"]+['\"]", f"    ndkVersion '{NDK_VERSION}'", text, count=1)
    else:
        text = re.sub(r"(?m)(^\s*android\s*\{)", lambda m: m.group(1) + f"\n    ndkVersion '{NDK_VERSION}'", text, count=1)


    # AndroidX AAR metadata in llamafu 0.1.0 requires compileSdk 36.
    # This does not change targetSdk or minSdk.
    compile_patterns = (
        r"(?m)^(\s*)compileSdkVersion\s+.*$",
        r"(?m)^(\s*)compileSdk\s*=\s*.*$",
        r"(?m)^(\s*)compileSdk\s+.*$",
    )
    compile_replacements = (
        r"\g<1>compileSdkVersion 36",
        r"\g<1>compileSdk = 36",
        r"\g<1>compileSdk 36",
    )
    compile_changed = False
    for pattern, replacement in zip(compile_patterns, compile_replacements):
        if re.search(pattern, text):
            text, count = re.subn(pattern, replacement, text, count=1)
            compile_changed = count == 1
            break
    if not compile_changed:
        text = re.sub(
            r"(?m)(^\s*android\s*\{)",
            lambda m: m.group(1) + "\n    compileSdkVersion 36",
            text,
            count=1,
        )

    # Ensure CMake configures the native target for API 23, not its upstream
    # default API 21. This is the actual pthread_atfork linker failure cause.
    default_config = re.search(r"(?m)^\s*defaultConfig\s*\{", text)
    if not default_config:
        raise RuntimeError(f"No defaultConfig {{}} block in {gradle_file}")
    min_sdk_pattern = r"(?m)^\s*minSdkVersion\s+\d+"
    if re.search(min_sdk_pattern, text):
        text = re.sub(min_sdk_pattern, f"        minSdkVersion {MIN_SDK}", text, count=1)
    elif re.search(r"(?m)^\s*minSdk\s*=", text):
        text = re.sub(r"(?m)^\s*minSdk\s*=\s*\d+", f"        minSdk = {MIN_SDK}", text, count=1)
    else:
        insert = default_config.end()
        text = text[:insert] + f"\n        minSdkVersion {MIN_SDK}" + text[insert:]

    if text != original:
        gradle_file.write_text(text, encoding="utf-8")
        print(f"Patched: {gradle_file}")
    else:
        print(f"Already patched: {gradle_file}")

    check = gradle_file.read_text(encoding="utf-8")
    if f"ndkVersion '{NDK_VERSION}'" not in check or f"minSdkVersion {MIN_SDK}" not in check:
        raise RuntimeError(f"llamafu patch verification failed: {gradle_file}")
    if not re.search(r"(?m)^\s*compileSdkVersion\s+36\s*$", check):
        raise RuntimeError(f"llamafu compileSdk 36 patch verification failed: {gradle_file}")


def patch_app_compile_sdk(project_root: Path) -> None:
    """Pin the app module to SDK 36 without changing minSdk or targetSdk."""
    app_gradle = project_root / "android/app/build.gradle.kts"
    if not app_gradle.is_file():
        raise RuntimeError(f"Application Gradle file is missing: {app_gradle}")
    content = app_gradle.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^android\s*\{(.*?)^\}", content)
    if not match:
        raise RuntimeError(f"No top-level android block in {app_gradle}")
    block = match.group(1)
    if len(re.findall(r"(?m)^\s*compileSdk\s*=", block)) != 1:
        raise RuntimeError("Expected exactly one compileSdk assignment in app Gradle.")
    new_block = re.sub(
        r"(?m)^(\s*)compileSdk\s*=.*$",
        r"\g<1>compileSdk = 36",
        block,
        count=1,
    )
    updated = content[:match.start(1)] + new_block + content[match.end(1):]
    if updated != content:
        app_gradle.write_text(updated, encoding="utf-8")
        print(f"Patched application compileSdk to 36: {app_gradle}")
    check = app_gradle.read_text(encoding="utf-8")
    check_match = re.search(r"(?ms)^android\s*\{(.*?)^\}", check)
    if not check_match or not re.search(r"(?m)^\s*compileSdk\s*=\s*36\s*$", check_match.group(1)):
        raise RuntimeError("Application compileSdk 36 verification failed.")
    if not re.search(r"(?m)^\s*minSdk\s*=\s*23\s*$", check):
        raise RuntimeError("Application minSdk changed unexpectedly.")
    if not re.search(r"(?m)^\s*targetSdk\s*=\s*flutter\.targetSdkVersion\s*$", check):
        raise RuntimeError("Application targetSdk changed unexpectedly.")

patch_app_compile_sdk(Path(__file__).resolve().parents[1])

print(f"llamafu configured: compileSdk 36, NDK {NDK_VERSION}, minSdk {MIN_SDK}.")
