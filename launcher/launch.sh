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
CHECK_PATCH=false

# --- Path Definitions ---
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$LAUNCHER_DIR" == *".app/Contents/Resources" ]]; then
    BASE_DIR="$(dirname "$(dirname "$(dirname "$LAUNCHER_DIR")")")"
    WITHIN_APP=true
else
    BASE_DIR="$(dirname "$LAUNCHER_DIR")"
fi
# --game <dir> overrides the game folder
for ((i = 1; i < $#; i++)); do
    if [ "${!i}" = "--game" ]; then
        GAME_ARG=$((i + 1))
        BASE_DIR="$(cd "${!GAME_ARG}" 2>/dev/null && pwd)"
    fi
done

USER_CONF="$BASE_DIR/connect.conf"
GAME_APP="$BASE_DIR/_classic_era_/World of Warcraft Classic.app"
GAME_BIN="$GAME_APP/Contents/MacOS/World of Warcraft Classic"
GAME_BAK="${GAME_BIN}_bak"
GAME_WTF_DIR="$BASE_DIR/_classic_era_/WTF"
GAME_CONFIG="$GAME_WTF_DIR/Config.wtf"

OPENSSL_DIR="$LAUNCHER_DIR/openssl-3.0.7"
MIRROR_LIST_FILE="$LAUNCHER_DIR/archive_mirrors.txt"
# Pieces of a client download, kept until it is installed so a stopped download continues
DOWNLOAD_DIR="$BASE_DIR/.download"
DOWNLOAD_PARTS=8
PROXY_DIR="$LAUNCHER_DIR/proxy"
PROXY_BIN="$PROXY_DIR/HermesProxy"
# Addon folders put here are copied into the game's Interface/AddOns at every start
ADDONS_DIR="$LAUNCHER_DIR/addons"
# The app reads the launcher folder next to it, not its own copy from when it was built
[ "$WITHIN_APP" = true ] && [ -d "$BASE_DIR/launcher/addons" ] && ADDONS_DIR="$BASE_DIR/launcher/addons"
GAME_ADDONS_DIR="$BASE_DIR/_classic_era_/Interface/AddOns"

PATCH_DIR="$LAUNCHER_DIR/build/patch"
PATCH_DIR_DYLIB="$PATCH_DIR/classicpatch.dylib"
PATCH_SCRIPT="$PATCH_DIR/patch_binary.sh"

# Relative to the game app's Contents folder
CLASSICPATCH_SUBPATH="Frameworks/classicpatch.dylib"
CLASSICPATCH_DYLIB="$GAME_APP/Contents/$CLASSICPATCH_SUBPATH"


# --- Supported Clients ---
# version build sha1-of-the-original-executable
CLIENTS="
1.14.0 40618 200c4c54316fb801d6d4d07d7031bb2b43f1c2be
1.14.1 42032 bff00e04f1a02ecf4b8410d5796eddda1dc24afc
1.14.2 42597 638233fd384602862e41590e4b0213242c82257f
"

# ask_yes "Question?": Enter, y or yes = yes; n or no = no; anything else asks again
ask_yes() {
    local answer
    while true; do
        read -e -r -p "$1 [Y/n]: " answer
        case "$answer" in
            ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "[!] Invalid selection." >&2 ;;
        esac
    done
}

# --- Client Detection and Patching ---
# Sets CLIENT_BUILD, CLIENT_VERSION, UNPATCHED_HASH for a known original sha1
lookup_client() {
    local version build unpatched
    while read -r version build unpatched; do
        if [ -n "$build" ] && [ "$1" == "$unpatched" ]; then
            CLIENT_BUILD="$build"
            CLIENT_VERSION="$version.$build"
            UNPATCHED_HASH="$unpatched"
            return 0
        fi
    done <<< "$CLIENTS"
    return 1
}

# Patched = the executable loads classicpatch.dylib
is_patched() {
    LC_ALL=C grep -a -q -F "@executable_path/../$CLASSICPATCH_SUBPATH" "$1"
}

# A patched executable's sha1 is signed on this Mac, so its backup tells the client instead
detect_client() {
    ACTUAL_HASH=""
    CLIENT_BUILD=""
    CLIENT_VERSION=""
    UNPATCHED_HASH=""
    [ -f "$GAME_BIN" ] || return 0
    ACTUAL_HASH=$(sha1_file "$GAME_BIN")
    lookup_client "$ACTUAL_HASH" || { [ -f "$GAME_BAK" ] && lookup_client "$(sha1_file "$GAME_BAK")"; }
    return 0
}

# MISSING, UNKNOWN, PATCHED or UNPATCHED - about the executable only, not classicpatch.dylib
client_state() {
    if [ ! -f "$GAME_BIN" ]; then
        echo "MISSING"
    elif [ -z "$CLIENT_BUILD" ]; then
        echo "UNKNOWN"
    elif is_patched "$GAME_BIN"; then
        echo "PATCHED"
    elif [ "$ACTUAL_HASH" == "$UNPATCHED_HASH" ]; then
        echo "UNPATCHED"
    else
        echo "UNKNOWN"
    fi
}

patch_executable() {
    strip_quarantine "$GAME_BIN"
    if [ ! -f "$PATCH_SCRIPT" ]; then
        echo "[!] patch_binary.sh not found at $PATCH_SCRIPT" >&2
        abort_launch
    fi

    if [ -f "$GAME_BAK" ]; then
        BACKUP_HASH=$(sha1_file "$GAME_BAK")
        if [ "$BACKUP_HASH" != "$UNPATCHED_HASH" ]; then
            echo "[!] Existing backup at $GAME_BAK doesn't match the expected unpatched client." >&2
            abort_launch
        fi
    else
        echo "[*] Creating backup..."
        if ! cp "$GAME_BIN" "$GAME_BAK"; then
            echo "[!] Failed to create the backup at $GAME_BAK" >&2
            rm -f "$GAME_BAK"
            abort_launch
        fi
    fi

    # @executable_path is dyld's name for Contents/MacOS - the game folder can move
    echo "[*] Patching the game binary..."
    GAME_PATCH_TMP="${GAME_BIN}.patching"
    rm -f "$GAME_PATCH_TMP"
    # Patch a copy of the backup first to avoid corrupting
    if cp "$GAME_BAK" "$GAME_PATCH_TMP" \
        && /bin/bash "$PATCH_SCRIPT" "$GAME_PATCH_TMP" "@executable_path/../$CLASSICPATCH_SUBPATH" \
        && is_patched "$GAME_PATCH_TMP" \
        && chmod +x "$GAME_PATCH_TMP" \
        && mv -f "$GAME_PATCH_TMP" "$GAME_BIN"; then
        echo "[*] Patching successful!"
    else
        echo "[!] Failed to patch the binary." >&2
        rm -f "$GAME_PATCH_TMP"
        abort_launch
    fi
}

# Puts or replaces classicpatch.dylib in the game app to be loaded by the patched binary
install_classicpatch() {
    if ! cmp -s "$PATCH_DIR_DYLIB" "$CLASSICPATCH_DYLIB"; then
        if [ ! -f "$PATCH_DIR_DYLIB" ]; then
            echo "[!] classicpatch.dylib not found at $PATCH_DIR_DYLIB" >&2
            echo "    Build it with launcher/build/patch/build_classicpatch.sh (you may need Apple's Command Line Tools)." >&2
            abort_launch
        fi
        echo "[*] Installing classicpatch.dylib..."
        if ! mkdir -p "$(dirname "$CLASSICPATCH_DYLIB")" || ! cp -f "$PATCH_DIR_DYLIB" "$CLASSICPATCH_DYLIB"; then
            echo "[!] Failed to install classicpatch.dylib into $CLASSICPATCH_DYLIB" >&2
            abort_launch
        fi
    fi
    strip_quarantine "$CLASSICPATCH_DYLIB"
}

print_expected_hashes() {
    awk 'NF { printf "    Expected %s unpatched: %s\n", $1, $3 }' <<< "$CLIENTS" >&2
}

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

# Only direct connections may carry a :port - the proxy sets its own
validate_bnet_address() {
    local host port
    case "$1" in
        :*|*:|*:*:*) return 1 ;;
        *:*)
            host="${1%:*}"
            port="${1#*:}"
            case "$port" in
                *[!0-9]*) return 1 ;;
            esac
            [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
            validate_server_address "$host"
            ;;
        *) validate_server_address "$1" ;;
    esac
}

