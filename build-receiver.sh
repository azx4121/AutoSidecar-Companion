#!/bin/bash
# 建置未簽署的測試 IPA，或匯出由 Apple 開發團隊簽署的 App Store Connect IPA。
set -euo pipefail
if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 && [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
here="$(cd "$(dirname "$0")" && pwd)"
release=false
if [[ "${1:-}" == --release ]]; then
    release=true
    shift
    if [[ ! "${RECEIVER_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]]; then
        echo '請設定發布接收器的 Apple Developer 團隊 ID（RECEIVER_TEAM_ID）。' >&2
        exit 2
    fi
fi
if [[ $# -gt 1 || "${1:-}" == -* ]]; then
    echo '用法：build-receiver.sh [--release] [輸出目錄]' >&2
    exit 2
fi
out="${1:-$here/dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
stage="$(mktemp -d /tmp/autosidecar-receiver.XXXXXXXX)"
trap 'rm -rf "$stage"' EXIT
project="$here/iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj"
common=(-project "$project" -scheme WiredDisplayClient -configuration Release
    -destination 'generic/platform=iOS' -derivedDataPath "$stage/DerivedData" -jobs 2)
run_xcode() {
    if ! /usr/bin/xcrun xcodebuild "$@" > "$stage/build.log" 2>&1; then
        /usr/bin/tail -60 "$stage/build.log" >&2
        return 1
    fi
}
if $release; then
    archive="$stage/AutoSidecar.xcarchive"
    run_xcode "${common[@]}" -archivePath "$archive" -allowProvisioningUpdates \
        "DEVELOPMENT_TEAM=$RECEIVER_TEAM_ID" archive
    /usr/libexec/PlistBuddy -c 'Add :method string app-store-connect' \
        -c 'Add :destination string export' -c "Add :teamID string $RECEIVER_TEAM_ID" \
        "$stage/export.plist" >/dev/null
    run_xcode -exportArchive -archivePath "$archive" -exportOptionsPlist "$stage/export.plist" \
        -exportPath "$stage/export" -allowProvisioningUpdates
    exported=("$stage"/export/*.ipa)
    if [[ ${#exported[@]} -ne 1 || ! -f "${exported[0]}" ]]; then
        echo 'Xcode 未匯出唯一的接收器 IPA。' >&2
        exit 1
    fi
    mv "${exported[0]}" "$out/AutoSidecar-iPad-AppStoreConnect.ipa"
    echo "$out/AutoSidecar-iPad-AppStoreConnect.ipa"
    exit
fi
run_xcode "${common[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build
mkdir -p "$stage/pkg/Payload"
app="$stage/pkg/Payload/WiredDisplayClient.app"
/usr/bin/ditto --noextattr --norsrc "$stage/DerivedData/Build/Products/Release-iphoneos/WiredDisplayClient.app" "$app"
/usr/bin/strip -S "$app/WiredDisplayClient"
/usr/bin/xattr -cr "$stage/pkg"
(cd "$stage/pkg" && /usr/bin/zip -q -r -X "$stage/receiver.ipa" Payload)
/usr/bin/python3 "$here/CompanionTests/check_receiver.py" "$stage/receiver.ipa"
mv "$stage/receiver.ipa" "$out/AutoSidecar-iPad-unsigned.ipa"
echo "$out/AutoSidecar-iPad-unsigned.ipa"
