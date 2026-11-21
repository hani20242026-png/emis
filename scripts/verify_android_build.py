#!/usr/bin/env python3
"""Fail-fast checks for the pinned EMIS Android/llamafu native build setup."""
from __future__ import annotations
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NDK_VERSION = "28.2.13676358"
MIN_SDK = 23


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache")).resolve()
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME", ""))
    require(sdk.is_dir(), "ANDROID_SDK_ROOT/ANDROID_HOME is missing or invalid.")
    require((sdk / "platforms" / "android-36" / "android.jar").is_file(),
            "Android SDK Platform 36 is not installed.")
    require((sdk / "ndk" / NDK_VERSION / "source.properties").is_file(), f"Required NDK {NDK_VERSION} is not installed.")
    for version in ("3.18.1", "3.22.1"):
        require((sdk / "cmake" / version / "bin/cmake").is_file(), f"Required Android CMake {version} is not installed.")

    app_gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
    require(re.search(r"(?m)^\s*compileSdk\s*=\s*36\s*$", app_gradle) is not None,
            "Application compileSdk must be 36.")
    require(re.search(r"ndkVersion\s*=\s*[\"']" + re.escape(NDK_VERSION), app_gradle) is not None,
            f"App Gradle must pin NDK {NDK_VERSION}.")
    require(re.search(r"minSdk\s*=\s*" + str(MIN_SDK) + r"\b", app_gradle) is not None,
            f"App minSdk must be {MIN_SDK} for the native pthread API requirement.")

    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    require(re.search(r"(?m)^\s+llamafu:\s*\^?0\.1\.0\s*$", pubspec) is not None,
            "pubspec.yaml must use the audited llamafu 0.1.0 release.")
    packages = sorted((pub_cache / "hosted/pub.dev").glob("llamafu-0.1.0/android"))
    require(len(packages) == 1, f"Expected one llamafu-0.1.0 package; found {packages}.")
    android = packages[0]
    plugin_gradle = (android / "build.gradle").read_text(encoding="utf-8")
    require(re.search(r"(?m)^\s*compileSdkVersion\s+36\s*$", plugin_gradle) is not None,
            "llamafu must be patched to compileSdkVersion 36 before Gradle starts.")
    source = (android / "src/main/cpp/../../../../../../llama.cpp").resolve()
    root_cmake = (source / "CMakeLists.txt").read_text(encoding="utf-8")
    android_ggml_options = re.search(
        r"if\s*\(\s*ANDROID\s*\)(.*?)endif\s*\(\s*\)",
        root_cmake,
        re.S,
    )
    require(
        android_ggml_options is not None
        and re.search(r"set\s*\(\s*GGML_LLAMAFILE\s+OFF\s+CACHE\s+BOOL", android_ggml_options.group(1))
        and re.search(r"set\s*\(\s*GGML_OPENMP\s+OFF\s+CACHE\s+BOOL", android_ggml_options.group(1))
        and root_cmake.find(android_ggml_options.group(0)) < root_cmake.find("add_subdirectory(ggml)"),
        "Android GGML_LLAMAFILE/GGML_OPENMP portability patch is missing or applied too late.",
    )
    ggml_cpu_cmake = (source / "ggml/src/ggml-cpu/CMakeLists.txt").read_text(encoding="utf-8")
    require("if (GGML_LLAMAFILE)" in ggml_cpu_cmake,
            "Pinned ggml CPU CMake layout changed; re-audit the Android LLAMAFILE workaround.")
    require(re.search(r"if\s*\(\s*ANDROID\s*\)\s*add_subdirectory\s*\(\s*tools/mtmd\s*\)\s*endif\s*\(\s*\)", root_cmake, re.S) is not None,
            "llama.cpp Android MTMD target registration is missing or malformed.")
    plugin_cmake = (android / "src/main/cpp/CMakeLists.txt").read_text(encoding="utf-8")
    android_links = re.search(r"if\s*\(\s*ANDROID\s*\)(.*?)else\s*\(\s*\)(.*?)endif\s*\(\s*\)", plugin_cmake, re.S)
    require(android_links is not None and re.search(r"(?m)^\s*mtmd\s*$", android_links.group(1)) is not None,
            "llamafu Android link list does not contain the mtmd target.")
    require((source / "tools/mtmd/CMakeLists.txt").is_file(), "MTMD CMake source is missing.")
    require((source / "tools/mtmd/clip.cpp").is_file(), "CLIP source is missing.")
    mtmd_cmake = (source / "tools/mtmd/CMakeLists.txt").read_text(encoding="utf-8")
    require("# EMIS_ANDROID_SKIP_MTMD_CLI_TOOLS" in mtmd_cmake,
            "Android MTMD CLI exclusion patch is missing.")
    for cli_target in ("llama-llava-cli", "llama-gemma3-cli", "llama-minicpmv-cli",
                       "llama-qwen2vl-cli", "llama-mtmd-cli"):
        require(re.search(rf"(?m)^\s*add_custom_target\s*\(\s*{re.escape(cli_target)}\s*\)", mtmd_cmake) is not None,
                f"Android no-op Ninja target is missing: {cli_target}.")
    import shutil
    free_gb = shutil.disk_usage(ROOT).free / (1024 ** 3)
    require(free_gb >= 8.0,
            f"Only {free_gb:.1f} GiB free disk remains; at least 8 GiB is required before Gradle.")
    mtmd_cmake = (source / "tools/mtmd/CMakeLists.txt").read_text(encoding="utf-8")
    require("# EMIS_ANDROID_SKIP_MTMD_CLI_TOOLS" in mtmd_cmake,
            "Android MTMD CLI exclusion patch is missing.")
    for cli_target in ("llama-llava-cli", "llama-gemma3-cli", "llama-minicpmv-cli",
                       "llama-qwen2vl-cli", "llama-mtmd-cli"):
        require(re.search(rf"(?m)^\s*add_custom_target\s*\(\s*{re.escape(cli_target)}\s*\)", mtmd_cmake) is not None,
                f"Android no-op Ninja target is missing: {cli_target}.")
    require(re.search(
        r"if\s*\(\s*ANDROID\s*\).*?add_custom_target\s*\(\s*llama-mtmd-cli\s*\).*?else\s*\(\s*\).*?set\s*\(\s*TARGET\s+llama-mtmd-cli\s*\).*?add_executable\s*\(\s*\$\{TARGET\}",
        mtmd_cmake, re.S) is not None,
        "MTMD CLI executable must remain available only for non-Android builds.")

    model = ROOT / "assets/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
    require(model.is_file() and model.stat().st_size >= 400_000_000,
            "Bundled Qwen GGUF model is missing or incomplete (<400 MB).")

    print(f"PASS: SDK 36, NDK/CMake, llamafu compileSdk/minSdk, MTMD/CLI exclusions, GGML options, GGUF model; free disk {free_gb:.1f} GiB.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"PRE-FLIGHT ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
