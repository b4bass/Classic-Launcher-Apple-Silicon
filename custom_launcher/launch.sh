#!/bin/bash

# --- Global State Defaults ---
WITHIN_APP_MODE=false
RESET_MODE=false
PATCH_ONLY_MODE=false
CONFIG_EXISTS=false
PROXY_ARGS_PASSED=false
SAVED_USE_PROXY=false
LAUNCH_PROXY=false

# --- Path Definitions ---
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$LAUNCHER_DIR" == *".app/Contents/Resources" ]]; then
    BASE_DIR="$(dirname "$(dirname "$(dirname "$LAUNCHER_DIR")")")"
    WITHIN_APP_MODE=true
else
    BASE_DIR="$(dirname "$LAUNCHER_DIR")"
fi

WOW_APP="$BASE_DIR/_classic_era_/World of Warcraft Classic.app"
WOW_BIN="$WOW_APP/Contents/MacOS/World of Warcraft Classic"
WOW_BAK="${WOW_BIN}_bak"
WOW_WTF_DIR="$BASE_DIR/_classic_era_/WTF"
WOW_CONFIG="$WOW_WTF_DIR/Config.wtf"

XDELTA_BIN="$LAUNCHER_DIR/xdelta3/bin/xdelta3"
OPENSSL_DIR="$LAUNCHER_DIR/openssl-3.0.7"
PATCH_FILE="$BASE_DIR/build/40618.patch"
if [ "$WITHIN_APP_MODE" = true ]; then
    PATCH_FILE="$LAUNCHER_DIR/build/40618.patch"
fi

PROXY_DIR="$LAUNCHER_DIR/proxy"
PROXY_BIN="$PROXY_DIR/HermesProxy"
USER_CONF="$LAUNCHER_DIR/40618.conf"

UNPATCHED_HASH="200c4c54316fb801d6d4d07d7031bb2b43f1c2be"
PATCHED_HASH="eee46704fa257bb831f332d06e21064d9fee91b5"

# --- Argument Parsing ---
CONNECTION_MODE=""
DIRECT_BNET_IP=""
CUSTOM_PROXY_BIN=""
PROXY_CONFIG_FILE=""
declare -a PROXY_SET_ARGS
EXTRACTED_SERVER_ADDRESS=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --checkpatch)
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
            ;;
        --reset)
            RESET_MODE=true
            shift
            ;;
        --patch)
            PATCH_ONLY_MODE=true
            shift
            ;;
        --bnet)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                DIRECT_BNET_IP="$2"
                shift 2
            else
                DIRECT_BNET_IP="127.0.0.1"
                shift
            fi
            ;;
        --switchproxy)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                CUSTOM_PROXY_BIN="$2"
                PROXY_ARGS_PASSED=true
                shift 2
            else
                echo "Error: --switchproxy requires a binary name." >&2;
                exit 1
            fi
            ;;
        --config)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                PROXY_CONFIG_FILE="$2"
                PROXY_ARGS_PASSED=true
                shift 2
            else
                echo "Error: --config requires a configuration file path." >&2;
                exit 1
            fi
            ;;
        --set)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                PROXY_SET_ARGS+=("$2")
                PROXY_ARGS_PASSED=true
                
                # Extract ServerAddress if passed, to update 40618.conf
                if [[ "$2" == ServerAddress=* ]]; then
                    EXTRACTED_SERVER_ADDRESS="${2#*=}"
                fi
                shift 2
            else
                echo "Error: --set requires a key=value pair." >&2;
                exit 1
            fi
            ;;
        *)
            echo "Unknown parameter passed: $1"
            exit 1
            ;;
    esac
done

echo "===================================="
echo "    WoW Classic 1.14.0 Patcher      "
echo "===================================="

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
    if [ "$RESET_MODE" = true ]; then
        echo "[*] --reset flag detected. Clearing saved configuration, caches..."
        rm -f "$USER_CONF"
        rm -rf "$BASE_DIR/_classic_era_/Cache" "$BASE_DIR/_classic_era_/Logs"
        # Reset portal
        if grep -q "^SET portal" "$WOW_CONFIG"; then
            sed -i '' 's/^SET portal.*/SET portal "127.0.0.1"/g' "$WOW_CONFIG"
        else
            echo 'SET portal "127.0.0.1"' >> "$WOW_CONFIG"
        fi
    fi
    if [ "$PATCH_ONLY_MODE" = true ]; then
        echo "[*] Patch check completed successfully."
    fi
    exit 0
