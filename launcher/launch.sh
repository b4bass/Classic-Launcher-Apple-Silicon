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
NO_ADDONS=false

# --- Path Definitions ---
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$LAUNCHER_DIR" == *".app/Contents/Resources" ]]; then
    BASE_DIR="$(dirname "$(dirname "$(dirname "$LAUNCHER_DIR")")")"
    WITHIN_APP=true
else
    BASE_DIR="$(dirname "$LAUNCHER_DIR")"
fi
# options.txt: options as typed after launch.sh, any number per line. The command line comes after it, so it wins
OPTIONS_FILE="$LAUNCHER_DIR/options.txt"
[ "$WITHIN_APP" = true ] && [ -f "$BASE_DIR/launcher/options.txt" ] && OPTIONS_FILE="$BASE_DIR/launcher/options.txt"
declare -a FILE_ARGS
if [ -f "$OPTIONS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | tr -d '\r')"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        # Split like Terminal does: a path with spaces goes in quotes
        if ! words="$(printf '%s\n' "$line" | xargs -n1 printf '%s\n' 2>/dev/null)"; then
            echo "[!] ${OPTIONS_FILE##*/}: a quote is not closed in: $line" >&2
            exit 1
        fi
        while IFS= read -r word; do FILE_ARGS+=("$word"); done <<< "$words"
    done < "$OPTIONS_FILE"
    set -- "${FILE_ARGS[@]}" "$@"
fi
# --game <dir> overrides the game folder, --client era|tbc|wotlk|cata the client in it
CLIENT_ARG=""
for ((i = 1; i < $#; i++)); do
    j=$((i + 1))
    if [ "${!i}" = "--game" ]; then
        BASE_DIR="$(cd "${!j}" 2>/dev/null && pwd)"
    elif [ "${!i}" = "--client" ]; then
        CLIENT_ARG="${!j}"
    fi
done

USER_CONF="$BASE_DIR/connect.conf"

OPENSSL_DIR="$LAUNCHER_DIR/openssl"
MIRROR_LIST_FILE="$LAUNCHER_DIR/archive_mirrors.txt"
# Pieces of a client download, kept until it is installed so a stopped download continues
DOWNLOAD_DIR="$BASE_DIR/.download"
# Connections per server, each taking the next chunk: archive.org gives each connection only a little, so the
# file's other servers are used too (archive.org: 3, so 24 connections)
DOWNLOAD_PER_SERVER=8
DOWNLOAD_CHUNK=$((64 * 1024 * 1024))
PROXY_DIR="$LAUNCHER_DIR/proxy"
PROXY_BIN="$PROXY_DIR/HermesProxy"
# Addon folders put in its era, tbc, wotlk or cata folder are copied into that client's Interface/AddOns at every start
ADDONS_DIR="$LAUNCHER_DIR/addons"
# The app reads the launcher folder next to it, not its own copy from when it was built
[ "$WITHIN_APP" = true ] && [ -d "$BASE_DIR/launcher/addons" ] && ADDONS_DIR="$BASE_DIR/launcher/addons"

PATCH_DIR="$LAUNCHER_DIR/build/patch"
PATCH_DIR_DYLIB="$PATCH_DIR/classicpatch.dylib"
PATCH_SCRIPT="$PATCH_DIR/patch_binary.sh"

# Relative to the game app's Contents folder
CLASSICPATCH_SUBPATH="Frameworks/classicpatch.dylib"


# --- Supported Clients ---
# version build sha1-of-the-original-executable
CLIENTS="
1.14.0 40618 200c4c54316fb801d6d4d07d7031bb2b43f1c2be
1.14.1 42032 bff00e04f1a02ecf4b8410d5796eddda1dc24afc
1.14.2 42597 638233fd384602862e41590e4b0213242c82257f
2.5.2 40892 be5eee620d5a75e4142a60858c013a861625b62e
2.5.3 42328 fc843a8d2f9a0ba0e2f86c0ad9e23b03de1ef99d
2.5.3 42598 be3a5cb20630b0f420b5531238933f6f3fb8f09a
3.4.3 54261 1d7cee2116baf1c4247e67a4b5f3c760dd5df7e6
4.4.2 60895 e4b089c80ceb293931ad97e0b2f90b0b7c2de108
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

# --- Clients ---
# Classic Era lives in _classic_era_; TBC, WotLK or Cataclysm Classic in _classic_ (one of them). One game folder can
# hold both, they share Data/
flavor_dir() { case "$1" in era) echo "_classic_era_" ;; *) echo "_classic_" ;; esac; }
has_flavor() { [ -d "$BASE_DIR/$(flavor_dir "$1")/World of Warcraft Classic.app" ]; }
# plist_value PLIST KEY: a value of an Info.plist, nothing when the file or the key is not there
# (plutil writes its errors to stdout: only a value it could read is printed)
plist_value() { local v; v="$(plutil -extract "$2" raw "$1" 2>/dev/null)" && echo "$v"; }
# The client's version, nothing when it is not there
flavor_version() { plist_value "$BASE_DIR/$(flavor_dir "$1")/World of Warcraft Classic.app/Contents/Info.plist" CFBundleVersion; }
# era, tbc, wotlk or cata: the client's connect.conf section and addons folder
client_of() {
    [ "$1" = era ] && { echo era; return; }
    case "$(flavor_version classic)" in 3.*) echo wotlk ;; 4.*) echo cata ;; *) echo tbc ;; esac
}
client_label() {
    case "$1" in era) echo "Classic Era" ;; tbc) echo "TBC Classic" ;; wotlk) echo "WotLK Classic" ;; cata) echo "Cataclysm Classic" ;; esac
}

