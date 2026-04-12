#!/bin/bash

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # custom_launcher/build/
LAUNCHER_DIR="$(dirname "$BUILD_DIR")"                      # custom_launcher/
BASE_DIR="$(dirname "$LAUNCHER_DIR")"                       # wow root

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

# 4. Copy custom_launcher content into the app bundle so it's self-contained
echo "[*] Including custom_launcher content in bundle..."
mkdir -p "$APP_OUT/Contents/Resources"
cp -R "$LAUNCHER_DIR/" "$APP_OUT/Contents/Resources/"
# Remove the build folder from the bundle to keep it clean
rm -rf "$APP_OUT/Contents/Resources/build"

# 5. Inject the WoW icon
echo "[*] Injecting WoW icon..."
cp "$ICON_ICNS" "$APP_OUT/Contents/Resources/wow.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile wow" "$APP_OUT/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string wow" "$APP_OUT/Contents/Info.plist"

# 6. Re-sign after modifying the bundle
echo "[*] Re-signing..."
codesign -f -s - "$APP_OUT"

# Clean up
rm -rf "$ICONSET" "$ICON_ICNS" /tmp/launcher.applescript

echo "[*] Done! $APP_NAME.app is ready."
