#!/bin/bash
# Sign, notarize and publish any Shafer LLC Mac app from this machine, without
# GitHub Actions.
#
#   ./ship.sh              ship the app in the current folder
#   ./ship.sh ../ledge     ship that one
#   DRY_RUN=1 ./ship.sh    build and notarize, publish nothing
#
# The shared release workflow does this in CI, but it needs org signing secrets
# that a Free-plan org can't hand to a private repo. Everything it needs is on
# this Mac anyway: the Developer ID in the keychain, a notarytool profile, and
# Sparkle's EdDSA key.
#
# The fleet is not uniform — some apps have a Sparkle feed, some have an R2
# publish script, some have neither. Each step here checks for what it needs
# and says what it skipped, rather than assuming Ledge's layout.
set -euo pipefail

cd "${1:-$PWD}"
APP_DIR="$PWD"
[ -f make-app.sh ] || { echo "✗ no make-app.sh — not a Shafer Mac app" >&2; exit 1; }
[ -f VERSION ] || { echo "✗ no VERSION file" >&2; exit 1; }

SLUG=$(basename "$APP_DIR")
NAME=$(tr '[:lower:]' '[:upper:]' <<< "${SLUG:0:1}")${SLUG:1}
VERSION=$(tr -d '[:space:]' < VERSION)
NOTARY_PROFILE="${NOTARY_PROFILE:-shafer}"
SPARKLE_BIN=$(ls -d .build/artifacts/*/Sparkle/bin 2>/dev/null | head -1 || true)

say() { printf '\n\033[1m› %s\033[0m\n' "$1"; }

# ── Refuse to ship something you can't reproduce ─────────────────────────────
# A local release has no clean room: whatever is in this tree is what users get.
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ working tree is dirty — commit or stash first" >&2
  git status --short >&2
  exit 1
fi
if [ -n "$(git log '@{u}..' --oneline 2>/dev/null)" ]; then
  echo "✗ unpushed commits — push first, so the tag matches the remote" >&2
  exit 1
fi

REPO=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
  echo "✗ v$VERSION is already released — bump VERSION first" >&2
  exit 1
fi

# ── Build number ────────────────────────────────────────────────────────────
# Sparkle compares CFBundleVersion, so local and CI releases have to share ONE
# increasing series. The published feed is the record of where that series got
# to; going under it strands everyone on this release, because the next build
# would look older and never be offered.
LAST=$(curl -fsS "https://dl.shafer.llc/$SLUG/appcast.xml" 2>/dev/null \
  | grep -oE '<sparkle:version>[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)
if [ -z "$LAST" ]; then
  LAST=$(gh run list -R "$REPO" --workflow release.yml --limit 1 \
    --json number --jq '.[0].number' 2>/dev/null || echo 0)
fi
BUILD=$(( ${LAST:-0} + 1 ))
say "$NAME $VERSION — build $BUILD (last published: ${LAST:-none})"

# ── Build, sign, notarize, staple ───────────────────────────────────────────
say "Building universal, signing and notarizing"
LEDGE_BUILD="$BUILD" APP_BUILD="$BUILD" NOTARY_PROFILE="$NOTARY_PROFILE" ./make-app.sh --dist

DMG="dist/$NAME-$VERSION.dmg"
ZIP="dist/$NAME-$VERSION.zip"
[ -f "$DMG" ] || { echo "✗ $DMG missing — did make-app.sh package it?" >&2; exit 1; }

say "Verifying the signature and the notarization ticket"
codesign --verify --deep --strict --verbose=1 "dist/$NAME.app"
spctl --assess --type execute "dist/$NAME.app"
# Gatekeeper accepts a stapled app offline; an unstapled one fails on a Mac
# that can't reach Apple, which is exactly the Mac that can't tell you why.
xcrun stapler validate "$DMG"

# ── Sparkle feed ────────────────────────────────────────────────────────────
if [ -f sparkle-public-key ] && [ -n "$SPARKLE_BIN" ]; then
  say "Signing the Sparkle feed"
  # Only this release goes in front of generate_appcast. Pointed at dist/ it
  # would scan every archive still sitting there — including the 0.0.0 ad-hoc
  # builds — and quietly offer them to users as updates.
  FEED_DIR=$(mktemp -d)
  trap 'rm -rf "$FEED_DIR"' EXIT
  cp "$ZIP" "$FEED_DIR/"
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://dl.shafer.llc/$SLUG/" "$FEED_DIR"
  [ -f "$FEED_DIR/appcast.xml" ] || { echo "✗ generate_appcast wrote no appcast.xml" >&2; exit 1; }
  cp "$FEED_DIR/appcast.xml" dist/appcast.xml
  grep -q "<sparkle:version>$BUILD<" dist/appcast.xml \
    || { echo "✗ feed doesn't advertise build $BUILD — refusing to publish a feed that strands users" >&2; exit 1; }
  ASSETS=("$DMG" "$ZIP" dist/appcast.xml)
else
  echo "  (no Sparkle key or tools here — shipping without a feed)"
  ASSETS=("$DMG" "$ZIP")
fi

if [ -n "${DRY_RUN:-}" ]; then
  say "DRY_RUN — built and notarized, publishing nothing"
  ls -la dist/
  exit 0
fi

# ── Publish ─────────────────────────────────────────────────────────────────
say "Tagging and creating the GitHub release"
git tag -a "v$VERSION" -m "$NAME $VERSION" 2>/dev/null || true
git push origin "v$VERSION"
gh release create "v$VERSION" "${ASSETS[@]}" -R "$REPO" \
  --title "$NAME v$VERSION" --generate-notes

# The repos are private, so installed copies and the website download from R2,
# not from GitHub. Last, so the feed never points at a file that isn't up yet.
if [ -x scripts/publish-downloads.sh ]; then
  say "Publishing downloads to R2"
  scripts/publish-downloads.sh "$VERSION"
else
  echo "  (no scripts/publish-downloads.sh — GitHub release only)"
fi

say "Shipped $NAME $VERSION (build $BUILD)"
