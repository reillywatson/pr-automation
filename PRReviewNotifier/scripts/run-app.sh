#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

swift build
bin_dir="$(swift build --show-bin-path)"

app_dir="$PWD/dist/PRReviewNotifier.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
log_file="$PWD/dist/PRReviewNotifier.launch.log"

if pgrep -x PRReviewNotifier >/dev/null 2>&1; then
  osascript -e 'tell application id "dev.reilly.PRReviewNotifier" to quit' >/dev/null 2>&1 || true

  tries=0
  while pgrep -x PRReviewNotifier >/dev/null 2>&1 && [ "$tries" -lt 20 ]; do
    sleep 0.25
    tries=$((tries + 1))
  done

  if pgrep -x PRReviewNotifier >/dev/null 2>&1; then
    pkill -x PRReviewNotifier >/dev/null 2>&1 || true
  fi
fi

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"

cp "$bin_dir/PRReviewNotifier" "$macos_dir/PRReviewNotifier"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>PRReviewNotifier</string>
  <key>CFBundleIdentifier</key>
  <string>dev.reilly.PRReviewNotifier</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PRReviewNotifier</string>
  <key>CFBundleDisplayName</key>
  <string>PR Review Notifier</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$contents_dir/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$app_dir" >/dev/null
fi

: > "$log_file"
open --stdout "$log_file" --stderr "$log_file" "$app_dir"

sleep 1
if pgrep -f "$macos_dir/PRReviewNotifier" >/dev/null 2>&1 || pgrep -x PRReviewNotifier >/dev/null 2>&1; then
  echo "Launched $app_dir"
  echo "Logs: $log_file"
else
  echo "Launch returned, but PRReviewNotifier is not running."
  echo "Logs: $log_file"
  if [ -s "$log_file" ]; then
    echo
    tail -40 "$log_file"
  fi
  exit 1
fi
