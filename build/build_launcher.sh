#!/bin/bash

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # build/
BASE_DIR="$(dirname "$BUILD_DIR")"                         # wow root
LAUNCHER_DIR="$BASE_DIR/custom_launcher"                   # custom_launcher/
APP_NAME="WoW Classic Launcher"
APP_OUT="$BASE_DIR/$APP_NAME.app"
ICON_PNG="$BUILD_DIR/wow.png"
ICON_ICNS="/tmp/wow.icns"

# 1. Create .icns from .png (Required for high-quality bundle icons)
echo "[*] Creating icon from wow.png..."
ICONSET="/tmp/wow.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size     "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null 2>&1
    sips -z $((size*2)) $((size*2)) "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$ICON_ICNS"

# 2. Write the AppleScript source
# Using 'path to resource' ensures it finds the script inside the bundle
cat > /tmp/launcher.applescript << 'EOF'
set launchScript to POSIX path of (path to resource "launch.sh")

tell application "Terminal"
    activate
    do script "bash " & quoted form of launchScript
end tell
EOF

# 3. Compile into .app
echo "[*] Building $APP_NAME.app..."
rm -rf "$APP_OUT"
osacompile -o "$APP_OUT" /tmp/launcher.applescript

# 4. Copy content into the app bundle so it's self-contained
echo "[*] Including custom_launcher content in bundle..."
mkdir -p "$APP_OUT/Contents/Resources"
mkdir -p "$APP_OUT/Contents/Resources/build"
cp -R "$LAUNCHER_DIR/" "$APP_OUT/Contents/Resources/"
# keep the patch file in the build folder
cp "$BUILD_DIR/"*.patch "$APP_OUT/Contents/Resources/build/"

# Drop Finder metadata junk - never useful, never wanted
find "$APP_OUT/Contents/Resources" -name ".DS_Store" -delete

# 5. Swap in the app's own proxy/window behavior
LAUNCH_SH="$APP_OUT/Contents/Resources/launch.sh"
WITHIN_APP_BLOCK="/tmp/launch_within_app.sh"
cat > "$WITHIN_APP_BLOCK" << 'EOF'
proxy_already_running() {
    echo "[*] Reusing existing proxy."
    START_PROXY=false
}

announce_proxy_started() {
    echo "[*] Connection Proxy running..."
}

after_game_launched() {
    close_window
}

on_game_closed() {
    kill -INT $$ 2>/dev/null
    while kill -0 $$ 2>/dev/null; do
        sleep 1
    done
    close_window
}

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

awk -v block="$WITHIN_APP_BLOCK" '
    /# BUILD:WITHIN_APP_BEGIN/ { print; while ((getline line < block) > 0) print line; skip=1; next }
    /# BUILD:WITHIN_APP_END/   { skip=0 }
    !skip
' "$LAUNCH_SH" > "$LAUNCH_SH.new" && mv "$LAUNCH_SH.new" "$LAUNCH_SH"

# Warn if the markers weren't found - app just gets regular launch.sh behavior
grep -q "^close_window()" "$LAUNCH_SH" || echo "[!] BUILD:WITHIN_APP markers not found in launch.sh."

# 6. Inject the WoW icon
echo "[*] Injecting WoW icon..."
cp "$ICON_ICNS" "$APP_OUT/Contents/Resources/wow.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile wow" "$APP_OUT/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string wow" "$APP_OUT/Contents/Info.plist"

# 7. Re-sign after modifying the bundle
echo "[*] Re-signing..."
codesign -f -s - "$APP_OUT"

# Clean up
rm -rf "$ICONSET" "$ICON_ICNS" /tmp/launcher.applescript "$WITHIN_APP_BLOCK"

echo "[*] Done! $APP_NAME.app is ready."
