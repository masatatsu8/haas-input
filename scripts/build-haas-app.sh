#!/bin/bash
set -euo pipefail

if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        printf 'Xcode が必要です。DEVELOPER_DIR に Xcode の Contents/Developer を指定してください。\n' >&2
        exit 1
    fi
fi

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT=${HAAS_BUILD_ROOT:-$PROJECT_ROOT/.haas-build/dedicated-app-build}
OUTPUT_ROOT=${HAAS_OUTPUT_ROOT:-$PROJECT_ROOT/.haas-build/dedicated-app-candidate}
PACKAGE_ROOT=${HAAS_PACKAGE_ROOT:-$PROJECT_ROOT/.haas-build/SourcePackages}
CONFIGURATION=${HAAS_BUILD_CONFIGURATION:-Release}
SIGNING_IDENTITY=${HAAS_CODESIGN_IDENTITY:--}
BUNDLE_MODELS=${HAAS_BUNDLE_MODELS:-1}
XCODEGEN=${XCODEGEN:-xcodegen}
APP_NAME="Haas音声入力"

case "$BUNDLE_MODELS" in
    0|1) ;;
    *) printf 'HAAS_BUNDLE_MODELS は 0 または 1 を指定してください。\n' >&2; exit 1 ;;
esac

"$XCODEGEN" generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT"
python3 "$PROJECT_ROOT/scripts/prepare-haas-runtime.py"

xcodebuild -resolvePackageDependencies -project "$PROJECT_ROOT/HaasInput.xcodeproj" \
    -scheme HaasInput -derivedDataPath "$BUILD_ROOT" -clonedSourcePackagesDirPath "$PACKAGE_ROOT"
xcodebuild -project "$PROJECT_ROOT/HaasInput.xcodeproj" -scheme HaasInput \
    -configuration "$CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
    -jobs 4 -derivedDataPath "$BUILD_ROOT" -clonedSourcePackagesDirPath "$PACKAGE_ROOT" \
    -disableAutomaticPackageResolution \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" build

mkdir -p "$OUTPUT_ROOT"
STAGING=$(mktemp -d "$OUTPUT_ROOT/.haas-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/$APP_NAME.app"
ditto "$BUILD_ROOT/Build/Products/$CONFIGURATION/$APP_NAME.app" "$APP"
ditto "$PROJECT_ROOT/.local-dependencies/haas-runtime" "$APP/Contents/Resources/Haas"
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/VOICEINK-LICENSE"
cp "$PACKAGE_ROOT/checkouts/swift-atomics/LICENSE.txt" "$APP/Contents/Resources/SWIFT-ATOMICS-LICENSE"

codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/Haas/libspeech.3.dylib"
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/Haas/speech"
python3 - "$APP/Contents/Resources/Haas" "$BUNDLE_MODELS" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
manifest["bundles_models"] = sys.argv[2] == "1"
if not manifest["bundles_models"]:
    for name in ("Haas-616M-ja-v1.0-Q8_0.gguf", "silero-vad.gguf"):
        (root / name).unlink()
manifest["signed_files"] = {}
for name in ("speech", "libspeech.3.dylib"):
    path = root / name
    manifest["signed_files"][name] = {
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size,
    }
manifest["bundled_files"] = {}
for path in sorted(root.iterdir()):
    if path.is_file() and path.name != "manifest.json":
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        manifest["bundled_files"][path.name] = {"sha256": digest.hexdigest(), "size": path.stat().st_size}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
    --entitlements "$PROJECT_ROOT/HaasInput/Configuration/HaasInput.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" "$OUTPUT_ROOT/$APP_NAME.app" <<'PY'
import os
from pathlib import Path
import shutil
import sys
import tempfile
import subprocess

staged, destination = map(Path, sys.argv[1:])
running = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
executable = destination / "Contents/MacOS/Haas音声入力"
if str(executable) in [line.strip() for line in running]:
    raise SystemExit("候補アプリが起動しています。終了してからビルドしてください。")
backup_root = Path(tempfile.mkdtemp(prefix=".haas-previous.", dir=destination.parent))
backup = backup_root / destination.name
if destination.exists():
    os.rename(destination, backup)
try:
    os.rename(staged, destination)
except BaseException:
    if backup.exists() and not destination.exists():
        os.rename(backup, destination)
    if backup.exists():
        print(f"以前の候補アプリを保持しました: {backup}", file=sys.stderr)
    raise
else:
    shutil.rmtree(backup_root)
PY
printf '作成しました: %s\n' "$OUTPUT_ROOT/$APP_NAME.app"
