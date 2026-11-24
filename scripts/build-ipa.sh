#!/usr/bin/env bash
# Builds an unsigned Garim .ipa with Xcode (macOS only).
# Usage: scripts/build-ipa.sh [output.ipa]
# A sideloading tool (AltStore, SideStore, Sideloadly…) signs it with the installer's Apple ID.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUTPUT="${1:-build/Garim-unsigned.ipa}"
case "$OUTPUT" in /*) ;; *) OUTPUT="$ROOT/$OUTPUT" ;; esac
WORK="$ROOT/build/ipa-work"
ARCHIVE="$WORK/Garim.xcarchive"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild를 찾을 수 없어요. Xcode가 설치된 Mac에서 실행해 주세요." >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/Payload" "$(dirname "$OUTPUT")"
xcodebuild -version

xcodebuild \
  -project Garim.xcodeproj \
  -scheme Garim \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  archive

APP="$ARCHIVE/Products/Applications/Garim.app"
if [ ! -d "$APP" ]; then
  echo "아카이브에서 Garim.app을 찾지 못했어요: $APP" >&2
  exit 1
fi

cp -R "$APP" "$WORK/Payload/"
rm -f "$OUTPUT"
(cd "$WORK" && zip -qry "$OUTPUT" Payload)
echo "IPA: $OUTPUT"