set_portal() {
    local portal="$1"
    if grep -q '^SET portal' "$GAME_CONFIG"; then
        sed -i '' "s|^SET portal.*|SET portal \"$portal\"|g" "$GAME_CONFIG"
    else
        printf 'SET portal "%s"\n' "$portal" >> "$GAME_CONFIG"
    fi
}

# 0 = usable, 1 = no file yet, 2 = garbage
load_config() {
    [ -f "$USER_CONF" ] || return 1
    [ -r "$USER_CONF" ] || return 2 # Can't read it, so treat it like garbage
    local key value use_proxy="" saved_ip=""
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
            SAVED_USE_PROXY) use_proxy="$value" ;;
            SAVED_IP) saved_ip="$value" ;;
        esac
    done < "$USER_CONF"

    # Both keys have to be present and sane, or the whole file counts as garbage
    case "$use_proxy" in
        true) validate_server_address "$saved_ip" || return 2 ;;
        false) validate_bnet_address "$saved_ip" || return 2 ;;
        *) return 2 ;;
    esac

    SAVED_USE_PROXY="$use_proxy"
    SAVED_IP="$saved_ip"
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
            echo "  --game <dir>           Use the game folder <dir> instead of this launcher's parent folder"
            echo "  --checkpatch           Print PATCHED, UNPATCHED, UNKNOWN, or MISSING, and exit"
            echo "  --patch                Patch the binary only, don't launch"
            echo "  --reset                Clear saved connection config and caches"
            echo "  --getmissing [url|zip] Fetch an untouched 1.14 client, or install it from a zip on this Mac"
            echo "                         (prompts for a mirror if neither is given)"
            echo "  --bnet [ip[:port]]     Connect directly, bypassing the Connection Proxy (default ip: 127.0.0.1)"
            echo "  --switchproxy <name>   Use a custom proxy binary from the proxy/ folder"
            echo "  --config <file>        Pass a custom proxy configuration file"
            echo "  --set <key=value>      Pass a proxy override, repeatable"
            echo "  --help, -h             Show this help"
            exit 0
            ;;
        --checkpatch)
            CHECK_PATCH=true
            shift
            ;;
        --game)
            # BASE_DIR is already set, in the path definitions
            if [[ -n "$2" && ! "$2" =~ ^-- ]] && [ -d "$2" ]; then
                shift 2
            else
                echo "[!] --game requires an existing game folder (the one that holds _classic_era_)." >&2
                exit 1
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
                if ! validate_bnet_address "$2"; then
                    echo "[!] --bnet: '$2' is not a valid IP, hostname, or host:port." >&2
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

                # Extract ServerAddress if passed, to update connect.conf
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

