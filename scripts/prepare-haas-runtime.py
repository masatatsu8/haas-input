#!/usr/bin/env python3
"""Stage fixed, checksum-verified Haas runtime assets for an offline app bundle."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / ".local-dependencies" / "haas-runtime"
SPEECH_REVISION = "af6b034918722b65c0f323d984d4644cd4120c77"
# speech.cpp の ggml submodule が指す commit。speech と libspeech に静的リンクされる。
GGML_REVISION = "700c9d743ed7cc583c0f1b6507afebb6c0e88bc0"
MODEL_REVISION = "25c400baaa9c002df8feffc140804e84228f069b"
VAD_REVISION = "7fcb7aa2a70c312f8579fc987b3e1cdecf9321ca"
MODEL_FILE = "Haas-616M-ja-v1.0-Q8_0.gguf"

ASSETS = {
    "speech-0.9.4-macos-arm64-metal.zip": {
        "url": "https://github.com/nyosegawa/speech.cpp/releases/download/v0.9.4/speech-0.9.4-macos-arm64-metal.zip",
        "sha256": "7ed31c27556926297c3ad521de289d97e17a17108feacb57a88d4b52444e6703",
        "reuse_path": "runtime/speechcpp/speech-0.9.4-macos-arm64-metal.zip",
    },
    MODEL_FILE: {
        "url": f"https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF/resolve/{MODEL_REVISION}/{MODEL_FILE}",
        "sha256": "cd5f60b2f1c411404b83fca4a65e3ce30a26d9e951b6a346529e65f22758afeb",
        "reuse_path": f"models/haas-speechcpp/{MODEL_FILE}",
    },
    "silero-vad.gguf": {
        "url": f"https://huggingface.co/sakasegawa/silero-vad-GGUF/resolve/{VAD_REVISION}/silero-vad-309K-v6.2-F32.gguf",
        "sha256": "2fc312514e5fc4fa4ffd02b25c76a4853fa4130e8fb9777d01502183b01238cb",
    },
    "SPEECH-LICENSE": {
        "url": f"https://raw.githubusercontent.com/nyosegawa/speech.cpp/{SPEECH_REVISION}/LICENSE",
        "sha256": "688f8aca0abe167966d277ed00bd594a5a51b028a4fbc1516ff9de7ef05c521a",
    },
    "GGML-LICENSE": {
        "url": f"https://raw.githubusercontent.com/nyosegawa/ggml/{GGML_REVISION}/LICENSE",
        "sha256": "94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d",
    },
    "CPP-HTTPLIB-LICENSE": {
        "url": f"https://raw.githubusercontent.com/nyosegawa/speech.cpp/{SPEECH_REVISION}/vendor/cpp-httplib/LICENSE",
        "sha256": "4b45cbe16d7b71b89ae6127e26e0d90a029198ca5e958ad8e3d0b8bbed364d8b",
    },
    "MINIAUDIO-LICENSE": {
        "url": f"https://raw.githubusercontent.com/nyosegawa/speech.cpp/{SPEECH_REVISION}/vendor/miniaudio/LICENSE",
        "sha256": "bde09ed161fef45da2194cba70601aab33ca6fdfe6eed2e3d95efd15b48561f9",
    },
    "HAAS-LICENSE": {
        "url": f"https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF/raw/{MODEL_REVISION}/LICENSE",
        "sha256": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
        "reuse_path": "models/haas-speechcpp/LICENSE",
    },
    "SILERO-LICENSE": {
        "url": f"https://huggingface.co/sakasegawa/silero-vad-GGUF/raw/{VAD_REVISION}/LICENSE",
        "sha256": "2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b",
    },
}

BINARIES = {
    "speech": "5a99d41d4d7c55936de832b73708e2a5ecf180d5b1e615837a6f66c1ee7c1550",
    "libspeech.3.dylib": "7bb5ec31d224f6e427be785af8d8b1942ec624c3e244dc29ab190098c50b8059",
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def acquire(name, asset, cache, reuse_root):
    target = cache / name
    if target.exists() and digest(target) == asset["sha256"]:
        return target
    source = reuse_root / asset["reuse_path"] if reuse_root and asset.get("reuse_path") else None
    with tempfile.TemporaryDirectory(prefix="download-", dir=cache) as temporary:
        candidate = Path(temporary) / name
        if source is not None and source.is_file():
            shutil.copyfile(source, candidate)
        else:
            subprocess.run([
                "curl", "--fail", "--location", "--show-error", "--output", str(candidate), asset["url"]
            ], check=True)
        if digest(candidate) != asset["sha256"]:
            raise ValueError(f"Checksum mismatch: {name}")
        candidate.replace(target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-root", type=Path, help="Optional existing asr-models checkout; read-only reuse")
    args = parser.parse_args()
    cache = ROOT / ".local-dependencies" / "haas-downloads"
    cache.mkdir(parents=True, exist_ok=True)
    DESTINATION.mkdir(parents=True, exist_ok=True)
    sources = {name: acquire(name, asset, cache, args.reuse_root) for name, asset in ASSETS.items()}
    archive = sources["speech-0.9.4-macos-arm64-metal.zip"]
    with zipfile.ZipFile(archive) as package:
        for name, expected in BINARIES.items():
            data = package.read(name)
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f"Archive member checksum mismatch: {name}")
            (DESTINATION / name).write_bytes(data)
    (DESTINATION / "speech").chmod(0o755)
    for name, source in sources.items():
        if not name.endswith(".zip"):
            shutil.copyfile(source, DESTINATION / name)
    manifest = {
        "speech_version": "0.9.4", "speech_revision": SPEECH_REVISION,
        "model_revision": MODEL_REVISION, "model_layout": 4, "model_quantization": "Q8_0",
        "vad_revision": VAD_REVISION,
        "sources": {name: {k: v for k, v in asset.items() if k != "reuse_path"} for name, asset in ASSETS.items()},
        "files": {p.name: {"sha256": digest(p), "size": p.stat().st_size}
                  for p in sorted(DESTINATION.iterdir()) if p.is_file() and p.name != "manifest.json"},
    }
    (DESTINATION / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(DESTINATION)


if __name__ == "__main__":
    main()
