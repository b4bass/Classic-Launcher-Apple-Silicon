#!/bin/bash

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # build/
BASE_DIR="$(dirname "$BUILD_DIR")"                         # wow root
LAUNCHER_DIR="$BASE_DIR/custom_launcher"                   # custom_launcher/
APP_NAME="WoW Classic Launcher"
APP_OUT="$BASE_DIR/$APP_NAME.app"
ICON_PNG="$BUILD_DIR/wow.png"
PATCH_FILE="$BUILD_DIR/40618.patch"

# Private, per-build scratch space instead of predictable /tmp paths
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT
ICONSET="$BUILD_TMP/wow.iconset"
ICON_ICNS="$BUILD_TMP/wow.icns"

# 0. Make sure the tools and source files we depend on are actually here
for cmd in sips iconutil osacompile codesign awk; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[!] Required command not found: $cmd" >&2; exit 1; }
done
[ -x /usr/libexec/PlistBuddy ] || { echo "[!] Required tool not found: /usr/libexec/PlistBuddy" >&2; exit 1; }
[ -f "$ICON_PNG" ] || { echo "[!] Icon source not found at $ICON_PNG" >&2; exit 1; }
[ -f "$PATCH_FILE" ] || { echo "[!] Patch file not found at $PATCH_FILE" >&2; exit 1; }
[ -f "$LAUNCHER_DIR/launch.sh" ] || { echo "[!] launch.sh not found at $LAUNCHER_DIR/launch.sh" >&2; exit 1; }
[ -f "$LAUNCHER_DIR/xdelta3/bin/xdelta3" ] || { echo "[!] xdelta3 binary not found at $LAUNCHER_DIR/xdelta3/bin/xdelta3" >&2; exit 1; }
[ -f "$LAUNCHER_DIR/proxy/HermesProxy" ] || { echo "[!] HermesProxy binary not found at $LAUNCHER_DIR/proxy/HermesProxy" >&2; exit 1; }
[ -f "$LAUNCHER_DIR/surge/surge" ] || { echo "[!] surge binary not found at $LAUNCHER_DIR/surge/surge" >&2; exit 1; }
[ -d "$LAUNCHER_DIR/openssl-3.0.7" ] || { echo "[!] openssl-3.0.7 folder not found at $LAUNCHER_DIR/openssl-3.0.7" >&2; exit 1; }

# 1. Create .icns from .png (Required for high-quality bundle icons)
echo "[*] Creating icon from wow.png..."
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size     "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null 2>&1 \
        || { echo "[!] Failed to generate ${size}x${size} icon." >&2; exit 1; }
    sips -z $((size*2)) $((size*2)) "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null 2>&1 \
        || { echo "[!] Failed to generate ${size}x${size}@2x icon." >&2; exit 1; }
done
iconutil -c icns "$ICONSET" -o "$ICON_ICNS" || { echo "[!] iconutil failed to build the .icns." >&2; exit 1; }

# 2. Write the AppleScript source
# Using 'path to resource' ensures it finds the script inside the bundle
cat > "$BUILD_TMP/launcher.applescript" << 'EOF'
set launchScript to POSIX path of (path to resource "launch.sh")

tell application "Terminal"
    activate
    do script "bash " & quoted form of launchScript
end tell
EOF

# 3. Compile into .app
echo "[*] Building $APP_NAME.app..."
rm -rf "$APP_OUT"
osacompile -o "$APP_OUT" "$BUILD_TMP/launcher.applescript" \
    || { echo "[!] osacompile failed to produce the .app." >&2; exit 1; }

# 4. Copy content into the app bundle so it's self-contained
echo "[*] Including custom_launcher content in bundle..."
mkdir -p "$APP_OUT/Contents/Resources/build"
cp -R "$LAUNCHER_DIR/" "$APP_OUT/Contents/Resources/" || { echo "[!] Failed to copy launcher content." >&2; exit 1; }
# keep the patch file in the build folder
cp "$PATCH_FILE" "$APP_OUT/Contents/Resources/build/" || { echo "[!] Failed to copy the patch file." >&2; exit 1; }

# Drop Finder metadata junk - never useful, never wanted
find "$APP_OUT/Contents/Resources" -name ".DS_Store" -delete

# 5. Swap in the app's own proxy/window behavior (see WITHIN_APP markers in launch.sh)
LAUNCH_SH="$APP_OUT/Contents/Resources/launch.sh"

# Replaces the content between a WITHIN_APP:$name:start/end marker pair
override_block() {
    local name="$1" body_file="$2"
    local start="# WITHIN_APP:${name}:start" end="# WITHIN_APP:${name}:end"
    if ! grep -qF "$start" "$LAUNCH_SH"; then
        echo "[!] $start not found in launch.sh - app override skipped." >&2
        return 0
    fi
    awk -v start="$start" -v end="$end" -v bodyfile="$body_file" '
        index($0, start) { print; while ((getline line < bodyfile) > 0) print line; skip=1; next }
        index($0, end) { skip=0 }
        !skip { print }
    ' "$LAUNCH_SH" > "$LAUNCH_SH.new" && mv "$LAUNCH_SH.new" "$LAUNCH_SH" && chmod +x "$LAUNCH_SH"
}

cat > "$BUILD_TMP/body_close_window.sh" << 'EOF'
# Terminal won't close a window with a foreground process still running
close_window() {
    local current_tty
    current_tty="$(tty)"
    (
        sleep 1
        osascript -e "
        tell application \"Terminal\"
            repeat with w in windows
                if (tty of (first tab of w)) is equal to \"$current_tty\" then
                    close w
                end if
            end repeat
        end tell
        " > /dev/null 2>&1
    ) & disown
}
EOF
override_block close_window "$BUILD_TMP/body_close_window.sh"

cat > "$BUILD_TMP/body_abort_launch.sh" << 'EOF'
echo "" >&2
read -p "Press Enter to close this window..." _
close_window
exit 1
EOF
override_block abort_launch "$BUILD_TMP/body_abort_launch.sh"

cat > "$BUILD_TMP/body_proxy_already_running.sh" << 'EOF'
echo "[*] Reusing existing proxy."
START_PROXY=false
EOF
override_block proxy_already_running "$BUILD_TMP/body_proxy_already_running.sh"

cat > "$BUILD_TMP/body_after_game_launched.sh" << 'EOF'
close_window
EOF
override_block after_game_launched "$BUILD_TMP/body_after_game_launched.sh"

cat > "$BUILD_TMP/body_on_game_closed.sh" << 'EOF'
kill -INT $$ 2>/dev/null
while kill -0 $$ 2>/dev/null; do
    sleep 1
done
close_window
EOF
override_block on_game_closed "$BUILD_TMP/body_on_game_closed.sh"

# Sanity check - warn (don't fail the build) if something didn't take
grep -q "^close_window()" "$LAUNCH_SH" || echo "[!] close_window() wasn't inserted into launch.sh."

# 6. Inject the WoW icon
echo "[*] Injecting WoW icon..."
cp "$ICON_ICNS" "$APP_OUT/Contents/Resources/wow.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile wow" "$APP_OUT/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string wow" "$APP_OUT/Contents/Info.plist"

# 7. Re-sign after modifying the bundle
echo "[*] Re-signing..."
codesign -f -s - "$APP_OUT" || { echo "[!] codesign failed." >&2; exit 1; }
codesign --verify --deep --strict "$APP_OUT" || { echo "[!] codesign verification failed." >&2; exit 1; }

echo "[*] Done! $APP_NAME.app is ready."