# set_flavor era|classic: the paths of that client
set_flavor() {
    FLAVOR="$1"
    FLAVOR_DIR="$BASE_DIR/$(flavor_dir "$1")"
    GAME_APP="$FLAVOR_DIR/World of Warcraft Classic.app"
    GAME_BIN="$GAME_APP/Contents/MacOS/World of Warcraft Classic"
    GAME_BAK="${GAME_BIN}_bak"
    GAME_WTF_DIR="$FLAVOR_DIR/WTF"
    GAME_CONFIG="$GAME_WTF_DIR/Config.wtf"
    GAME_ADDONS_DIR="$FLAVOR_DIR/Interface/AddOns"
    CLASSICPATCH_DYLIB="$GAME_APP/Contents/$CLASSICPATCH_SUBPATH"
    CLIENT="$(client_of "$1")"
    CLIENT_NAME="$(client_label "$CLIENT")"
}

# Both clients here and no --client: ask which one (Enter = Classic Era)
choose_client() {
    local answer
    echo ""
    echo "=========== Choose a client ==========="
    echo "  1) $(client_label era) $(flavor_version era)"
    echo "  2) $(client_label "$(client_of classic)") $(flavor_version classic)"
    echo "======================================="
    while true; do
        read -e -r -p "Enter choice [1-2, Enter = 1]: " answer || answer=""
        case "${answer:-1}" in
            1) set_flavor era; break ;;
            2) set_flavor classic; break ;;
            *) echo "[!] Invalid selection." >&2 ;;
        esac
    done
}

case "$CLIENT_ARG" in
    era) set_flavor era ;;
    tbc|wotlk|cata)
        set_flavor classic
        # Nothing in _classic_ yet: the client asked for (messages name it)
        has_flavor classic || { CLIENT="$CLIENT_ARG"; CLIENT_NAME="$(client_label "$CLIENT")"; }
        if has_flavor classic && [ "$CLIENT" != "$CLIENT_ARG" ]; then
            echo "[!] _classic_ folder holds $CLIENT_NAME $(flavor_version classic), not $(client_label "$CLIENT_ARG")." >&2
            exit 1
        fi
        ;;
    "") if has_flavor era || ! has_flavor classic; then set_flavor era; else set_flavor classic; fi ;;
    *) echo "[!] --client must be era, tbc, wotlk or cata." >&2; exit 1 ;;
esac

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

# connect.conf holds one section per client, in this order (others are kept after them):
#   [era]
#   SAVED_USE_PROXY=true
#   SAVED_IP=logon.example.com
CONF_SECTIONS="era tbc wotlk cata"

# Older names of a section: the product name test builds wrote (wow_classic: TBC, WotLK and Cataclysm share it)
conf_old_name() { case "$1" in era) echo "wow_classic_era" ;; tbc|wotlk|cata) echo "wow_classic" ;; esac; }

# conf_section NAME [OLD]: the lines of that section, else of its older name (OLD, "-" for none). Lines before the
# first section are era's (0.75 and before knew only Classic Era), unless the file has an [era] section
conf_section() {
    [ -r "$USER_CONF" ] || return 0
    awk -v want="$1" -v old="${2:-$(conf_old_name "$1")}" '{ sub(/\r$/, "") }
        /^\[.*\]$/ { name = substr($0, 2, length($0) - 2); if (name == want) has = 1; started = 1; next }
        /^[[:space:]]*(#|$)/ { next }
        !started { pre[++np] = $0; next }
        name == want { print; next }
        name == old { o[++no] = $0 }
        END { if (has) exit
              if (no) for (i = 1; i <= no; i++) print o[i]
              else if (want == "era") for (i = 1; i <= np; i++) print pre[i] }' "$USER_CONF"
}

# The sections the file has besides the usual ones and their older names, in file order
conf_other_names() {
    [ -r "$USER_CONF" ] || return 0
    awk -v known=" $CONF_SECTIONS wow_classic_era wow_classic " '{ sub(/\r$/, "") } /^\[.*\]$/ {
        name = substr($0, 2, length($0) - 2); if (index(known, " " name " ") == 0 && !seen[name]++) print name }' "$USER_CONF"
}