detect_client

# --checkpatch: print the state and exit - PATCHED also needs classicpatch.dylib in place
if [ "$CHECK_PATCH" = true ]; then
    CLIENT_STATE=$(client_state)
    if [ "$CLIENT_STATE" == "PATCHED" ] && [ ! -f "$CLASSICPATCH_DYLIB" ]; then
        CLIENT_STATE=UNPATCHED
    fi
    echo "$CLIENT_STATE"
    case "$CLIENT_STATE" in
        PATCHED) exit 0 ;;
        UNPATCHED) exit 1 ;;
        UNKNOWN) exit 2 ;;
        *) exit 3 ;;
    esac
fi

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
echo "   Classic 1.14 - Patcher & Launcher  "
echo "======================================="

# --- Client Download ---
# file_size FILE: its size in bytes, 0 if it is not there
file_size() { stat -f %z "$1" 2>/dev/null || echo 0; }

# fetch_part URL FILE FIRST LAST: those bytes of URL into FILE, asking only for what FILE is still missing
fetch_part() {
    local url="$1" file="$2" first="$3" last="$4" want have attempt=0
    want=$((last - first + 1))
    while [ "$attempt" -lt 30 ]; do
        have=$(file_size "$file")
        # More than asked: the server ignored the range - start this piece over
        if [ "$have" -gt "$want" ]; then : > "$file"; have=0; fi
        [ "$have" -eq "$want" ] && return 0
        attempt=$((attempt + 1))
        # A connection that stalls for a minute is dropped and asked again
        curl -fsL --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
            -r "$((first + have))-$last" "$url" >> "$file" 2>/dev/null || sleep 2
    done
    [ "$(file_size "$file")" -eq "$want" ]
}

# Stops the piece downloads (each is a subshell running curl)
stop_download() {
    local pid
    for pid in "${DOWNLOAD_PIDS[@]}"; do
        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    done
    DOWNLOAD_PIDS=()
}

