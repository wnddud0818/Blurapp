#!/usr/bin/env bash
# Builds the unsigned IPA on this Mac and attaches it to a GitHub release, without GitHub Actions.
# Needs Xcode and the GitHub CLI signed in (gh auth login).
# Usage: scripts/publish-ipa.sh v1.1.0
set -euo pipefail

TAG="${1:-}"
if [ -z "$TAG" ]; then
  echo "사용법: scripts/publish-ipa.sh <태그>  (예: scripts/publish-ipa.sh v1.1.0)" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI(gh)가 필요해요. brew install gh 후 gh auth login을 실행해 주세요." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
IPA="build/Garim-${TAG}-unsigned.ipa"
scripts/build-ipa.sh "$IPA"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$IPA" --clobber
else
  gh release create "$TAG" "$IPA" --target "$(git rev-parse HEAD)" --title "가림 $TAG" --generate-notes
fi
echo "릴리즈 $TAG 에 $IPA 를 올렸어요."