# write_config [LINES]: the file again, with LINES as this client's section (none: the section goes, and the file
# once it is empty)
write_config() {
    local tmp="${USER_CONF}.tmp.$$" name body any=false
    {
        echo "# Connection settings saved by the launcher, one section per client. launch.sh --reset clears one section."
        for name in $CONF_SECTIONS $(conf_other_names); do
            if [ "$name" = "$CLIENT" ]; then
                body="$1"
            else
                # The shared older [wow_classic] is only taken over by the client in _classic_ (kept below otherwise)
                case "$name" in tbc|wotlk|cata) body="$(conf_section "$name" -)" ;; *) body="$(conf_section "$name")" ;; esac
            fi
            [ -n "$body" ] || continue
            printf '\n[%s]\n%s\n' "$name" "$body"
        done
        case "$CLIENT" in tbc|wotlk|cata) ;; *)
            body="$(conf_section wow_classic -)"
            [ -n "$body" ] && printf '\n[%s]\n%s\n' wow_classic "$body"
            ;;
        esac
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    grep -q '^\[' "$tmp" && any=true
    if [ "$any" = true ]; then
        chmod 600 "$tmp" && mv "$tmp" "$USER_CONF"
    else
        rm -f "$tmp" "$USER_CONF"
    fi
}

# This client's settings: 0 = usable, 1 = none yet, 2 = garbage
load_config() {
    [ -f "$USER_CONF" ] || return 1
    [ -r "$USER_CONF" ] || return 2 # Can't read it, so treat it like garbage
    local key value use_proxy="" saved_ip="" section
    section="$(conf_section "$CLIENT")"
    [ -n "$section" ] || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            SAVED_USE_PROXY) use_proxy="$value" ;;
            SAVED_IP) saved_ip="$value" ;;
        esac
    done <<< "$section"

    # Both keys have to be present and sane, or the section counts as garbage
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
    write_config "$(printf 'SAVED_USE_PROXY=%s\nSAVED_IP=%s' "$SAVED_USE_PROXY" "$SAVED_IP")"
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
            echo "  --client <name>        era, tbc, wotlk or cata: the client to start when the game folder holds two"
            echo "  --checkpatch           Print PATCHED, UNPATCHED, UNKNOWN, or MISSING, and exit"
            echo "  --patch                Patch the binary only, don't launch"
            echo "  --reset                Clear the client's saved connection settings and caches"
            echo "  --getmissing [url|zip] Fetch an untouched 1.14 client, or install it from a zip on this computer"
            echo "  --bnet [ip[:port]]     Connect directly, bypassing the Connection Proxy (default ip: 127.0.0.1)"
            echo "  --switchproxy <name>   Use another proxy binary: its name in the proxy/ folder, or its path"
            echo "  --config <file>        Pass a custom proxy configuration file"
            echo "  --set <key=value>      Pass a proxy override, repeatable"
            echo "  --noaddon              Don't copy launcher/addons/<client> into the game"
            echo "  --help, -h             Show this help"
            echo ""
            echo "Options in launcher/options.txt are read first as defaults; command-line arguments override them."
            exit 0
            ;;
        --checkpatch)
            CHECK_PATCH=true
            shift
            ;;
        --noaddon)
            NO_ADDONS=true
            shift
            ;;
        --game)
            # BASE_DIR is already set, in the path definitions
            if [[ -n "$2" && ! "$2" =~ ^-- ]] && [ -d "$2" ]; then
                shift 2
            else
                echo "[!] --game requires an existing game folder (the one that holds _classic_era_ or _classic_)." >&2
                exit 1
            fi
            ;;
        --client)
            # CLIENT_ARG is already set, in the path definitions
            shift 2
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

