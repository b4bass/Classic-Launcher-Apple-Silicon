#!/bin/bash

# ========================================
# Path Definitions
# ========================================
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$LAUNCHER_DIR" == *".app/Contents/Resources" ]]; then
    BASE_DIR="$(dirname "$(dirname "$(dirname "$LAUNCHER_DIR")")")"
    WITHIN_APP_MODE=true
else
    BASE_DIR="$(dirname "$LAUNCHER_DIR")"
    WITHIN_APP_MODE=false
fi

WOW_APP="$BASE_DIR/_classic_era_/World of Warcraft Classic.app"
WOW_BIN="$WOW_APP/Contents/MacOS/World of Warcraft Classic"
WOW_BAK="${WOW_BIN}_bak"
WOW_WTF_DIR="$BASE_DIR/_classic_era_/WTF"
WOW_CONFIG="$WOW_WTF_DIR/Config.wtf"

XDELTA_BIN="$LAUNCHER_DIR/xdelta3/bin/xdelta3"
OPENSSL_DIR="$LAUNCHER_DIR/openssl-3.0.7"
PATCH_FILE="$BASE_DIR/build/40618.patch"
if [ $WITHIN_APP_MODE = true ]; then
    PATCH_FILE="$LAUNCHER_DIR/build/40618.patch"
fi

PROXY_DIR="$LAUNCHER_DIR/Proxy"
PROXY_BIN="$PROXY_DIR/HermesProxy"
PROXY_CONF="$PROXY_DIR/HermesProxy.config"
PROXY_PROC_NAME=$(basename "$PROXY_BIN")

USER_CONF="$LAUNCHER_DIR/40618.conf"

# We check both states so the script doesn't fail if already patched
UNPATCHED_HASH="200c4c54316fb801d6d4d07d7031bb2b43f1c2be"
PATCHED_HASH="eee46704fa257bb831f332d06e21064d9fee91b5"

if [ "$1" == "--checkpatch" ]; then
    if [ -f "$WOW_BIN" ]; then
        ACTUAL_HASH=$(shasum "$WOW_BIN" | awk '{print $1}')
        if [ "$ACTUAL_HASH" == "$PATCHED_HASH" ]; then
            echo "PATCHED"
        elif [ "$ACTUAL_HASH" == "$UNPATCHED_HASH" ]; then
            echo "UNPATCHED"
        else
            echo "ERROR"
        fi
    else
        echo "ERROR"
    fi
    exit 0
fi

echo "===================================="
echo "    WoW Classic 1.14.0 Patcher      "
echo "===================================="

# Handle --reset argument
RESET_MODE=false
PATCH_ONLY_MODE=false
if [ "$1" == "--reset" ]; then
    echo "[*] --reset flag detected. Clearing saved configuration and caches..."
    rm -f "$USER_CONF"
    rm -rf "$BASE_DIR/_classic_era_/Cache" "$BASE_DIR/_classic_era_/Logs"
    if [ -f "$PROXY_CONF" ]; then
        sed -i '' 's|<add key="ServerAddress" value="[^"]*" />|<add key="ServerAddress" value="127.0.0.1" />|g' "$PROXY_CONF"
    fi
    RESET_MODE=true
elif [ "$1" == "--patch" ]; then
    echo "[*] --patch flag detected. Ensuring binary is patched..."
    PATCH_ONLY_MODE=true
fi

# 1. Remove quarantine attributes from all downloaded files
echo "[*] Removing Apple quarantine security attributes..."
xattr -dr com.apple.quarantine "$BASE_DIR" 2>/dev/null

# Ensure binaries are executable
chmod +x "$WOW_BIN" "$XDELTA_BIN" "$PROXY_BIN" 2>/dev/null

# 2. Check Backup and Patch status
if [ ! -f "$WOW_BIN" ]; then
    echo "Error: WoW binary not found at $WOW_BIN"
    exit 1
fi

ACTUAL_HASH=$(shasum "$WOW_BIN" | awk '{print $1}')

if [ "$ACTUAL_HASH" == "$PATCHED_HASH" ]; then
    echo "[*] WoW binary is already patched. Skipping patch phase."

elif [ "$ACTUAL_HASH" == "$UNPATCHED_HASH" ]; then
    echo "[*] Unpatched WoW binary detected. Initializing patch process..."
    
    if [ ! -f "$PATCH_FILE" ]; then
        echo "Error: Patch file not found at $PATCH_FILE"
        exit 1
    fi

    if [ ! -f "$WOW_BAK" ]; then
        echo "[*] Creating backup..."
        cp "$WOW_BIN" "$WOW_BAK"
    fi

    # Patch binary using the correct syntax: xdelta3 -d -f -s <ORIG> <PATCH> <OUT>
    echo "[*] Patching WoW binary..."
    "$XDELTA_BIN" -d -f -s "$WOW_BAK" "$PATCH_FILE" "$WOW_BIN"
    
    if [ $? -eq 0 ]; then
        echo "[*] Patching successful!"
    else
        echo "Error: Failed to patch the binary."
        mv "$WOW_BAK" "$WOW_BIN"
        exit 1
    fi