# download_file URL OUT: in DOWNLOAD_PARTS pieces at once when the server allows it; stopped pieces are continued later
download_file() {
    local url="$1" out="$2" size=0 ranges="" part_size i first last have start_have total t0 elapsed rate alive pid failed=0
    # Size and byte-range support, asked up to 3 times (mirrors answer an error now and then)
    for i in 1 2 3; do
        size="$(curl -sIL --connect-timeout 20 --max-time 60 "$url" | tr -d '\r' \
            | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')"
        [ "$size" -gt 0 ] && ranges="$(curl -sL -r 0-15 --connect-timeout 20 --max-time 60 -o /dev/null -w '%{http_code}' "$url")"
        [ "$ranges" = 206 ] && break
        sleep 3
    done
    # Pieces of another download (other URL or size) are not mixed in; an unknown size keeps them
    if [ "$size" -gt 0 ] && [ "$(cat "$out.source" 2>/dev/null)" != "$url $size" ]; then
        rm -f "$out" "$out".part*
        echo "$url $size" > "$out.source"
    fi
    [ "$size" -gt 0 ] && [ "$(file_size "$out")" -eq "$size" ] && return 0

    # No size or no byte ranges: one connection, which still continues a stopped download
    if [ "$ranges" != 206 ]; then
        echo "[*] The mirror does not allow several connections: downloading with one."
        curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 -C - -o "$out" "$url"
        return $?
    fi

    part_size=$(( (size + DOWNLOAD_PARTS - 1) / DOWNLOAD_PARTS ))
    have=0
    for ((i = 0; i < DOWNLOAD_PARTS; i++)); do
        have=$((have + $(file_size "$out.part$i")))
    done
    if [ "$have" -gt 0 ]; then
        echo "[*] Continuing the download: $(awk -v h="$have" -v s="$size" 'BEGIN { printf "%.1f of %.1f GB", h / 1e9, s / 1e9 }') already here."
    fi

    DOWNLOAD_PIDS=()
    for ((i = 0; i < DOWNLOAD_PARTS; i++)); do
        first=$((i * part_size))
        [ "$first" -ge "$size" ] && break
        last=$((first + part_size - 1))
        [ "$last" -ge "$size" ] && last=$((size - 1))
        fetch_part "$url" "$out.part$i" "$first" "$last" &
        DOWNLOAD_PIDS+=($!)
    done

    # Redraw a single status line in place
    start_have=$have
    t0=$(date +%s)
    while :; do
        alive=0
        for pid in "${DOWNLOAD_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        total=0
        for ((i = 0; i < DOWNLOAD_PARTS; i++)); do total=$((total + $(file_size "$out.part$i"))); done
        elapsed=$(( $(date +%s) - t0 ))
        [ "$elapsed" -gt 0 ] && rate=$(( (total - start_have) / elapsed )) || rate=0
        printf '\r\033[K    %s' "$(awk -v t="$total" -v s="$size" -v r="$rate" \
            'BEGIN { printf "%.1f / %.1f GB  %d%%  %.1f MB/s", t / 1e9, s / 1e9, t * 100 / s, r / 1e6 }')"
        [ "$alive" -eq 1 ] || break
        sleep 2
    done
    echo ""

    for pid in "${DOWNLOAD_PIDS[@]}"; do
        wait "$pid" || failed=1
    done
    DOWNLOAD_PIDS=()
    [ "$failed" -eq 0 ] || return 1

    # Join the pieces: only one piece's worth of extra disk at a time
    mv -f "$out.part0" "$out" || return 1
    for ((i = 1; i < DOWNLOAD_PARTS; i++)); do
        [ -f "$out.part$i" ] || continue
        cat "$out.part$i" >> "$out" && rm -f "$out.part$i" || return 1
    done
    [ "$(file_size "$out")" -eq "$size" ]
}