# --checkpatch: print the state and exit - PATCHED also needs classicpatch.dylib in place. A folder with both clients
# and no --client: one line per client, the exit code of the first one not PATCHED
patch_state() {
    local state
    state=$(client_state)
    [ "$state" = PATCHED ] && [ ! -f "$CLASSICPATCH_DYLIB" ] && state=UNPATCHED
    echo "$state"
}
state_code() { case "$1" in PATCHED) echo 0 ;; UNPATCHED) echo 1 ;; UNKNOWN) echo 2 ;; *) echo 3 ;; esac; }
if [ "$CHECK_PATCH" = true ]; then
    if [ -z "$CLIENT_ARG" ] && has_flavor era && has_flavor classic; then
        CODE=0
        for f in era classic; do
            set_flavor "$f"
            detect_client
            CLIENT_STATE=$(patch_state)
            echo "$(flavor_version "$f") $CLIENT_STATE"
            [ "$CODE" -eq 0 ] && CODE=$(state_code "$CLIENT_STATE")
        done
        exit "$CODE"
    fi
    CLIENT_STATE=$(patch_state)
    echo "$CLIENT_STATE"
    exit "$(state_code "$CLIENT_STATE")"
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
echo "   WoW Classic - Patcher & Launcher"
echo "======================================="
[ ${#FILE_ARGS[@]} -gt 0 ] && echo "[*] Options from ${OPTIONS_FILE#"$BASE_DIR/"}: ${FILE_ARGS[*]}"
if [ -z "$CLIENT_ARG" ] && [ "$GET_MISSING" = false ] && has_flavor era && has_flavor classic; then
    choose_client
    detect_client
fi
CLIENT_SHOWN_VERSION="$(flavor_version "$FLAVOR")"
echo "[*] $CLIENT_NAME${CLIENT_SHOWN_VERSION:+ $CLIENT_SHOWN_VERSION}"

# --- Client Download ---
# file_size FILE: its size in bytes, 0 if it is not there
file_size() { stat -f %z "$1" 2>/dev/null || echo 0; }

# Free bytes on the game folder's disk
free_bytes() { df -k "$BASE_DIR" | awk 'NR == 2 { print $4 * 1024 }'; }

# gb BYTES: e.g. 6.8 GB
gb() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }

# Stops the piece downloads (each is a subshell running curl)
stop_download() {
    local pid
    for pid in "${DOWNLOAD_PIDS[@]}"; do
        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    done
    DOWNLOAD_PIDS=()
}

# fetch_part URL FILE FIRST LAST: those bytes of URL into FILE, asking only for what FILE is still missing
fetch_part() {
    local url="$1" file="$2" first="$3" last="$4" want have before attempt=0
    want=$((last - first + 1))
    while [ "$attempt" -lt 30 ]; do
        have=$(file_size "$file")
        # More than asked: the server ignored the range - start this piece over
        if [ "$have" -gt "$want" ]; then : > "$file"; have=0; fi
        [ "$have" -eq "$want" ] && return 0
        before=$have
        # A slow connection (under 50 KB/s for 30 s) is dropped and opened again: archive.org sets each connection's
        # speed when it opens. Low enough not to drop every connection of a slow line. Only tries that brought nothing count
        curl -fsL --connect-timeout 20 --speed-limit 51200 --speed-time 30 \
            -r "$((first + have))-$last" "$url" >> "$file" 2>/dev/null
        if [ "$(file_size "$file")" -eq "$before" ]; then
            attempt=$((attempt + 1))
            sleep 2
        fi
    done
    [ "$(file_size "$file")" -eq "$want" ]
}

# fetch_chunks URL OUT SIZE WORKER: chunks WORKER, WORKER + DOWNLOAD_PARTS, ... of URL into OUT.partN
fetch_chunks() {
    local url="$1" out="$2" size="$3" n first last
    for ((n = $4; n * DOWNLOAD_CHUNK < size; n += DOWNLOAD_PARTS)); do
        first=$((n * DOWNLOAD_CHUNK))
        last=$((first + DOWNLOAD_CHUNK - 1))
        [ "$last" -ge "$size" ] && last=$((size - 1))
        fetch_part "$url" "$out.part$n" "$first" "$last" || return 1
    done
}

# mirror_urls URL SIZE: URL, then the same file on the item's other servers when it is on archive.org (each server
# limits what it gives, so they add up); only those that report SIZE
mirror_urls() {
    local url="$1" size="$2" item path meta dir host u
    # The link itself, redirect followed on every request: where it leads can expire (GitHub's after an hour)
    echo "$url"
    [[ "$url" =~ ^https?://archive\.org/download/([^/]+)/(.+)$ ]] || return 0
    item="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    meta="$(mktemp)"
    curl -fsL --connect-timeout 20 --max-time 30 -o "$meta" "https://archive.org/metadata/$item" || { rm -f "$meta"; return 0; }
    dir="$(plutil -extract dir raw "$meta" 2>/dev/null)"
    for host in "$(plutil -extract d1 raw "$meta" 2>/dev/null)" "$(plutil -extract d2 raw "$meta" 2>/dev/null)"; do
        [ -n "$host" ] && [ -n "$dir" ] || continue
        u="https://$host$dir/$path"
        [ "$(curl -sI --connect-timeout 20 --max-time 30 "$u" | tr -d '\r' \
            | awk 'tolower($1) == "content-length:" { print $2 }')" = "$size" ] && echo "$u"
    done
    rm -f "$meta"
}

# download_file URL OUT: in DOWNLOAD_CHUNK chunks over DOWNLOAD_PARTS connections when the server allows it;
# a stopped download continues from the chunks already here
download_file() {
    local url="$1" out="$2" size=0 ranges="" chunks i have total elapsed rate alive pid failed=0
    # Size and byte-range support, asked up to 3 times (mirrors answer an error now and then)
    for i in 1 2 3; do
        size="$(curl -sIL --connect-timeout 20 --max-time 60 "$url" | tr -d '\r' \
            | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')"
        [ "$size" -gt 0 ] && ranges="$(curl -sL -r 0-15 --connect-timeout 20 --max-time 60 -o /dev/null -w '%{http_code}' "$url")"
        [ "$ranges" = 206 ] && break
        sleep 3
    done
    # Chunks of another download (other URL, size or chunk size) are not mixed in; an unknown size keeps them
    if [ "$size" -gt 0 ] && [ "$(cat "$out.source" 2>/dev/null)" != "$url $size $DOWNLOAD_CHUNK" ]; then
        rm -f "$out" "$out".part*
        echo "$url $size $DOWNLOAD_CHUNK" > "$out.source"
    fi
    [ "$size" -gt 0 ] && [ "$(file_size "$out")" -eq "$size" ] && return 0

    # No size or no byte ranges: one connection, which still continues a stopped download
    if [ "$ranges" != 206 ]; then
        echo "[*] The mirror does not allow several connections: downloading with one."
        curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 -C - -o "$out" "$url"
        return $?
    fi

    chunks=$(( (size + DOWNLOAD_CHUNK - 1) / DOWNLOAD_CHUNK ))
    downloaded() { local n t=0; for ((n = 0; n < chunks; n++)); do t=$((t + $(file_size "$out.part$n"))); done; echo $t; }
    have=$(downloaded)
    if [ "$have" -gt 0 ]; then
        echo "[*] Continuing the download: $(awk -v h="$have" -v s="$size" 'BEGIN { printf "%.1f of %.1f GB", h / 1e9, s / 1e9 }') already here."
    fi

    local urls=()
    while IFS= read -r i; do urls+=("$i"); done < <(mirror_urls "$url" "$size")
    [ "${#urls[@]}" -gt 1 ] && echo "[*] Downloading from ${#urls[@]} servers at once."
    DOWNLOAD_PARTS=$((DOWNLOAD_PER_SERVER * ${#urls[@]}))
    DOWNLOAD_PIDS=()
    for ((i = 0; i < DOWNLOAD_PARTS && i < chunks; i++)); do
        fetch_chunks "${urls[i % ${#urls[@]}]}" "$out" "$size" "$i" &
        DOWNLOAD_PIDS+=($!)
    done

    # Redraw a single status line in place; the speed is that of the last 10 s
    local hist=() now
    while :; do
        alive=0
        for pid in "${DOWNLOAD_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        total=$(downloaded)
        now=$(date +%s)
        hist+=("$now:$total")
        [ "${#hist[@]}" -gt 6 ] && hist=("${hist[@]:1}")
        elapsed=$(( now - ${hist[0]%%:*} ))
        [ "$elapsed" -gt 0 ] && rate=$(( (total - ${hist[0]#*:}) / elapsed )) || rate=0
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

    # Join the chunks: only one chunk's worth of extra disk at a time
    mv -f "$out.part0" "$out" || return 1
    for ((i = 1; i < chunks; i++)); do
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

    # Room for what is left to download plus the unpacked client (moved into place, not copied)
    if [ "$LOCAL_ZIP" = true ]; then
        ZIP_SIZE=$(file_size "$SELECTED_URL"); ZIP_HAVE=$ZIP_SIZE
    else
        ZIP_SIZE="$(curl -sIL --connect-timeout 20 --max-time 60 "$SELECTED_URL" | tr -d '\r' \
            | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')"
        ZIP_HAVE=$(file_size "$DOWNLOAD_DIR/$ZIP_NAME")
        for part in "$DOWNLOAD_DIR/$ZIP_NAME".part*; do [ -f "$part" ] && ZIP_HAVE=$((ZIP_HAVE + $(file_size "$part"))); done
    fi
    if [ "$ZIP_SIZE" -gt 0 ]; then
        NEED=$((ZIP_SIZE - ZIP_HAVE + ZIP_SIZE * 11 / 10))
        FREE=$(free_bytes)
        if [ "$NEED" -gt "$FREE" ]; then
            echo "[!] Not enough free space: the client needs about $(gb "$NEED") here (download and unpacked), $(gb "$FREE") is free." >&2
            echo "    Free some space, then run again." >&2
            abort_launch
        fi
    fi

    # Unpacked next to its destination, so installing it is a move
    GET_TMP="$(mktemp -d "$BASE_DIR/.extract.XXXXXX")"
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
    for entry in "$EXTRACTED_ROOT"/* "$EXTRACTED_ROOT"/.[!.]*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        # Moved when new; merged into what the folder already has otherwise
        if [ -e "$BASE_DIR/$name" ]; then
            ditto "$entry" "$BASE_DIR/$name"
        else
            mv "$entry" "$BASE_DIR/$name"
        fi || { echo "[!] Failed to install the client into $BASE_DIR" >&2; abort_launch; }
    done

    echo "[*] Client fetched and installed."
    rm -rf "$GET_TMP" "$DOWNLOAD_DIR"
    trap - EXIT INT TERM
    # Fall through into the patch-and-launch flow below instead of exiting
}

# 1. Make sure the client is actually here. Only Classic Era 1.14.0 can be fetched: the others are brought complete
if [ "$FLAVOR" = classic ] && { [ "$GET_MISSING" = true ] || [ ! -f "$GAME_BIN" ]; }; then
    echo "[!] No $CLIENT_NAME client to start in $FLAVOR_DIR" >&2
    abort_launch
fi
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
        echo "[!] Patcher is expecting $(awk 'NF { printf "%s%s (%s)", n++ ? ", " : "", $1, $2 }' <<< "$CLIENTS")." >&2
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
        echo "[!] connect.conf holds no usable settings for $CLIENT_NAME." >&2
        echo ""
        echo "==== Invalid Launcher Config File ====="
        echo "  [Yes] -> Reset the configuration"
        echo "   No   -> Exit, fix or delete connect.conf yourself"
        echo "======================================="
        if ask_yes "Reset $CLIENT_NAME's settings in connect.conf now?"; then
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
    # Only this client's section: the others keep theirs. A saved 4.x password for its server goes too
    RESET_IP="$(conf_section "$CLIENT" | sed -n 's/^SAVED_IP=//p' | tail -1)"
    [ -n "$RESET_IP" ] && keychain_forget "$RESET_IP"
    write_config ""
    rm -rf "$FLAVOR_DIR/Cache" "$FLAVOR_DIR/Logs"
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
        # A wrong or empty address asks again (direct: Enter = 127.0.0.1)
        while true; do
            if [ "$CONNECTION_TYPE" = "PROXY" ]; then
                read -e -r -p "Enter realmlist server address: " INPUT_IP
                SAVED_IP="$INPUT_IP"
                [ -n "$SAVED_IP" ] || { echo "[!] Enter the server's address." >&2; continue; }
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

    # Determine Proxy Binary: a name in the proxy folder, or a path to one elsewhere
    if [ -n "$CUSTOM_PROXY_BIN" ]; then
        case "$CUSTOM_PROXY_BIN" in
            */*) CUSTOM_PROXY_PATH="$CUSTOM_PROXY_BIN" ;;
            *) CUSTOM_PROXY_PATH="$PROXY_DIR/$CUSTOM_PROXY_BIN" ;;
        esac
        if [ -f "$CUSTOM_PROXY_PATH" ]; then
            PROXY_BIN="$(cd "$(dirname "$CUSTOM_PROXY_PATH")" && pwd)/$(basename "$CUSTOM_PROXY_PATH")"
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
    # 3.4.3+'s patched login seed comes from the ConnectTo modulus (classicpatch, Ed25519 mode), not appsettings' SeedHex.
    # As ClientSeed, the key every HermesProxy and fork reads (HermesProxy 4.3+ takes it for SeedHex)
    case "$CLIENT_VERSION" in
        3.*|4.*) PROXY_COMMAND+=("--set" "ClientSeed=5FD6800BA7FF0140C7BC8EF56B27B0BF") ;;
    esac

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

# Copies each addon folder of launcher/addons/<client> into the game, replacing an older copy of the same addon
install_addons() {
    local addon count=0
    [ -d "$ADDONS_DIR" ] || return 0
    for addon in "$ADDONS_DIR/$CLIENT"/*/; do
        [ -d "$addon" ] || continue
        addon="${addon%/}"
        mkdir -p "$GAME_ADDONS_DIR"
        rm -rf "${GAME_ADDONS_DIR:?}/$(basename "$addon")"
        ditto "$addon" "$GAME_ADDONS_DIR/$(basename "$addon")" && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && echo "[*] Installed $count addon(s) from launcher/addons/$CLIENT."
    return 0
}

# The game data (Data/data) is shared by the clients of this folder; the first one started keeps it open in its own
# layout. Classic Era and TBC Classic use an older one (Data/data/shmem version 4), which Cataclysm Classic cannot open:
# started after them, it stops with "Tact instance creation failed. Error (5)". Started first, it runs beside them;
# once they are closed, it rewrites the file in its own layout.
# other_games: "PID command" of this folder's other running clients
other_games() {
    ps -axo pid=,command= | grep -F -- "$BASE_DIR/_" | grep -F -- "/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic" \
        | grep -v -F -- "$GAME_BIN"
}

# quit_game PID: asks that game to quit, as its Quit menu does (a kill would leave the game reporting a hang), and
# waits up to 30 s for it
quit_game() {
    local i
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); a.isNil() ? false : a.terminate" > /dev/null 2>&1
    for ((i = 0; i < 30; i++)); do
        kill -0 "$1" 2> /dev/null || return 0
        sleep 1
    done
    return 1
}

# CLI default asks before closing the other game - the built .app closes it alone, as it restarts the proxy
close_other_games() {
    # WITHIN_APP:close_other_games:start
    if ! ask_yes "Close $RUNNING_NAME and start $CLIENT_NAME?"; then
        echo "    To play both, start $CLIENT_NAME first, then $RUNNING_NAME." >&2
        abort_launch
    fi
    # WITHIN_APP:close_other_games:end
}

case "$CLIENT_VERSION" in
    4.*)
        RUNNING_GAMES="$(other_games)"
        if [ -n "$RUNNING_GAMES" ] && [ "$(od -An -tu1 -N1 "$BASE_DIR/Data/data/shmem" 2>/dev/null | tr -d ' ')" = 4 ]; then
            case "$RUNNING_GAMES" in */_classic_era_/*) RUNNING_NAME="Classic Era" ;; *) RUNNING_NAME="TBC Classic" ;; esac
            echo "[!] $CLIENT_NAME cannot start while $RUNNING_NAME is running from this game folder." >&2
            close_other_games
            echo "[*] Closing $RUNNING_NAME..."
            for pid in $(awk '{ print $1 }' <<< "$RUNNING_GAMES"); do
                if ! quit_game "$pid"; then
                    echo "[!] $RUNNING_NAME did not close: close it yourself, then run again." >&2
                    abort_launch
                fi
            done
        fi
        ;;
esac

# 4. Execution Phase
[ "$NO_ADDONS" = true ] || install_addons
# Job control on, so the game gets its own process group, away from Ctrl+C
set -m

START_PROXY=true

# proxy_setting KEY ARGS...: the value of the last --set KEY=... in a proxy command
proxy_setting() {
    local key="$1" value="" arg
    shift
    for arg in "$@"; do
        [[ "$arg" == "$key="* ]] && value="${arg#*=}"
    done
    echo "$value"
}

# proxy_target ARGS...: the client and server a proxy command is for, e.g. 1.14.2 (42597) on logon.yourserver.com
proxy_target() {
    local build server version
    build="$(proxy_setting ClientBuild "$@")"
    server="$(proxy_setting ServerAddress "$@")"
    version="$(awk -v b="$build" '$2 == b { print $1 }' <<< "$CLIENTS")"
    echo "${version:-client} (${build:-unknown build}) on ${server:-an unknown server}"
}

# Stops the running proxy (RUNNING_PID) and waits up to 5 s for its port to be free
stop_running_proxy() {
    local i
    kill "$RUNNING_PID" 2>/dev/null
    for ((i = 0; i < 10; i++)); do
        lsof -nP -t -iTCP:"$PROXY_PORT" -sTCP:LISTEN > /dev/null 2>&1 || return 0
        sleep 0.5
    done
}

# CLI default asks, restart first when the running one is for another client or server - the built .app decides alone
proxy_already_running() {
    # WITHIN_APP:proxy_already_running:start
    if [ "$PROXY_MATCHES" = true ]; then
        if ask_yes "The Connection Proxy is already running for $RUNNING_TARGET. Keep it running?"; then
            echo "[*] Keeping the Connection Proxy running."
            START_PROXY=false
            return
        fi
    else
        echo "[!] The Connection Proxy already running is for $RUNNING_TARGET; this game needs $WANTED_TARGET."
        if ! ask_yes "Restart it for this game?"; then
            echo "[*] Keeping the Connection Proxy running."
            START_PROXY=false
            return
        fi
    fi
    stop_running_proxy
    # WITHIN_APP:proxy_already_running:end
}

# 4.x account passwords, in the macOS Keychain under this name, one per server
KEYCHAIN_SERVICE="Classic Launcher"
keychain_password() { security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null; }
# keychain_save SERVER PASSWORD: given to security on its input, so the password is never on a command line
keychain_save() {
    local pw="${2//\\/\\\\}"
    pw="${pw//\"/\\\"}"
    printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' "$KEYCHAIN_SERVICE" "$1" "$pw" | security -i > /dev/null 2>&1
}
keychain_forget() { security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" > /dev/null 2>&1; }

# read_masked PROMPT: a password into MASKED, shown as stars with only the last character typed visible; 1 if the input ends
read_masked() {
    local c
    MASKED=""
    # Ctrl+C cancels the launch, with the typed characters shown again in the terminal
    trap 'stty echo 2> /dev/null; echo ""; exit 130' INT
    printf '%s' "$1"
    # Only the end of the line changes (the line may wrap in a narrow terminal): the last character typed shows,
    # the one before turns into a star
    while :; do
        IFS= read -r -s -n 1 c || { trap - INT; echo ""; return 1; }
        case "$c" in
            "") break ;;
            $'\x03') stty echo 2> /dev/null; echo ""; exit 130 ;;
            $'\x7f'|$'\b') [ -n "$MASKED" ] && { MASKED="${MASKED%?}"; printf '\b \b'; } ;;
            [[:cntrl:]]) continue ;;
            *) [ -n "$MASKED" ] && printf '\b*'; MASKED="$MASKED$c"; printf '%s' "$c" ;;
        esac
    done
    trap - INT
    # Once entered, the last character hidden too
    [ -n "$MASKED" ] && printf '\b*'
    echo ""
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

# A running proxy is found by its BNet port, whatever its name: macOS lets a second one listen on the same port,
# and the game would reach either
PROXY_PORT="$(proxy_setting BNetPort "${PROXY_COMMAND[@]}")"
PROXY_PORT="${PROXY_PORT:-1119}"
RUNNING_PID="$(lsof -nP -t -iTCP:"$PROXY_PORT" -sTCP:LISTEN 2>/dev/null | head -1)"
if [ "$LAUNCH_PROXY" = true ] && [ -n "$RUNNING_PID" ]; then
    RUNNING_BIN="$(ps -o comm= -p "$RUNNING_PID")"
    # Its command line tells which client and server it was started for; one started by this launcher has a ClientBuild
    read -r -a RUNNING_ARGS <<< "$(ps -o args= -p "$RUNNING_PID")"
    if [ -n "$(proxy_setting ClientBuild "${RUNNING_ARGS[@]}")" ]; then
        RUNNING_TARGET="$(proxy_target "${RUNNING_ARGS[@]}") with ${RUNNING_BIN##*/}"
        WANTED_TARGET="$(proxy_target "${PROXY_COMMAND[@]}") with ${PROXY_BIN##*/}"
        [ "$RUNNING_BIN" = "$PROXY_BIN" ] && [ "$RUNNING_TARGET" = "$WANTED_TARGET" ] && PROXY_MATCHES=true || PROXY_MATCHES=false
        proxy_already_running
    else
        echo "[!] Port $PROXY_PORT is already used by ${RUNNING_BIN##*/} (PID $RUNNING_PID): the game may reach it instead of the Connection Proxy." >&2
    fi
fi

if [ "$LAUNCH_PROXY" = true ] && [ "$START_PROXY" = true ]; then
    # 4.x logs in with SRP and never sends the password: the proxy needs the server account's, through its
    # environment only (never in a file); without a terminal the proxy could not ask for it itself
    # Asked once per server, then kept in the Keychain (--reset forgets it)
    case "$CLIENT_VERSION" in
        4.*)
            if [ -z "${HERMES_LegacyServerOptions__Password:-}" ]; then
                HERMES_LegacyServerOptions__Password="$(keychain_password "$SAVED_IP")"
                [ -n "$HERMES_LegacyServerOptions__Password" ] && echo "[*] Account password for $SAVED_IP: from your Keychain."
            fi
            if [ -z "$HERMES_LegacyServerOptions__Password" ]; then
                echo ""
                echo "======= Cataclysm Classic Login ======="
                echo "  Password -> saved locally, in this Mac's Keychain"
                echo "  Ctrl+C   -> cancel"
                echo "======================================="
                while [ -z "$HERMES_LegacyServerOptions__Password" ]; do
                    read_masked "Enter your account password for $SAVED_IP: " || break
                    HERMES_LegacyServerOptions__Password="$MASKED"
                    [ -n "$HERMES_LegacyServerOptions__Password" ] || echo "[!] The password cannot be empty." >&2
                done
                [ -n "$HERMES_LegacyServerOptions__Password" ] && keychain_save "$SAVED_IP" "$HERMES_LegacyServerOptions__Password"
            fi
            export HERMES_LegacyServerOptions__Password
            ;;
    esac
    FULL_PROXY_CMD=("${PROXY_COMMAND[@]}")
    strip_quarantine "$PROXY_DIR" "$PROXY_BIN" "$OPENSSL_DIR"
    chmod +x "$PROXY_BIN" 2>/dev/null

    echo "[*] Executing Connection Proxy command: ${FULL_PROXY_CMD[*]}"
    echo "[*] Connection Proxy running..."

    # Watch the game from its own subshell - exec below stops this from reaping it
    (
        echo "[*] Launching the game..."
        echo "======================================="

        # Started from the game folder; exec keeps one PID to watch
        (cd "$BASE_DIR" && exec nohup "$GAME_BIN" > /dev/null 2>&1) &
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

    # A proxy elsewhere runs from its own folder, with its own appsettings.json
    cd "$(dirname "$PROXY_BIN")"
    # OpenSSL for proxies on .NET 6/7 (AES-GCM; they quit at start without it). HermesProxy 4.x on .NET 10 does not use it
    export DYLD_LIBRARY_PATH="$OPENSSL_DIR"
    # exec replaces this process with the proxy, so Ctrl+C reaches it directly
    # Stdin from /dev/null: HermesProxy before v4.7 waited for Enter when it quit
    exec "${FULL_PROXY_CMD[@]}" < /dev/null
else
    echo "[*] Launching the game..."
    echo "======================================="

    # Started from the game folder; exec keeps one PID to watch
    (cd "$BASE_DIR" && exec nohup "$GAME_BIN" > /dev/null 2>&1) &

    after_game_launched
fi
