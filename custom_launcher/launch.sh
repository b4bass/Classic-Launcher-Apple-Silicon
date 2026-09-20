#!/bin/bash

# --- Global State Defaults ---
WITHIN_APP=false
RESET=false
PATCH_ONLY=false
GET_MISSING=false
CONFIG_EXISTS=false
PROXY_ARGS_PASSED=false
SAVED_USE_PROXY=false
LAUNCH_PROXY=false

# --- Path Definitions ---
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$LAUNCHER_DIR" == *".app/Contents/Resources" ]]; then
    BASE_DIR="$(dirname "$(dirname "$(dirname "$LAUNCHER_DIR")")")"
    WITHIN_APP=true
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
if [ "$WITHIN_APP" = true ]; then
    PATCH_FILE="$LAUNCHER_DIR/build/40618.patch"
fi

PROXY_DIR="$LAUNCHER_DIR/proxy"
PROXY_BIN="$PROXY_DIR/HermesProxy"
USER_CONF="$LAUNCHER_DIR/40618.conf"

SURGE_BIN="$LAUNCHER_DIR/surge/surge"
MIRROR_LIST_FILE="$LAUNCHER_DIR/surge/archives.txt"

UNPATCHED_HASH="200c4c54316fb801d6d4d07d7031bb2b43f1c2be"
PATCHED_HASH="eee46704fa257bb831f332d06e21064d9fee91b5"

# --- Helpers ---
sha1_file() {
    shasum "$1" 2>/dev/null | awk '{print $1}'
}

# Called right before each binary/dir is actually used, not on every launch
strip_quarantine() {
    for path in "$@"; do
        if [ -d "$path" ]; then
            xattr -dr com.apple.quarantine "$path" 2>/dev/null
        else
            xattr -d com.apple.quarantine "$path" 2>/dev/null
        fi
    done
    return 0
}

validate_server_address() {
    case "$1" in
        '') return 1 ;;
        *[!A-Za-z0-9.-]*) return 1 ;;
    esac
    return 0
}

set_portal() {
    local portal="$1"
    if grep -q '^SET portal' "$WOW_CONFIG"; then
        sed -i '' "s|^SET portal.*|SET portal \"$portal\"|g" "$WOW_CONFIG"
    else
        printf 'SET portal "%s"\n' "$portal" >> "$WOW_CONFIG"
    fi
}

load_config() {
    [ -f "$USER_CONF" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            SAVED_USE_PROXY)
                case "$value" in
                    true|false) SAVED_USE_PROXY="$value" ;;
                esac
                ;;
            SAVED_IP)
                validate_server_address "$value" && SAVED_IP="$value"
                ;;
        esac
    done < "$USER_CONF"
    CONFIG_EXISTS=true
    return 0
}

save_config() {
    local tmp="${USER_CONF}.tmp.$$"
    {
        printf 'SAVED_USE_PROXY=%s\n' "$SAVED_USE_PROXY"
        printf 'SAVED_IP=%s\n' "$SAVED_IP"
    } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$USER_CONF"
}