fi

# 3. Handle User Configuration
if [ -f "$USER_CONF" ]; then
    echo "[*] Loading saved configuration from 40618.conf..."
    source "$USER_CONF"
    CONFIG_EXISTS=true
fi

# If user passed --bnet <ip>. Force direct.
if [ -n "$DIRECT_BNET_IP" ]; then
    CONNECTION_MODE="DIRECT"
    
    # Write to config if missing, if previously set to proxy, or IP changed
    if [ "$CONFIG_EXISTS" = false ] || [ "$SAVED_USE_PROXY" = true ] || [ "$SAVED_IP" != "$DIRECT_BNET_IP" ]; then
        SAVED_USE_PROXY=false
        SAVED_IP="$DIRECT_BNET_IP"
        echo "SAVED_USE_PROXY=$SAVED_USE_PROXY" > "$USER_CONF"
        echo "SAVED_IP=\"$SAVED_IP\"" >> "$USER_CONF"
        echo "[*] Updated 40618.conf: Switched to Direct Connection ($SAVED_IP)."
    fi

# If user passed Proxy arguments. Force Proxy.
elif [ "$PROXY_ARGS_PASSED" = true ]; then
    CONNECTION_MODE="PROXY"
    
    # Determine the ServerAddress to save
    NEW_SAVED_IP="$SAVED_IP"
    if [ -n "$EXTRACTED_SERVER_ADDRESS" ]; then
        NEW_SAVED_IP="$EXTRACTED_SERVER_ADDRESS"
    elif [ -z "$SAVED_IP" ]; then
        NEW_SAVED_IP="127.0.0.1" # Fallback if no config and no explicit ServerAddress
    fi
    
    # Write to config if missing, if previously set to direct, or IP changed
    if [ "$CONFIG_EXISTS" = false ] || [ "$SAVED_USE_PROXY" = false ] || [ "$SAVED_IP" != "$NEW_SAVED_IP" ]; then
        SAVED_USE_PROXY=true
        SAVED_IP="$NEW_SAVED_IP"
        echo "SAVED_USE_PROXY=$SAVED_USE_PROXY" > "$USER_CONF"
        echo "SAVED_IP=\"$SAVED_IP\"" >> "$USER_CONF"
        echo "[*] Updated 40618.conf: Switched to Proxy Connection ($SAVED_IP)."
    fi

