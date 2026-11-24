#!/usr/bin/env python3
"""Patch the resolved file_picker Android library to compile against Android API 36.

This runs after `flutter pub get` but before Gradle configures any Android project.
It intentionally avoids changing compileSdk from a root-project afterEvaluate hook,
which is too late on recent Android Gradle Plugin versions.
"""
from __future__ import annotations
import os
import re
import sys
from pathlib import Path


def main() -> int:
    pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))
    hosted = pub_cache / "hosted" / "pub.dev"
    package_dirs = sorted(p for p in hosted.glob("file_picker-*") if p.is_dir() and (p / "android").is_dir())
    if not package_dirs:
        print(f"ERROR: No resolved file_picker package found under {hosted}", file=sys.stderr)
        return 1

    patterns = (
        re.compile(r"(?m)^([ \t]*compileSdkVersion[ \t]*(?:=[ \t]*)?)\d+([ \t]*(?://.*)?)$"),
        re.compile(r"(?m)^([ \t]*compileSdk[ \t]*(?:=[ \t]*)?)\d+([ \t]*(?://.*)?)$"),
    )
    for package_dir in package_dirs:
        android_dir = package_dir / "android"
        gradle_files = [p for p in (android_dir / "build.gradle", android_dir / "build.gradle.kts") if p.is_file()]
        if not gradle_files:
            print(f"ERROR: No Android Gradle build file found in {android_dir}", file=sys.stderr)
            return 1
        for gradle_file in gradle_files:
            source = gradle_file.read_text(encoding="utf-8")
            updated = source
            replacements = 0
            for pattern in patterns:
                updated, count = pattern.subn(lambda m: f"{m.group(1)}36{m.group(2)}", updated)
                replacements += count
            if replacements:
                gradle_file.write_text(updated, encoding="utf-8")
                print(f"Patched {gradle_file}: compileSdk set to 36 ({replacements} declaration(s)).")
            elif re.search(r"(?m)^\s*compileSdk(?:Version)?\s*(?:=)?\s*(?:36|flutter\.compileSdkVersion)\b", source):
                print(f"Already compatible: {gradle_file}")
            else:
                print(f"ERROR: Could not find a numeric compileSdk declaration in {gradle_file}.", file=sys.stderr)
                print(source, file=sys.stderr)
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