# --- Argument Parsing ---
CONNECTION_TYPE=""
DIRECT_BNET_IP=""
CUSTOM_PROXY_BIN=""
PROXY_CONFIG_FILE=""
declare -a PROXY_SET_ARGS
EXTRACTED_SERVER_ADDRESS=""
GET_URL_ARG=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: launch.sh [option]"
            echo ""
            echo "  (no options)           Patch if needed, then launch and connect"
            echo "  --checkpatch           Print PATCHED, UNPATCHED, or ERROR, and exit"
            echo "  --patch                Patch the binary only, don't launch"
            echo "  --reset                Clear saved connection config and caches"
            echo "  --getmissing [url]     Fetch an untouched 40618 client (prompts for a mirror if no url given)"
            echo "  --bnet [ip]            Connect directly, bypassing the proxy (default ip: 127.0.0.1)"
            echo "  --switchproxy <name>   Use a custom proxy binary from the proxy/ folder"
            echo "  --config <file>        Pass a custom proxy configuration file"
            echo "  --set <key=value>      Pass a proxy override, repeatable"
            echo "  --help, -h             Show this help"
            exit 0
            ;;
        --checkpatch)
            if [ -f "$WOW_BIN" ]; then
                ACTUAL_HASH=$(sha1_file "$WOW_BIN")
                if [ "$ACTUAL_HASH" == "$PATCHED_HASH" ]; then
                    echo "PATCHED"
                    exit 0
                elif [ "$ACTUAL_HASH" == "$UNPATCHED_HASH" ]; then
                    echo "UNPATCHED"
                    exit 1
                else
                    echo "ERROR"
                    exit 2
                fi
            else
                echo "ERROR"
                exit 3
            fi
            ;;
        --reset)
            RESET=true
            shift
            ;;
        --patch)
            PATCH_ONLY=true
            shift
            ;;
        --getmissing)
            GET_MISSING=true
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                GET_URL_ARG="$2"
                shift 2
            else
                shift
            fi
            ;;
        --bnet)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                if ! validate_server_address "$2"; then
                    echo "[!] --bnet: '$2' is not a valid IP or hostname." >&2
                    exit 1
                fi
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
                echo "[!] --switchproxy requires a binary name." >&2
                exit 1
            fi
            ;;
        --config)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                PROXY_CONFIG_FILE="$2"
                PROXY_ARGS_PASSED=true
                shift 2
            else
                echo "[!] --config requires a configuration file path." >&2
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
                    if ! validate_server_address "$EXTRACTED_SERVER_ADDRESS"; then
                        echo "[!] --set ServerAddress: '$EXTRACTED_SERVER_ADDRESS' is not a valid IP or hostname." >&2
                        exit 1
                    fi
                fi
                shift 2
            else
                echo "[!] --set requires a key=value pair." >&2
                exit 1
            fi
            ;;
        *)
            echo "[!] Unknown parameter passed: $1" >&2
            exit 1
            ;;
    esac
done

# Compiled.app-only, build_launcher.sh fills this in
# WITHIN_APP:close_window:start
# WITHIN_APP:close_window:end

# Called from many places below, so the check lives here once
abort_launch() {
    # WITHIN_APP:abort_launch:start
    exit 1
    # WITHIN_APP:abort_launch:end
}

echo "======================================="
echo "     WoW Classic 1.14.0 - Patcher      "
echo "======================================="