# If normal run (No overriding arguments)
else
    if [ "$CONFIG_EXISTS" = true ]; then
        if [ "$SAVED_USE_PROXY" = true ]; then CONNECTION_MODE="PROXY"
        else
            CONNECTION_MODE="DIRECT"
        fi
    else
        echo ""
        echo "========= Connection Method ========="
        echo "  [Yes] -> via Connection Proxy      (for legacy/private servers)"
        echo "   No   -> Direct                    (for servers with native client support)"
        echo "====================================="
        read -p "Connect via Connection Proxy? [Y/n]: " USE_PROXY_INPUT
        
        # Matches y, Y, yes, Yes, or empty string (defaults to Yes)
        if [[ -z "$USE_PROXY_INPUT" ]] || [[ "$USE_PROXY_INPUT" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            CONNECTION_MODE="PROXY"
            SAVED_USE_PROXY=true
            echo "Example: logon.example.com or 127.0.0.1"
            read -p "Enter realmlist server address: " INPUT_IP
        else
            CONNECTION_MODE="DIRECT"
            SAVED_USE_PROXY=false
            read -p "Enter bnetserver IP: " INPUT_IP
        fi
        
        SAVED_IP=${INPUT_IP:-127.0.0.1}    
        # Save to file
        echo "SAVED_USE_PROXY=$SAVED_USE_PROXY" > "$USER_CONF"
        echo "SAVED_IP=\"$SAVED_IP\"" >> "$USER_CONF"
        echo "[*] Settings saved to 40618.conf. Use ./launch.sh --reset to change them later."
    fi
fi

# Apply the loaded/saved configuration

if [ "$CONNECTION_MODE" = "PROXY" ]; then
    LAUNCH_PROXY=true

    # Update Game Config to Proxy IP
    echo "[*] Configuring WoW to connect to local Proxy (127.0.0.1)..."
    if grep -q "^SET portal" "$WOW_CONFIG"; then
        sed -i '' 's/^SET portal.*/SET portal "127.0.0.1"/g' "$WOW_CONFIG"
    else
        echo 'SET portal "127.0.0.1"' >> "$WOW_CONFIG"
    fi

    # Determine Proxy Binary
    if [ -n "$CUSTOM_PROXY_BIN" ]; then
        if [ -f "$PROXY_DIR/$CUSTOM_PROXY_BIN" ]; then
            PROXY_BIN="$PROXY_DIR/$CUSTOM_PROXY_BIN"
        else
            echo "Warning: Custom proxy '$CUSTOM_PROXY_BIN' not found. Using default."
        fi
    fi

    # Build HermesProxy Command Array
    PROXY_COMMAND=("$PROXY_BIN")

    if [ -n "$PROXY_CONFIG_FILE" ]; then
        PROXY_COMMAND+=("--config" "$PROXY_CONFIG_FILE")
    fi

    # Add Default Client Build
    PROXY_COMMAND+=("--set" "ClientBuild=40618")

    # Ensure a ServerAddress is present if no config file is passed
    if [ -z "$PROXY_CONFIG_FILE" ]; then
        HAS_SERVER_ADDRESS=false
        for arg in "${PROXY_SET_ARGS[@]}"; do
            if [[ "$arg" == ServerAddress=* ]]; then
                HAS_SERVER_ADDRESS=true; break
            fi
        done
        if [ "$HAS_SERVER_ADDRESS" = false ] && [ -n "$SAVED_IP" ]; then
            PROXY_COMMAND+=("--set" "ServerAddress=$SAVED_IP")
        fi
    fi

    # Inject manual --set overrides into array (replacing duplicates if any)
    for set_arg in "${PROXY_SET_ARGS[@]}"; do
        key=$(echo "$set_arg" | cut -d= -f1)
        found=false
        for i in "${!PROXY_COMMAND[@]}"; do
            if [[ "${PROXY_COMMAND[$i]}" == "--set" && "${PROXY_COMMAND[$i+1]}" =~ ^$key= ]]; then
                PROXY_COMMAND[$i+1]="$set_arg"
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            PROXY_COMMAND+=("--set" "$set_arg")
        fi
    done

elif [ "$CONNECTION_MODE" = "DIRECT" ]; then
    echo "[*] Configuring WoW to connect directly to $SAVED_IP..."
    if grep -q "^SET portal" "$WOW_CONFIG"; then
        sed -i '' 's/^SET portal.*/SET portal "'"$SAVED_IP"'"/g' "$WOW_CONFIG"
    else
        echo "SET portal \"$SAVED_IP\"" >> "$WOW_CONFIG"
    fi
fi

# 4. Execution Phase
PROXY_PROC_NAME=$(basename "$PROXY_BIN")
killall "$PROXY_PROC_NAME" 2>/dev/null
sleep 1

echo "[*] Launching World of Warcraft Classic..."
nohup "$WOW_BIN" > /dev/null 2>&1 &

if [ "$LAUNCH_PROXY" = true ]; then
    FULL_PROXY_CMD=("${PROXY_COMMAND[@]}")
    
    echo "Executing proxy command: ${FULL_PROXY_CMD[*]}"
    echo "[*] Connection Proxy running in this terminal (close it to stop proxy)..."
    echo "========================================"
    
    cd "$PROXY_DIR"
    export DYLD_LIBRARY_PATH="$OPENSSL_DIR"
    # Execute
    "${FULL_PROXY_CMD[@]}"
else
    echo "[*] Done! You can close this terminal."
fi