else
    echo "error : patcher is expecting WoW Classic 1.14.0 (40618)"
    echo "Current file hash is : $ACTUAL_HASH"
    echo "Expected unpatched   : $UNPATCHED_HASH"
    echo "Expected patched     : $PATCHED_HASH"
    exit 1
fi

# Ensure WTF directory exists for config
mkdir -p "$WOW_WTF_DIR"
touch "$WOW_CONFIG"

if [ "$RESET_MODE" = true ] || [ "$PATCH_ONLY_MODE" = true ]; then
    if [ "$PATCH_ONLY_MODE" = true ]; then
        echo "[*] Patch check completed successfully."
    fi
    exit 0
fi

# 3. Handle User Configuration
if [ -f "$USER_CONF" ]; then
    echo "[*] Loading saved configuration from 40618.conf..."
    source "$USER_CONF"
else
    # Ask user for settings and save them
    echo ""
    echo "========= Connection Method ========="
    echo "  [Yes] -> via Connection Proxy      (for legacy/private servers)"
    echo "   No   -> Direct                    (for servers with native client support)"
    echo "====================================="
    read -p "Connect via Connection Proxy? [Y/n]: " USE_PROXY_INPUT
    
    # Matches y, Y, yes, Yes, or empty string (defaults to Yes)
    if [[ -z "$USE_PROXY_INPUT" ]] || [[ "$USE_PROXY_INPUT" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        SAVED_USE_PROXY=true
        echo "Example: logon.example.com or 127.0.0.1"
        read -p "Enter realmlist server address: " INPUT_IP
        SAVED_IP=${INPUT_IP:-127.0.0.1}
    else
        SAVED_USE_PROXY=false
        read -p "Enter bnetserver IP: " INPUT_IP
        SAVED_IP=${INPUT_IP:-127.0.0.1}
    fi
    
    # Save to file
    echo "SAVED_USE_PROXY=$SAVED_USE_PROXY" > "$USER_CONF"
    echo "SAVED_IP=\"$SAVED_IP\"" >> "$USER_CONF"
    echo "[*] Settings saved to 40618.conf. Use ./patcher.sh --reset to change them later."
fi

# Apply the loaded/saved configuration
if [ "$SAVED_USE_PROXY" = true ]; then
    echo "[*] Configuring Connection Proxy to point to $SAVED_IP..."
    if [ -f "$PROXY_CONF" ]; then
        sed -i '' 's|<add key="ServerAddress" value="[^"]*" />|<add key="ServerAddress" value="'"$SAVED_IP"'" />|g' "$PROXY_CONF"
    else
        echo "Warning: Proxy configuration not found at $PROXY_CONF."
    fi

    echo "[*] Configuring WoW to connect to local Proxy (127.0.0.1)..."
    if grep -q "^SET portal" "$WOW_CONFIG"; then
        sed -i '' 's/^SET portal.*/SET portal "127.0.0.1"/g' "$WOW_CONFIG"
    else
        echo 'SET portal "127.0.0.1"' >> "$WOW_CONFIG"
    fi

    LAUNCH_PROXY=true
else
    echo "[*] Configuring WoW to connect directly to $SAVED_IP..."
    if grep -q "^SET portal" "$WOW_CONFIG"; then
        sed -i '' 's/^SET portal.*/SET portal "'"$SAVED_IP"'"/g' "$WOW_CONFIG"
    else
        echo "SET portal \"$SAVED_IP\"" >> "$WOW_CONFIG"
    fi

    LAUNCH_PROXY=false
fi

# 4. Execution Phase
killall "$PROXY_PROC_NAME" 2>/dev/null
sleep 1

echo "[*] Launching World of Warcraft Classic..."
nohup "$WOW_BIN" > /dev/null 2>&1 &

if [ "$LAUNCH_PROXY" = true ]; then
    echo "[*] Connection Proxy running in this terminal (close it to stop proxy)..."
    echo "========================================"
    cd "$PROXY_DIR"
    export DYLD_LIBRARY_PATH="$OPENSSL_DIR"
    # Execute
    "$PROXY_BIN"
else
    echo "[*] Done! You can close this terminal."
fi
