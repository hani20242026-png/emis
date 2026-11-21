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
  (stub_dir / "llamafu.dart").write_text(STUB_LLAMAFU_DART, encoding="utf-8")

  package_config = root / ".dart_tool" / "package_config.json"
  if package_config.exists():
    import json

    data = json.loads(package_config.read_text(encoding="utf-8"))
    packages = data.get("packages", [])
    packages = [p for p in packages if p.get("name") != "llamafu"]
    packages.append({
        "name": "llamafu",
        "rootUri": stub_dir.parent.resolve().as_uri(),
        "packageUri": "lib/",
        "languageVersion": "3.0",
    })
    data["packages"] = packages
    package_config.write_text(json.dumps(data, indent=2), encoding="utf-8")


if __name__ == "__main__":
  main()
