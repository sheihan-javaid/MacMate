#!/bin/zsh
#
# End-to-end test of the in-app updater: builds a signed 1.5.0 and a signed
# 1.5.1 of this checkout, plus an ad-hoc 1.5.1, serves them over local HTTP, and
# runs UpdateInstallerTests, which installs one over the other and checks that
# unsigned or damaged downloads are refused.
#
# Needs the "MacMate Self-Signed" identity (docs/signing.md).

set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE"
trap '[[ -n "${SERVER_PID:-}" ]] && kill $SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

IDENTITY="MacMate Self-Signed"
SIGNED=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="" OTHER_CODE_SIGN_FLAGS="--timestamp=none")

build() { # <derived> <settings...>
  local derived=$1; shift
  xcodebuild -project MacMate.xcodeproj -scheme MacMate -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=NO "$@" build -quiet > "$derived.log" 2>&1 \
    || { tail -20 "$derived.log" >&2; exit 1; }
  echo "$derived/Build/Products/Release/MacMate.app"
}

echo "==> Building fixtures"
old=$(build "$WORK/old" "${SIGNED[@]}" MARKETING_VERSION=1.5.0)
ditto "$old" "$FIXTURE/old.app"
new=$(build "$WORK/new" "${SIGNED[@]}" MARKETING_VERSION=1.5.1)
ditto -c -k --keepParent "$new" "$FIXTURE/new.zip"
adhoc=$(build "$WORK/adhoc" CODE_SIGN_IDENTITY=- MARKETING_VERSION=1.5.1)
ditto -c -k --keepParent "$adhoc" "$FIXTURE/adhoc.zip"

PORT=8765
python3 -m http.server $PORT --bind 127.0.0.1 --directory "$FIXTURE" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1

echo "==> Running UpdateInstallerTests"
# The test host must be signed like a release, since the updater compares the
# download's certificate with the running app's.
TEST_RUNNER_MACMATE_UPDATE_FIXTURE="$FIXTURE" TEST_RUNNER_MACMATE_UPDATE_SERVER="http://127.0.0.1:$PORT" \
  xcodebuild test -project MacMate.xcodeproj -scheme MacMate -destination 'platform=macOS' \
    -derivedDataPath "$WORK/test" "${SIGNED[@]}" \
    -only-testing:MacMateTests/UpdateInstallerTests 2>&1 \
  | grep -E "✔|✘|passed|failed|error:|TEST (SUCCEEDED|FAILED)" | grep -v "^$"
