#!/usr/bin/env python3
"""Restore the pinned llama.cpp source and register/link MTMD for Android."""
from __future__ import annotations

import os
import re
import shutil
import sys
import tarfile
import textwrap
import tempfile
import time
import urllib.request
from pathlib import Path

COMMIT = "b96b82f"
URL = f"https://codeload.github.com/ggml-org/llama.cpp/tar.gz/{COMMIT}"


def extract_checked(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        roots = {member.name.split("/", 1)[0] for member in members if member.name}
        if len(roots) != 1:
            raise RuntimeError(f"Unexpected llama.cpp archive layout: {sorted(roots)}")
        root = next(iter(roots))
        base = destination.resolve()
        for member in members:
            target = (destination / member.name).resolve()
            if target != base and base not in target.parents:
                raise RuntimeError(f"Unsafe archive path: {member.name}")
            if member.issym() or member.islnk():
                raise RuntimeError(f"Unexpected archive link: {member.name}")
        tar.extractall(destination)
    return destination / root


def patch_static_guard(source: Path) -> None:
    cmake = source / "ggml/src/CMakeLists.txt"
    content = cmake.read_text(encoding="utf-8")
    patched, count = re.subn(
        r"(?m)^(\s*)if\s*\(\s*GGML_STATIC\s*\)\s*$",
        r"\1if (GGML_STATIC AND NOT ANDROID)",
        content,
        count=1,
    )
    if count:
        cmake.write_text(patched, encoding="utf-8")
        content = patched
    if not re.search(r"if\s*\(\s*GGML_STATIC\s+AND\s+NOT\s+ANDROID\s*\)", content):
        raise RuntimeError("Could not verify the Android-safe GGML_STATIC guard in pinned llama.cpp.")



def patch_android_ggml_options(source: Path) -> None:
    """Disable Android-incompatible optional CPU kernels before ggml is configured."""
    cmake = source / "CMakeLists.txt"
    content = cmake.read_text(encoding="utf-8")
    marker = (
        "if (ANDROID)\n"
        '    set(GGML_LLAMAFILE OFF CACHE BOOL "EMIS: disable unsupported Android llamafile kernels" FORCE)\n'
        '    set(GGML_OPENMP OFF CACHE BOOL "EMIS: avoid Android OpenMP runtime dependency" FORCE)\n'
        "endif()"
    )
    # Set cache values before llama.cpp calls add_subdirectory(ggml).
    if marker not in content:
        anchor = re.search(
            r"(?m)^if\s*\(\s*NOT\s+TARGET\s+ggml\s+AND\s+NOT\s+LLAMA_USE_SYSTEM_GGML\s*\)\s*$",
            content,
        )
        if not anchor:
            raise RuntimeError("Could not find the pinned llama.cpp ggml configuration anchor.")
        content = content[:anchor.start()] + marker + "\n\n" + content[anchor.start():]
        cmake.write_text(content, encoding="utf-8")

    verified = cmake.read_text(encoding="utf-8")
    position = verified.find(marker)
    ggml_position = verified.find("add_subdirectory(ggml)")
    if position < 0 or ggml_position < 0 or position > ggml_position:
        raise RuntimeError("Android GGML portability options are missing or placed after ggml configuration.")
    ggml_cmake = (source / "ggml/CMakeLists.txt").read_text(encoding="utf-8")
    if "option(GGML_LLAMAFILE" not in ggml_cmake or "option(GGML_OPENMP" not in ggml_cmake:
        raise RuntimeError("Pinned ggml CMake options changed; Android portability patch needs review.")


def patch_mtmd_target(source: Path) -> None:
    """Add the MTMD library target only to Android builds, without all llama tools."""
    cmake = source / "CMakeLists.txt"
    content = cmake.read_text(encoding="utf-8")
    marker = "if (ANDROID)\n    add_subdirectory(tools/mtmd)\nendif()"
    if marker not in content:
        anchor = re.search(r"(?m)^\s*add_subdirectory\s*\(\s*src\s*\)\s*$", content)
        if not anchor:
            raise RuntimeError("Could not find add_subdirectory(src) in llama.cpp root CMakeLists.txt.")
        content = content[:anchor.end()] + "\n\n" + marker + content[anchor.end():]
        cmake.write_text(content, encoding="utf-8")
    verified = cmake.read_text(encoding="utf-8")
    if marker not in verified:
        raise RuntimeError("Android MTMD target registration did not persist correctly.")
    if not (source / "tools/mtmd/CMakeLists.txt").is_file():
        raise RuntimeError("llama.cpp tools/mtmd/CMakeLists.txt is missing.")



def patch_android_mtmd_cli_targets(source: Path) -> None:
    """Keep llamafu's requested Ninja names, but do not compile CLI tools on Android."""
    cmake = source / "tools/mtmd/CMakeLists.txt"
    content = cmake.read_text(encoding="utf-8")
    marker = "# EMIS_ANDROID_SKIP_MTMD_CLI_TOOLS"
    if marker not in content:
        pattern = re.compile(
            r"(?ms)^add_executable\s*\(\s*llama-llava-cli\s+deprecation-warning\.cpp\s*\)\s*"
            r".*?^target_compile_features\s*\(\s*\$\{TARGET\}\s+PRIVATE\s+cxx_std_17\s*\)\s*$"
        )
        match = pattern.search(content)
        if not match:
            raise RuntimeError(
                "Could not locate the complete pinned MTMD CLI target block; refusing an unsafe CMake edit."
            )
        original = match.group(0)
        replacement = (
            "if (ANDROID)\n"
            f"    {marker}\n"
            "    # llamafu's Gradle script explicitly asks Ninja for these names.\n"
            "    # Empty custom targets satisfy that request without compiling CLI programs.\n"
            "    add_custom_target(llama-llava-cli)\n"
            "    add_custom_target(llama-gemma3-cli)\n"
            "    add_custom_target(llama-minicpmv-cli)\n"
            "    add_custom_target(llama-qwen2vl-cli)\n"
            "    add_custom_target(llama-mtmd-cli)\n"
            "else()\n"
            f"{textwrap.indent(original, '    ')}\n"
            "endif()"
        )
        content = content[:match.start()] + replacement + content[match.end():]
        cmake.write_text(content, encoding="utf-8")

    verified = cmake.read_text(encoding="utf-8")
    if marker not in verified:
        raise RuntimeError("Android MTMD CLI exclusion marker was not written.")
    for target in (
        "llama-llava-cli",
        "llama-gemma3-cli",
        "llama-minicpmv-cli",
        "llama-qwen2vl-cli",
        "llama-mtmd-cli",
    ):
        if not re.search(rf"(?m)^\s*add_custom_target\s*\(\s*{re.escape(target)}\s*\)", verified):
            raise RuntimeError(f"Android no-op Ninja target is missing: {target}")
    if not re.search(
        r"if\s*\(\s*ANDROID\s*\).*?add_custom_target\s*\(\s*llama-mtmd-cli\s*\).*?else\s*\(\s*\).*?set\s*\(\s*TARGET\s+llama-mtmd-cli\s*\).*?add_executable\s*\(\s*\$\{TARGET\}",
        verified,
        re.S,
    ):
        raise RuntimeError("MTMD CLI executable is not correctly restricted to non-Android builds.")


def patch_plugin(android_dir: Path) -> None:
    cmake = android_dir / "src/main/cpp/CMakeLists.txt"
    if not cmake.is_file():
        found = [str(path.relative_to(android_dir)) for path in android_dir.rglob("CMakeLists.txt")]
        raise RuntimeError(f"llamafu CMakeLists not found at {cmake}; found: {found}")

    content = cmake.read_text(encoding="utf-8")
    android_block = re.search(
        r"if\s*\(\s*ANDROID\s*\)(.*?)else\s*\(\s*\)(.*?)endif\s*\(\s*\)",
        content,
        re.S,
    )
    if not android_block:
        raise RuntimeError("Could not locate llamafu's Android target_link_libraries branch.")

    android_links = android_block.group(1)
    if not re.search(r"(?m)^\s*mtmd\s*$", android_links):
        updated_links, count = re.subn(
            r"(?m)^(\s*)ggml\s*$", r"\1ggml\n\1mtmd", android_links, count=1
        )
        if count != 1:
            raise RuntimeError("Could not insert mtmd after ggml in llamafu's Android link list.")
        content = content[:android_block.start(1)] + updated_links + content[android_block.end(1):]
        cmake.write_text(content, encoding="utf-8")

    verified = cmake.read_text(encoding="utf-8")
    block = re.search(
        r"if\s*\(\s*ANDROID\s*\)(.*?)else\s*\(\s*\)(.*?)endif\s*\(\s*\)",
        verified,
        re.S,
    )
    if not block or not re.search(r"(?m)^\s*mtmd\s*$", block.group(1)):
        raise RuntimeError("llamafu Android link list does not contain the mtmd target.")


def main() -> int:
    cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache")).resolve()
    package_dirs = sorted((cache / "hosted/pub.dev").glob("llamafu-*/android"))
    if len(package_dirs) != 1:
        raise RuntimeError(f"Expected exactly one llamafu Android package under {cache}; found {package_dirs}")

    android_dir = package_dirs[0]
    cpp_dir = android_dir / "src/main/cpp"
    # Resolves to PUB_CACHE/hosted/llama.cpp for llamafu 0.1.0.
    source = (cpp_dir / "../../../../../../llama.cpp").resolve()
    required = ("CMakeLists.txt", "ggml/src/CMakeLists.txt", "src/CMakeLists.txt")

    if not all((source / item).is_file() for item in required):
        source.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="emis-llama-") as temporary:
            temporary_path = Path(temporary)
            archive = temporary_path / "llama.cpp.tar.gz"
            request = urllib.request.Request(URL, headers={"User-Agent": "EMIS-GitHub-Actions"})
            last_error: Exception | None = None
            for attempt in range(1, 4):
                try:
                    with urllib.request.urlopen(request, timeout=180) as response, archive.open("wb") as output:
                        shutil.copyfileobj(response, output)
                    if archive.stat().st_size < 1_000_000:
                        raise RuntimeError("Downloaded llama.cpp archive is unexpectedly small.")
                    last_error = None
                    break
                except Exception as error:
                    last_error = error
                    archive.unlink(missing_ok=True)
                    if attempt < 3:
                        print(f"llama.cpp download attempt {attempt}/3 failed: {error}; retrying...", file=sys.stderr)
                        time.sleep(5 * attempt)
            if last_error is not None:
                raise RuntimeError(f"Could not download pinned llama.cpp after 3 attempts: {last_error}")
            extracted = extract_checked(archive, temporary_path / "extract")
            staged = source.with_name(source.name + ".stage")
            if staged.exists():
                shutil.rmtree(staged)
            shutil.copytree(extracted, staged)
            if source.exists():
                shutil.rmtree(source)
            staged.rename(source)

    for relative in ("tools/mtmd/CMakeLists.txt", "tools/mtmd/clip.cpp", *required):
        if not (source / relative).is_file():
            raise RuntimeError(f"Required pinned llama.cpp file is missing: {relative}")

    patch_static_guard(source)
    patch_android_ggml_options(source)
    patch_mtmd_target(source)
    patch_android_mtmd_cli_targets(source)
    patch_plugin(android_dir)

    print(f"llama.cpp source: {source}")
    print("Verified: Android-only MTMD library is registered and linked by llamafu.")
    print("Verified: five Gradle-requested MTMD CLI names are no-op targets on Android; CLI sources are not compiled.")
    print("Verified: Android GGML_LLAMAFILE and GGML_OPENMP are disabled before ggml configuration.")
    print("Verified: no dependency on LLAMA_BUILD_TOOLS / full tools build.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # fail early with a useful CI diagnostic
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
