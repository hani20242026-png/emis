from pathlib import Path

STUB_LLAMAFU_DART = """library llamafu;

class Llamafu {
  Llamafu._();

  static Future<Llamafu> init({
    required String modelPath,
    int threads = 4,
    int contextSize = 2048,
  }) async {
    throw UnsupportedError(
      'Local GGUF inference via llamafu is not enabled in this build target.',
    );
  }

  Future<String> complete({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.05,
  }) async {
    throw UnsupportedError(
      'Local GGUF inference via llamafu is not enabled in this build target.',
    );
  }

  void close() {}
}
"""


def main() -> None:
  root = Path(__file__).resolve().parent.parent
  stub_dir = root / ".dart_tool" / "local_ai_stub" / "lib"
  stub_dir.mkdir(parents=True, exist_ok=True)
  stub_file = stub_dir / "llamafu.dart"
  stub_file.write_text(STUB_LLAMAFU_DART, encoding="utf-8")

  package_config = root / ".dart_tool" / "package_config.json"
  if not package_config.is_file():
    raise FileNotFoundError(
        "Flutter package configuration is missing. Run `flutter pub get` "
        "before scripts/stub_local_ai.py."
    )

  import json
  from urllib.parse import urlparse
  from urllib.request import url2pathname

  data = json.loads(package_config.read_text(encoding="utf-8"))
  if not isinstance(data, dict) or not isinstance(data.get("packages"), list):
    raise ValueError(f"Invalid Flutter package configuration: {package_config}")

  packages = [p for p in data["packages"] if p.get("name") != "llamafu"]
  packages.append({
      "name": "llamafu",
      "rootUri": stub_dir.parent.resolve().as_uri(),
      "packageUri": "lib/",
      "languageVersion": "3.0",
  })
  data["packages"] = packages
  package_config.write_text(json.dumps(data, indent=2), encoding="utf-8")

  # Fail immediately if the generated import target or package mapping is wrong.
  check = json.loads(package_config.read_text(encoding="utf-8"))
  entries = [p for p in check["packages"] if p.get("name") == "llamafu"]
  if len(entries) != 1:
    raise RuntimeError(f"Expected one llamafu package mapping; found {len(entries)}")
  resolved_root = Path(url2pathname(urlparse(entries[0]["rootUri"]).path))
  resolved_file = resolved_root / entries[0]["packageUri"] / "llamafu.dart"
  if not resolved_file.is_file():
    raise RuntimeError(f"llamafu stub import target does not exist: {resolved_file}")

  print(f"Registered no-AI llamafu stub: {resolved_file}")


if __name__ == "__main__":
  main()
