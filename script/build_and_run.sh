#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="postmere"
BUNDLE_ID="mujhtech.postmere"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUILD_LOG="$BUILD_DIR/build.log"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$BUILD_DIR"
echo "Building Postmere…"
if ! xcodebuild \
  -project "$PROJECT_ROOT/postmere/postmere.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  echo "Build failed. Full log: $BUILD_LOG" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    echo "Opened Postmere."
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "Postmere built, launched, and is running."
    ;;
esac