# Only used if the client turns out to be missing below
run_get_client() {
    # Normally only reachable via --getmissing on an existing install (CLI only)
    if [ -f "$GAME_BIN" ]; then
        echo "[!] A client already exists at $GAME_BIN" >&2
        echo "    --getmissing is only for an initial, empty install. Remove client files first" >&2
        echo "    if you really want to fetch it again." >&2
        abort_launch
    fi

    # Another launcher already downloading into this game folder
    if [ -f "$DOWNLOAD_DIR/download.pid" ] && kill -0 "$(cat "$DOWNLOAD_DIR/download.pid" 2>/dev/null)" 2>/dev/null; then
        echo "[!] A download is already in progress - wait for it to finish, then retry." >&2
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
        # Ships bundled with archive_mirrors.txt - only empty if someone deleted it
        if [ ${#MIRRORS[@]} -eq 0 ]; then
            echo "[!] No mirrors listed in $MIRROR_LIST_FILE" >&2
            echo "    Add at least one URL to that file (one per line), then retry." >&2
            abort_launch
        fi

        if [ ${#MIRRORS[@]} -eq 1 ]; then
            SELECTED_URL="${MIRRORS[0]}"
        else
            echo ""
            echo "=========== Choose a mirror ==========="
            for i in "${!MIRRORS[@]}"; do
                echo "  $((i + 1))) ${MIRRORS[$i]}"
            done
            echo "======================================="
            while true; do
                read -e -r -p "Enter choice [1-${#MIRRORS[@]}]: " MIRROR_CHOICE || abort_launch
                [[ "$MIRROR_CHOICE" =~ ^[0-9]+$ ]] && [ "$MIRROR_CHOICE" -ge 1 ] && [ "$MIRROR_CHOICE" -le "${#MIRRORS[@]}" ] && break
                echo "[!] Invalid selection." >&2
            done
            SELECTED_URL="${MIRRORS[$((MIRROR_CHOICE - 1))]}"
        fi
    fi

    # A zip already on this Mac is extracted where it is, never moved or deleted
    LOCAL_ZIP=false
    case "$SELECTED_URL" in
        http://*|https://*) ;;
        *)
            if [ ! -f "$SELECTED_URL" ]; then
                echo "[!] Not a web address (http:// or https://) or a zip on this Mac: $SELECTED_URL" >&2
                abort_launch
            fi
            LOCAL_ZIP=true
            ;;
    esac

    # Strip any query string/fragment before using it as a filename
    ZIP_NAME="$(basename "${SELECTED_URL%%[?#]*}")"

    GET_TMP="$(mktemp -d)"
    mkdir -p "$DOWNLOAD_DIR"
    echo $$ > "$DOWNLOAD_DIR/download.pid"
    # Stopped or failed: the pieces stay for the next run, the rest goes
    DOWNLOAD_PIDS=()
    trap 'stop_download; rm -f "$DOWNLOAD_DIR/download.pid"; rm -rf "$GET_TMP"' EXIT
    trap 'exit 130' INT TERM

    if [ "$LOCAL_ZIP" = true ]; then
        ZIP_PATH="$SELECTED_URL"
        echo "[*] Using the client archive on this Mac:"
        echo "    $ZIP_PATH"
    else
        echo "[*] Fetching client (this may take a while)..."
        echo "    $SELECTED_URL"

        ZIP_PATH="$DOWNLOAD_DIR/$ZIP_NAME"
        if ! download_file "$SELECTED_URL" "$ZIP_PATH"; then
            echo "[!] Fetching the client failed." >&2
            echo "    (check the mirror - it may be dead: $SELECTED_URL)" >&2
            echo "    Run again to continue the download." >&2
            abort_launch
        fi
    fi

    echo "[*] Extracting client archive..."
    mkdir -p "$GET_TMP/extracted"
    if ! ditto -xk "$ZIP_PATH" "$GET_TMP/extracted"; then
        # A broken download is not kept: the next run fetches it again
        [ "$LOCAL_ZIP" = true ] || rm -f "$ZIP_PATH"
        echo "[!] Failed to extract $ZIP_PATH" >&2
        abort_launch
    fi

    # Mirrors wrap this differently - find whichever folder actually holds the client
    GAME_BIN_SUBPATH="${GAME_BIN#"$BASE_DIR/"}"
    EXTRACTED_ROOT="$GET_TMP/extracted"
    if [ ! -f "$EXTRACTED_ROOT/$GAME_BIN_SUBPATH" ] || [ ! -d "$EXTRACTED_ROOT/Data" ]; then
        EXTRACTED_ROOT=""
        for entry in "$GET_TMP/extracted"/*/; do
            [ -f "${entry}${GAME_BIN_SUBPATH}" ] && [ -d "${entry}Data" ] && EXTRACTED_ROOT="${entry%/}" && break
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
    rm -rf "$GET_TMP" "$DOWNLOAD_DIR"
    trap - EXIT INT TERM
    # Fall through into the patch-and-launch flow below instead of exiting
}

# 1. Make sure the client is actually here
if [ "$GET_MISSING" = true ]; then
    run_get_client
    # --getmissing only downloads and extracts
    echo "    Run again to patch and connect."
    exit 0
fi

if [ ! -f "$GAME_BIN" ]; then
    echo "[!] Game binary not found at $GAME_BIN" >&2
    echo ""
    echo "====== Get missing client files ======="
    echo "  [Yes] -> Fetch a 1.14 client"
    echo "   No   -> Exit, fetch it manually later"
    echo "======================================="
    if ask_yes "Fetch a 1.14 client now?"; then
        run_get_client
    fi
    if [ ! -f "$GAME_BIN" ]; then
        abort_launch
    fi
    # Only known now
    detect_client
fi

# 2. Check Backup and Patch status
case "$(client_state)" in
    PATCHED)
        echo "[*] Game binary is already patched. Skipping patch phase."
        ;;
    UNPATCHED)
        echo "[*] Unpatched game binary detected. Initializing patch process..."
        patch_executable
        ;;
    *)
        # Read from Supported Clients
        echo "[!] Patcher is expecting Classic 1.14.0 (40618), 1.14.1 (42032) or 1.14.2 (42597)." >&2
        echo "    Current file hash: $ACTUAL_HASH" >&2
        print_expected_hashes
        abort_launch
        ;;
esac
install_classicpatch

# Ensure WTF directory exists for config
mkdir -p "$GAME_WTF_DIR"
touch "$GAME_CONFIG"

# 3. Handle User Configuration
# No point reading a config --reset is about to delete, and --patch never needs it
if [ "$RESET" = false ] && [ "$PATCH_ONLY" = false ]; then
    load_config
    CONF_STATE=$?

    if [ "$CONF_STATE" -eq 0 ]; then
        echo "[*] Loading saved configuration from connect.conf..."
    # Nothing usable - reset below, unless arguments will overwrite it anyway
    elif [ "$CONF_STATE" -eq 2 ] && [ -z "$DIRECT_BNET_IP" ] && [ "$PROXY_ARGS_PASSED" = false ]; then
        echo "[!] connect.conf holds no usable settings." >&2
        echo ""
        echo "==== Invalid Launcher Config File ====="
        echo "  [Yes] -> Reset the configuration"
        echo "   No   -> Exit, fix or delete connect.conf yourself"
        echo "======================================="
        if ask_yes "Reset connect.conf now?"; then
            RESET=true
        else
            echo "[!] Left the file as it is: $USER_CONF" >&2
            abort_launch
        fi
    fi
fi

# --reset, or the answer to the prompt above
if [ "$RESET" = true ]; then
    echo "[*] Clearing saved configuration, caches..."
    rm -f "$USER_CONF"
    rm -rf "$BASE_DIR/_classic_era_/Cache" "$BASE_DIR/_classic_era_/Logs"
    set_portal "127.0.0.1"
    # Manual escape hatch - everything below is normally only touched on first use
    strip_quarantine "$GAME_BIN" "$PROXY_DIR" "$OPENSSL_DIR"
    chmod +x "$GAME_BIN" "$PROXY_BIN" 2>/dev/null
fi

# --patch stops here - --reset carries on into the connection setup below
if [ "$PATCH_ONLY" = true ]; then
    echo "[*] Patch check completed successfully."
    exit 0
fi

# If user passed --bnet <ip>. Force direct.
if [ -n "$DIRECT_BNET_IP" ]; then
    CONNECTION_TYPE="DIRECT"

    # Write to config if missing, if previously set to proxy, or IP changed
    if [ "$CONFIG_EXISTS" = false ] || [ "$SAVED_USE_PROXY" = true ] || [ "$SAVED_IP" != "$DIRECT_BNET_IP" ]; then
        SAVED_USE_PROXY=false
        SAVED_IP="$DIRECT_BNET_IP"
        save_config
        echo "[*] Updated connect.conf: switched to a direct connection ($SAVED_IP)."
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
    else
        NEW_SAVED_IP="${SAVED_IP%%:*}" # Any port came from --bnet - the proxy sets its own
    fi

    # Write to config if missing, if previously set to direct, or IP changed
    if [ "$CONFIG_EXISTS" = false ] || [ "$SAVED_USE_PROXY" = false ] || [ "$SAVED_IP" != "$NEW_SAVED_IP" ]; then
        SAVED_USE_PROXY=true
        SAVED_IP="$NEW_SAVED_IP"
        save_config
        echo "[*] Updated connect.conf: switched to the Connection Proxy ($SAVED_IP)."
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
        if ask_yes "Connect via Connection Proxy?"; then
            CONNECTION_TYPE="PROXY"
            SAVED_USE_PROXY=true
            echo "    Example: logon.example.com or 127.0.0.1"
        else
            CONNECTION_TYPE="DIRECT"
            SAVED_USE_PROXY=false
            echo "    Example: 127.0.0.1 or 127.0.0.1:1119"
        fi
        # Enter = 127.0.0.1, a wrong address asks again
        while true; do
            if [ "$CONNECTION_TYPE" = "PROXY" ]; then
                read -e -r -p "Enter realmlist server address [127.0.0.1]: " INPUT_IP
                SAVED_IP=${INPUT_IP:-127.0.0.1}
                validate_server_address "$SAVED_IP" && break
                echo "[!] '$SAVED_IP' is not a valid IP or hostname." >&2
            else
                read -e -r -p "Enter native bnetserver [127.0.0.1]: " INPUT_IP
                SAVED_IP=${INPUT_IP:-127.0.0.1}
                validate_bnet_address "$SAVED_IP" && break
                echo "[!] '$SAVED_IP' is not a valid IP, hostname, or host:port." >&2
            fi
        done
        # Save to file
        save_config
        echo "[*] Settings saved to connect.conf."
        echo "    To change them later, run launch.sh --reset or delete connect.conf in the game folder."
    fi
fi

# Apply the loaded/saved configuration
if [ "$CONNECTION_TYPE" = "PROXY" ]; then
    LAUNCH_PROXY=true

    # Update Game Config to Proxy IP
    echo "[*] Configuring the game to connect to the Connection Proxy (127.0.0.1)..."
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
    PROXY_COMMAND+=("--set" "ClientBuild=$CLIENT_BUILD")

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
    echo "[*] Configuring the game to connect directly to $SAVED_IP..."
    set_portal "$SAVED_IP"
fi

# Copies each addon folder of launcher/addons into the game, replacing an older copy of the same addon
install_addons() {
    local addon count=0
    [ -d "$ADDONS_DIR" ] || return 0
    for addon in "$ADDONS_DIR"/*/; do
        [ -d "$addon" ] || continue
        addon="${addon%/}"
        mkdir -p "$GAME_ADDONS_DIR"
        rm -rf "${GAME_ADDONS_DIR:?}/$(basename "$addon")"
        ditto "$addon" "$GAME_ADDONS_DIR/$(basename "$addon")" && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && echo "[*] Installed $count addon(s) from the launcher's addons folder."
    return 0
}

# 4. Execution Phase
install_addons
# Job control on, so the game gets its own process group, away from Ctrl+C
set -m

START_PROXY=true
PROXY_PROC_NAME=$(basename "$PROXY_BIN")

# CLI default prompts interactively - the built .app reuses silently
proxy_already_running() {
    # WITHIN_APP:proxy_already_running:start
    if ask_yes "The Connection Proxy is already running. Keep it running?"; then
        echo "[*] Keeping the Connection Proxy running."
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
        echo "[*] Game closed. The Connection Proxy is still running - Ctrl+C to stop it."
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

    echo "[*] Executing Connection Proxy command: ${FULL_PROXY_CMD[*]}"
    echo "[*] Connection Proxy running..."

    # Watch the game from its own subshell - exec below stops this from reaping it
    (
        echo "[*] Launching the game..."
        echo "======================================="

        nohup "$GAME_BIN" > /dev/null 2>&1 &
        GAME_PID=$!

        while kill -0 "$GAME_PID" 2>/dev/null; do
            sleep 2
        done
        # Another account may still be using this proxy - match by path, not just name
        if pgrep -f "$GAME_BIN" > /dev/null 2>&1; then
            echo ""
            echo "[*] Game closed, but another client is still connected."
            echo "    Leaving the Connection Proxy running."
            while pgrep -f "$GAME_BIN" > /dev/null 2>&1 && kill -0 $$ 2>/dev/null; do
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
    echo "[*] Launching the game..."
    echo "======================================="

    nohup "$GAME_BIN" > /dev/null 2>&1 &

    after_game_launched
fi
