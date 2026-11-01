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
TEST_BUILD_ROOT=${HAAS_TEST_BUILD_ROOT:-$PROJECT_ROOT/.haas-build/dedicated-test-host}
PACKAGE_ROOT=${HAAS_PACKAGE_ROOT:-$PROJECT_ROOT/.haas-build/SourcePackages}
CONFIGURATION=${HAAS_TEST_CONFIGURATION:-Debug}
SIGNING_IDENTITY=${HAAS_CODESIGN_IDENTITY:--}
XCODEGEN=${XCODEGEN:-xcodegen}
ACTION=(test -only-testing:HaasInputTests)

if [ "${1:-}" = "--show-build-settings" ]; then
    ACTION=(-showBuildSettings -json)
    shift
fi

"$XCODEGEN" generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT"
xcodebuild -resolvePackageDependencies -project "$PROJECT_ROOT/HaasInput.xcodeproj" \
    -scheme HaasInputTests -derivedDataPath "$TEST_BUILD_ROOT" -clonedSourcePackagesDirPath "$PACKAGE_ROOT"

# TestHost の入口は空の Settings Scene。実 runtime は同梱せず、モデル準備や録音を開始しない。
exec xcodebuild -project "$PROJECT_ROOT/HaasInput.xcodeproj" -scheme HaasInputTests \
    -configuration "$CONFIGURATION" -destination 'platform=macOS,arch=arm64' -jobs 4 \
    -derivedDataPath "$TEST_BUILD_ROOT" -clonedSourcePackagesDirPath "$PACKAGE_ROOT" \
    -disableAutomaticPackageResolution \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" "${ACTION[@]}" "$@"