# Only used if the client turns out to be missing below
run_get_client() {
    if [ ! -f "$SURGE_BIN" ]; then
        echo "[!] Required surge binary not found at $SURGE_BIN" >&2
        echo "    Place it there (and chmod +x it), then retry." >&2
        abort_launch
    fi
    strip_quarantine "$LAUNCHER_DIR/surge"
    chmod +x "$SURGE_BIN" 2>/dev/null

    # Normally only reachable via --getmissing on an existing install (CLI only)
    if [ -f "$WOW_BIN" ]; then
        echo "[!] A client already exists at $WOW_BIN" >&2
        echo "    --getmissing is only for an initial, empty install. Remove client files first" >&2
        echo "    if you really want to fetch it again." >&2
        abort_launch
    fi

    if pgrep -x "$(basename "$SURGE_BIN")" > /dev/null 2>&1; then
        echo "[*] A download is already in progress - wait for it to finish, then retry."
        abort_launch
    fi

    # --- Mirror Selection ---
    if [ -n "$GET_URL_ARG" ]; then
        SELECTED_URL="$GET_URL_ARG"
    else
        declare -a MIRRORS
        if [ -f "$MIRROR_LIST_FILE" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="$(echo "$line" | tr -d '\r')"
                [ -z "$line" ] && continue
                [[ "$line" == \#* ]] && continue
                MIRRORS+=("$line")
            done < "$MIRROR_LIST_FILE"
        fi
        # Ships bundled with archives.txt - only empty if someone deleted it
        if [ ${#MIRRORS[@]} -eq 0 ]; then
            echo "[!] No mirrors listed in $MIRROR_LIST_FILE" >&2
            echo "    Add at least one URL to that file (one per line), then retry." >&2
            abort_launch
        fi

        if [ ${#MIRRORS[@]} -eq 1 ]; then
            SELECTED_URL="${MIRRORS[0]}"
        else
            echo ""
            echo "Select a mirror:"
            for i in "${!MIRRORS[@]}"; do
                echo "  $((i + 1))) ${MIRRORS[$i]}"
            done
            read -p "Enter choice [1-${#MIRRORS[@]}]: " MIRROR_CHOICE
            if ! [[ "$MIRROR_CHOICE" =~ ^[0-9]+$ ]] || [ "$MIRROR_CHOICE" -lt 1 ] || [ "$MIRROR_CHOICE" -gt "${#MIRRORS[@]}" ]; then
                echo "[!] Invalid selection." >&2
                abort_launch
            fi
            SELECTED_URL="${MIRRORS[$((MIRROR_CHOICE - 1))]}"
        fi
    fi

    case "$SELECTED_URL" in
        http://*|https://*) ;;
        *)
            echo "[!] Mirror URL must start with http:// or https://: $SELECTED_URL" >&2
            abort_launch
            ;;
    esac

    # Strip any query string/fragment before using it as a filename
    ZIP_NAME="$(basename "${SELECTED_URL%%[?#]*}")"

    GET_TMP="$(mktemp -d)"
    trap 'rm -rf "$GET_TMP"' EXIT

    echo "[*] Fetching client (this may take a while)..."
    echo "    $SELECTED_URL"

    # Snapshot existing transfer IDs to spot the new one later
    BEFORE_IDS="$("$SURGE_BIN" ls 2>/dev/null | tail -n +3 | awk '{print $1}')"

    # Run headless in the background, silence its own status chatter
    "$SURGE_BIN" server "$SELECTED_URL" --output "$GET_TMP" --exit-when-done >/dev/null 2>&1 &
    SURGE_PID=$!

    # Find our transfer's ID among any new entries
    sleep 2
    DL_ID=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        DL_ID="$("$SURGE_BIN" ls 2>/dev/null | tail -n +3 | awk '{print $1}' \
            | grep -vFx -f <(printf '%s\n' "$BEFORE_IDS") | head -1)"
        [ -n "$DL_ID" ] && break
        sleep 1
    done

    # Redraw a single status line in place, no table, no clearing
    while kill -0 "$SURGE_PID" 2>/dev/null; do
        if [ -n "$DL_ID" ]; then
            LINE="$("$SURGE_BIN" ls 2>/dev/null | awk -v id="$DL_ID" '$1 == id')"
            [ -n "$LINE" ] && printf '\r\033[K%s' "$LINE"
        fi
        sleep 2
    done
    echo ""

    wait "$SURGE_PID"
    if [ $? -ne 0 ]; then
        echo "[!] Fetching the client failed." >&2
        abort_launch
    fi

    ZIP_PATH="$GET_TMP/$ZIP_NAME"
    if [ ! -f "$ZIP_PATH" ]; then
        echo "[!] Expected file not found at $ZIP_PATH" >&2
        echo "    (check the mirror - it may be dead: $SELECTED_URL)" >&2
        abort_launch
    fi

    echo "[*] Extracting client archive..."
    mkdir -p "$GET_TMP/extracted"
    if ! ditto -xk "$ZIP_PATH" "$GET_TMP/extracted"; then
        echo "[!] Failed to extract $ZIP_PATH" >&2
        abort_launch
    fi

    # Mirrors wrap this differently - find whichever folder actually holds the client
    WOW_BIN_SUBPATH="${WOW_BIN#"$BASE_DIR/"}"
    EXTRACTED_ROOT="$GET_TMP/extracted"
    if [ ! -f "$EXTRACTED_ROOT/$WOW_BIN_SUBPATH" ] || [ ! -d "$EXTRACTED_ROOT/Data" ]; then
        EXTRACTED_ROOT=""
        for entry in "$GET_TMP/extracted"/*/; do
            [ -f "${entry}${WOW_BIN_SUBPATH}" ] && [ -d "${entry}Data" ] && EXTRACTED_ROOT="${entry%/}" && break
        done
    fi
    if [ -z "$EXTRACTED_ROOT" ]; then
        echo "[!] Unexpected archive layout (_classic_era_/Data not found)." >&2
        abort_launch
    fi

    echo "[*] Installing client into $BASE_DIR..."
    if ! ditto "$EXTRACTED_ROOT" "$BASE_DIR"; then
        echo "[!] Failed to install the client into $BASE_DIR" >&2
        abort_launch
    fi

    echo "[*] Client fetched and installed."
    rm -rf "$GET_TMP"
    trap - EXIT
    # Fall through into the patch-and-launch flow below instead of exiting
}

# 1. Make sure the client is actually here
if [ "$GET_MISSING" = true ]; then
    run_get_client
    # --getmissing only downloads and extracts
    echo "    Run again to patch and connect."
    exit 0
fi

if [ ! -f "$WOW_BIN" ]; then
    echo "[!] WoW binary not found at $WOW_BIN" >&2
    echo ""
    echo "====== Get missing client files ======="
    echo "  [Yes] -> Fetch the 40618 client"
    echo "   No   -> Exit, fetch it manually later"
    echo "======================================="
    read -p "Fetch the 40618 client now? [Y/n]: " GET_MISSING_INPUT
    if [[ -z "$GET_MISSING_INPUT" ]] || [[ "$GET_MISSING_INPUT" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        run_get_client
    fi
    if [ ! -f "$WOW_BIN" ]; then
        abort_launch
    fi
fi

# 2. Check Backup and Patch status
ACTUAL_HASH=$(sha1_file "$WOW_BIN")
if [ "$ACTUAL_HASH" == "$PATCHED_HASH" ]; then
    echo "[*] WoW binary is already patched. Skipping patch phase."
elif [ "$ACTUAL_HASH" == "$UNPATCHED_HASH" ]; then
    echo "[*] Unpatched WoW binary detected. Initializing patch process..."
    strip_quarantine "$WOW_BIN" "$LAUNCHER_DIR/xdelta3"
    chmod +x "$WOW_BIN" "$XDELTA_BIN" 2>/dev/null
    if [ ! -f "$PATCH_FILE" ]; then
        echo "[!] Patch file not found at $PATCH_FILE" >&2
        abort_launch
    fi

    if [ -f "$WOW_BAK" ]; then
        BACKUP_HASH=$(sha1_file "$WOW_BAK")
        if [ "$BACKUP_HASH" != "$UNPATCHED_HASH" ]; then
            echo "[!] Existing backup at $WOW_BAK doesn't match the expected unpatched client." >&2
            abort_launch
        fi
    else
        echo "[*] Creating backup..."
        cp "$WOW_BIN" "$WOW_BAK"
    fi

    # Patch into a temp file first, so a crash mid-patch can't corrupt $WOW_BIN
    echo "[*] Patching WoW binary..."
    WOW_PATCH_TMP="${WOW_BIN}.patching"
    rm -f "$WOW_PATCH_TMP"
    "$XDELTA_BIN" -d -f -s "$WOW_BAK" "$PATCH_FILE" "$WOW_PATCH_TMP"
    XDELTA_STATUS=$?

    if [ $XDELTA_STATUS -eq 0 ] && [ -f "$WOW_PATCH_TMP" ] && [ "$(sha1_file "$WOW_PATCH_TMP")" == "$PATCHED_HASH" ]; then
        chmod +x "$WOW_PATCH_TMP"
        mv -f "$WOW_PATCH_TMP" "$WOW_BIN"
        echo "[*] Patching successful!"
    else
        echo "[!] Failed to patch the binary." >&2
        rm -f "$WOW_PATCH_TMP"
        abort_launch
    fi
else
    echo "[!] Patcher is expecting WoW Classic 1.14.0 (40618)" >&2
    echo "    Current file hash: $ACTUAL_HASH" >&2
    echo "    Expected unpatched: $UNPATCHED_HASH" >&2
    echo "    Expected patched: $PATCHED_HASH" >&2
    abort_launch
fi

# Ensure WTF directory exists for config
mkdir -p "$WOW_WTF_DIR"
touch "$WOW_CONFIG"

if [ "$RESET" = true ] || [ "$PATCH_ONLY" = true ]; then
    if [ "$RESET" = true ]; then
        echo "[*] --reset flag detected. Clearing saved configuration, caches..."
        rm -f "$USER_CONF"
        rm -rf "$BASE_DIR/_classic_era_/Cache" "$BASE_DIR/_classic_era_/Logs"
        set_portal "127.0.0.1"
        # Manual escape hatch - everything below is normally only touched on first use
        strip_quarantine "$WOW_BIN" "$LAUNCHER_DIR/xdelta3" "$LAUNCHER_DIR/surge" "$PROXY_DIR" "$OPENSSL_DIR"
        chmod +x "$WOW_BIN" "$XDELTA_BIN" "$SURGE_BIN" "$PROXY_BIN" 2>/dev/null
    fi
    if [ "$PATCH_ONLY" = true ]; then
        echo "[*] Patch check completed successfully."
    fi
    exit 0
fi

# 3. Handle User Configuration
if load_config; then
    echo "[*] Loading saved configuration from 40618.conf..."
fi

# If user passed --bnet <ip>. Force direct.
if [ -n "$DIRECT_BNET_IP" ]; then
    CONNECTION_TYPE="DIRECT"

    # Write to config if missing, if previously set to proxy, or IP changed
    if [ "$CONFIG_EXISTS" = false ] || [ "$SAVED_USE_PROXY" = true ] || [ "$SAVED_IP" != "$DIRECT_BNET_IP" ]; then
        SAVED_USE_PROXY=false
        SAVED_IP="$DIRECT_BNET_IP"
        save_config
        echo "[*] Updated 40618.conf: Switched to Direct Connection ($SAVED_IP)."
    fi

# If user passed Proxy arguments. Force Proxy.
elif [ "$PROXY_ARGS_PASSED" = true ]; then
    CONNECTION_TYPE="PROXY"

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
        save_config
        echo "[*] Updated 40618.conf: Switched to Proxy Connection ($SAVED_IP)."
    fi

# If normal run (No overriding arguments)
else
    if [ "$CONFIG_EXISTS" = true ]; then
        if [ "$SAVED_USE_PROXY" = true ]; then CONNECTION_TYPE="PROXY"
        else
            CONNECTION_TYPE="DIRECT"
        fi
    else
        echo ""
        echo "========== Connection Method =========="
        echo "  [Yes] -> via Connection Proxy  (for legacy/private servers)"
        echo "   No   -> Direct                (for servers with native client support)"
        echo "======================================="
        read -p "Connect via Connection Proxy? [Y/n]: " USE_PROXY_INPUT

        # Matches y, Y, yes, Yes, or empty string (defaults to Yes)
        if [[ -z "$USE_PROXY_INPUT" ]] || [[ "$USE_PROXY_INPUT" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            CONNECTION_TYPE="PROXY"
            SAVED_USE_PROXY=true
            echo "Example: logon.example.com or 127.0.0.1"
            read -p "Enter realmlist server address: " INPUT_IP
        else
            CONNECTION_TYPE="DIRECT"
            SAVED_USE_PROXY=false
            read -p "Enter bnetserver IP: " INPUT_IP
        fi

        SAVED_IP=${INPUT_IP:-127.0.0.1}
        if ! validate_server_address "$SAVED_IP"; then
            echo "[!] '$SAVED_IP' is not a valid IP or hostname." >&2
            abort_launch
        fi
        # Save to file
        save_config
        echo "[*] Settings saved to 40618.conf. Use ./launch.sh --reset to change them later."
    fi
fi

# Apply the loaded/saved configuration

if [ "$CONNECTION_TYPE" = "PROXY" ]; then
    LAUNCH_PROXY=true

    # Update Game Config to Proxy IP
    echo "[*] Configuring WoW to connect to local Proxy (127.0.0.1)..."
    set_portal "127.0.0.1"

    # Determine Proxy Binary
    if [ -n "$CUSTOM_PROXY_BIN" ]; then
        if [ -f "$PROXY_DIR/$CUSTOM_PROXY_BIN" ]; then
            PROXY_BIN="$PROXY_DIR/$CUSTOM_PROXY_BIN"
        else
            echo "[!] Custom proxy '$CUSTOM_PROXY_BIN' not found. Using default." >&2
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
        key="${set_arg%%=*}"
        found=false
        for i in "${!PROXY_COMMAND[@]}"; do
            if [[ "${PROXY_COMMAND[$i]}" == "--set" && "${PROXY_COMMAND[$i+1]}" == "$key="* ]]; then
                PROXY_COMMAND[$i+1]="$set_arg"
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            PROXY_COMMAND+=("--set" "$set_arg")
        fi
    done

elif [ "$CONNECTION_TYPE" = "DIRECT" ]; then
    echo "[*] Configuring WoW to connect directly to $SAVED_IP..."
    set_portal "$SAVED_IP"
fi

# 4. Execution Phase
# Job control on, so the game gets its own process group, away from Ctrl+C
set -m

START_PROXY=true
PROXY_PROC_NAME=$(basename "$PROXY_BIN")

# CLI default prompts interactively - the built .app reuses silently
proxy_already_running() {
    # WITHIN_APP:proxy_already_running:start
    read -p "A proxy is already running. Keep it running? [Y/n]: " KEEP_RUNNING
    [[ -z "$KEEP_RUNNING" ]] && KEEP_RUNNING="Y"

    if [[ "$KEEP_RUNNING" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "[*] Keeping the existing proxy running."
        START_PROXY=false
    else
        killall "$PROXY_PROC_NAME" 2>/dev/null
        sleep 1
    fi
    # WITHIN_APP:proxy_already_running:end
}

# CLI default leaves the proxy running - the built .app also stops it
on_game_closed() {
    # WITHIN_APP:on_game_closed:start
    if kill -0 $$ 2>/dev/null; then
        echo ""
        echo "[*] Game closed. Proxy is still running - Ctrl+C to stop it."
    fi
    # WITHIN_APP:on_game_closed:end
}

# CLI default just prints a message - the built .app closes its window instead
after_game_launched() {
    # WITHIN_APP:after_game_launched:start
    echo "[*] Done! You can close this terminal."
    # WITHIN_APP:after_game_launched:end
}

if [ "$LAUNCH_PROXY" = true ] && pgrep -x "$PROXY_PROC_NAME" > /dev/null 2>&1; then
    proxy_already_running
fi

if [ "$LAUNCH_PROXY" = true ] && [ "$START_PROXY" = true ]; then
    FULL_PROXY_CMD=("${PROXY_COMMAND[@]}")
    strip_quarantine "$PROXY_DIR" "$OPENSSL_DIR"
    chmod +x "$PROXY_BIN" 2>/dev/null

    echo "[*] Executing proxy command: ${FULL_PROXY_CMD[*]}"
    echo "[*] Connection Proxy running..."

    # Watch the game from its own subshell - exec below stops this from reaping it
    (
        echo "[*] Launching World of Warcraft Classic..."
        echo "======================================="

        nohup "$WOW_BIN" > /dev/null 2>&1 &
        WOW_PID=$!

        while kill -0 "$WOW_PID" 2>/dev/null; do
            sleep 2
        done
        # Another account may still be using this proxy - match by path, not just name
        if pgrep -f "$WOW_BIN" > /dev/null 2>&1; then
            echo ""
            echo "[*] Game closed, but another client is still connected."
            echo "    Leaving the proxy running."
            while pgrep -f "$WOW_BIN" > /dev/null 2>&1 && kill -0 $$ 2>/dev/null; do
                sleep 2
            done
        fi

        on_game_closed
    ) &
    disown

    cd "$PROXY_DIR"
    export DYLD_LIBRARY_PATH="$OPENSSL_DIR"
    # exec replaces this process with the proxy, so Ctrl+C reaches it directly
    # Stdin from /dev/null - "Press enter to close" won't hang with no tty to read
    exec "${FULL_PROXY_CMD[@]}" < /dev/null
else
    echo "[*] Launching World of Warcraft Classic..."
    echo "======================================="

    nohup "$WOW_BIN" > /dev/null 2>&1 &

    after_game_launched
fi
