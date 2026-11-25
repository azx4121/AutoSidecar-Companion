#!/bin/bash
# 在獨立工作區建置可供重新簽署的 iPad 試用版，不需簽署帳號或連接裝置。
set -euo pipefail
if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 && [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
stage="$(mktemp -d /tmp/autosidecar-receiver.XXXXXXXX)"
trap 'rm -rf "$stage"' EXIT
src="$here"
project="$src/iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj"
if ! /usr/bin/xcrun xcodebuild -project "$project" -scheme WiredDisplayClient -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$stage/DerivedData" -jobs 2 \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
    EXCLUDED_SOURCE_FILE_NAMES=LegacyUSBAudioView.swift \
    PRODUCT_BUNDLE_IDENTIFIER=org.autosidecar.companion.receiver \
    MARKETING_VERSION=0.2.0 CURRENT_PROJECT_VERSION=2 INFOPLIST_KEY_CFBundleDisplayName='AutoSidecar 副螢幕' \
    INFOPLIST_KEY_NSMicrophoneUsageDescription='開啟 iPad 麥克風時，將收音傳送到已配對的 Mac。' \
    build > "$stage/build.log" 2>&1; then
    /usr/bin/tail -60 "$stage/build.log" >&2
    exit 1
fi
mkdir -p "$stage/pkg/Payload"
app="$stage/pkg/Payload/WiredDisplayClient.app"
/usr/bin/ditto --noextattr --norsrc "$stage/DerivedData/Build/Products/Release-iphoneos/WiredDisplayClient.app" "$app"
/usr/bin/strip -S "$app/WiredDisplayClient"
/bin/cp "$src/LICENSE" "$app/LICENSE.txt"
/usr/bin/xattr -cr "$stage/pkg"
(cd "$stage/pkg" && /usr/bin/zip -q -r -X "$stage/receiver.ipa" Payload)
/usr/bin/python3 "$here/CompanionTests/check_receiver.py" "$stage/receiver.ipa"
mv "$stage/receiver.ipa" "$out/AutoSidecar-iPad-unsigned.ipa"
echo "$out/AutoSidecar-iPad-unsigned.ipa"
