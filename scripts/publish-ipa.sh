#!/usr/bin/env bash
# Builds the unsigned IPA on this Mac and attaches it to a GitHub release, without GitHub Actions.
# Needs Xcode and the GitHub CLI signed in (gh auth login).
# Usage: scripts/publish-ipa.sh v1.1.0
#   - If the tag already exists on GitHub, check it out first (git checkout v1.1.0).
#   - Otherwise the release and tag are created at the current commit, which must already be pushed.
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
# Only tracked changes matter; Xcode leaves untracked workspace files behind.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "커밋하지 않은 변경이 있어요. 커밋하거나 git stash 한 뒤 다시 실행해 주세요." >&2
  exit 1
fi

HEAD_COMMIT="$(git rev-parse HEAD)"
git fetch --quiet --tags origin
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  TAG_EXISTS=yes
  # The IPA must come from the tag's own commit.
  if [ "$(git rev-parse "$TAG^{commit}")" != "$HEAD_COMMIT" ]; then
    echo "$TAG 태그는 다른 커밋을 가리켜요. git checkout $TAG 후 다시 실행하거나 새 태그 이름을 써 주세요." >&2
    exit 1
  fi
else
  TAG_EXISTS=no
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$HEAD_COMMIT" ]; then
    echo "$TAG 태그가 이 Mac에만 있고 다른 커밋을 가리켜요. git tag -d $TAG 후 다시 실행해 주세요." >&2
    exit 1
  fi
  if [ -z "$(git branch -r --contains HEAD)" ]; then
    echo "지금 커밋이 아직 GitHub에 없어요. 먼저 git push 해 주세요." >&2
    exit 1
  fi
fi

IPA="build/Garim-${TAG}-unsigned.ipa"
scripts/build-ipa.sh "$IPA"

# Nothing is tagged until the build has succeeded.
if gh release view "$TAG" >/dev/null 2>&1; then
  if [ "$TAG_EXISTS" = no ]; then
    # A draft release whose tag isn't created yet: pin the tag to the commit that was built.
    gh release edit "$TAG" --target "$HEAD_COMMIT"
  fi
  gh release upload "$TAG" "$IPA" --clobber
elif [ "$TAG_EXISTS" = yes ]; then
  gh release create "$TAG" "$IPA" --verify-tag --title "가림 $TAG" --generate-notes
else
  # Create the release with the locally built IPA attached.
  gh release create "$TAG" "$IPA" --target "$HEAD_COMMIT" --title "가림 $TAG" --generate-notes
fi
echo "릴리즈 $TAG 에 $IPA 를 올렸어요."
