#!/usr/bin/env bash
# Builds the unsigned IPA on this Mac and attaches it to a GitHub release, without GitHub Actions.
# Needs Xcode and the GitHub CLI signed in (gh auth login).
# Usage: scripts/publish-ipa.sh v1.1.0
#   - If the tag already exists on GitHub, check it out first (git checkout v1.1.0).
#   - Otherwise the tag is created at the current commit, which must already be pushed.
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
if [ -n "$(git status --porcelain)" ]; then
  echo "커밋하지 않은 변경이 있어요. 커밋하거나 stash한 뒤 다시 실행해 주세요." >&2
  exit 1
fi

git fetch --quiet --tags origin
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  # The IPA must come from the tag's own commit.
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$TAG^{commit}")" ]; then
    echo "$TAG 태그는 다른 커밋을 가리켜요. git checkout $TAG 후 다시 실행해 주세요." >&2
    exit 1
  fi
else
  if [ -z "$(git branch -r --contains HEAD)" ]; then
    echo "지금 커밋이 아직 GitHub에 없어요. 먼저 git push 해 주세요." >&2
    exit 1
  fi
  # Create the tag before the long build so a mistake shows up early.
  git tag "$TAG" HEAD
  git push origin "refs/tags/$TAG"
fi

IPA="build/Garim-${TAG}-unsigned.ipa"
scripts/build-ipa.sh "$IPA"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$IPA" --clobber
else
  # The IPA is uploaded before the release is published, so the Release IPA workflow skips itself.
  gh release create "$TAG" "$IPA" --verify-tag --title "가림 $TAG" --generate-notes
fi
echo "릴리즈 $TAG 에 $IPA 를 올렸어요."
