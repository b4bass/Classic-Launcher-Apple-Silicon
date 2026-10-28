#!/bin/bash
# Builds classicpatch.dylib (universal: arm64 + x86_64) from classicpatch.c, both in this patch folder.
# Needs only Apple's Command Line Tools (clang + codesign); nothing else to install.

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # launcher/build/patch/
OUT="$PATCH_DIR/classicpatch.dylib"

# Without the Command Line Tools, running clang would pop up Apple's installer instead - say so up front
if ! xcode-select -p >/dev/null 2>&1; then
    echo "[!] Building classicpatch.dylib needs Apple's Command Line Tools. Install them with:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi
[ -f "$PATCH_DIR/classicpatch.c" ] && [ -f "$PATCH_DIR/arctium_data.h" ] || { echo "[!] Sources not found in $PATCH_DIR" >&2; exit 1; }

echo "[*] Building classicpatch.dylib..."
clang -arch arm64 -arch x86_64 -dynamiclib -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=10.13 \
    -framework CoreFoundation -install_name @executable_path/../Frameworks/classicpatch.dylib \
    -o "$OUT" "$PATCH_DIR/classicpatch.c" || { echo "[!] Compiling classicpatch.dylib failed." >&2; exit 1; }
codesign -f -s - "$OUT" || { echo "[!] codesign failed." >&2; exit 1; }
echo "[*] Done: $OUT"
