#!/bin/bash
# patch_binary.sh FILE DYLIB - makes the executable FILE load the library DYLIB when it starts.
#
# The game's code is encrypted on disk, so it can't be patched as a file. Instead, one LC_LOAD_DYLIB load command is
# added to each slice (arm64 and x86_64): macOS (dyld) then loads DYLIB before the game runs, and DYLIB patches the
# game in memory. DYLIB is a path as dyld reads it, e.g. @executable_path/../Frameworks/classicpatch.dylib.
#
# Steps: remove the signature (it covers the load commands), add the load command, sign again ad-hoc with the
# original identifier and without hardened runtime (which would refuse an unsigned library), verify.
# FILE is changed in place: give it a copy, it is unusable if this fails.
# Exit 0 on success, 1 on failure. Needs only tools that come with macOS (od, dd, printf, head, codesign).

FILE="$1"
DYLIB="$2"

# --- Mach-O reading and writing ---
# u32_le / u32_be FILE OFFSET: a 32-bit number from the file
u32_le() { od -An -tu4 -j "$2" -N4 "$1" | tr -d ' '; }
u32_be() { echo $(( 16#$(od -An -tx1 -j "$2" -N4 "$1" | tr -d ' \n') )); }

# put_u32_le FILE OFFSET VALUE
put_u32_le() {
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($3 & 255)) $(($3 >> 8 & 255)) $(($3 >> 16 & 255)) $(($3 >> 24 & 255)))" \
        | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

# The load command: LC_LOAD_DYLIB (0xc), cmdsize, name offset 24, timestamp 2, versions 1.0, then DYLIB and zero
# bytes up to cmdsize = 24 + path + at least one zero, rounded up to a multiple of 8
load_command() {
    local size=$(((24 + ${#DYLIB} + 1 + 7) / 8 * 8))
    printf '\x0c\x00\x00\x00'
    printf "$(printf '\\x%02x' "$size")"
    printf '\x00\x00\x00\x18\x00\x00\x00\x02\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00'
    printf '%s' "$DYLIB"
    head -c $((size - 24 - ${#DYLIB})) /dev/zero
}

# slice_room FILE OFFSET: bytes free between the load commands of the 64-bit slice at OFFSET and its first section.
# Reads the header and load commands as 32-bit words: ncmds = word 4, sizeofcmds = word 5, commands from word 8.
# In an LC_SEGMENT_64 (0x19), nsects is word 16 and the sections (20 words each) start at word 18; a section's file
# offset is its word 12 (0 for sections without file data).
slice_room() {
    local f="$1" off="$2" words=() p c k s sect_off first=0
    [ "$(od -An -tx1 -j "$off" -N4 "$f" | tr -d ' \n')" = "cffaedfe" ] || return 1
    words=($(od -An -v -tu4 -j "$off" -N $((32 + $(u32_le "$f" $((off + 20))))) "$f"))
    p=8
    for ((c = 0; c < words[4]; c++)); do
        if [ "${words[p]}" -eq 25 ]; then
            for ((k = 0; k < words[p + 16]; k++)); do
                s=${words[p + 18 + k * 20 + 12]}
                if [ "$s" -gt 0 ] && { [ "$first" -eq 0 ] || [ "$s" -lt "$first" ]; }; then
                    first=$s
                fi
            done
        fi
        p=$((p + words[p + 1] / 4))
    done
    [ "$first" -gt 0 ] || return 1
    echo $((first - 32 - words[5]))
}

# Appends the load command to every slice. Checks all slices first, so nothing is changed if one has no room.
add_load_command() {
    local f="$1" size=$(($(load_command | wc -c))) slices=() off end n i room
    case "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" in
        cafebabe)
            n=$(u32_be "$f" 4)
            for ((i = 0; i < n; i++)); do
                slices+=("$(u32_be "$f" $((8 + i * 20 + 8)))")
            done
            ;;
        cffaedfe) slices=(0) ;;
        *) return 1 ;;
    esac
    for off in "${slices[@]}"; do
        room=$(slice_room "$f" "$off") || return 1
        [ "$room" -ge "$size" ] || return 1
        # The free space must really be free: zero padding
        end=$((off + 32 + $(u32_le "$f" $((off + 20)))))
        [ -z "$(od -v -An -tx1 -j "$end" -N"$size" "$f" | tr -d ' 0\n')" ] || return 1
    done
    for off in "${slices[@]}"; do
        end=$((off + 32 + $(u32_le "$f" $((off + 20)))))
        load_command | dd of="$f" bs=1 seek="$end" conv=notrunc 2>/dev/null
        put_u32_le "$f" $((off + 16)) $(($(u32_le "$f" $((off + 16))) + 1))       # ncmds
        put_u32_le "$f" $((off + 20)) $(($(u32_le "$f" $((off + 20))) + size))    # sizeofcmds
    done
}

# --- Main ---
# 200 keeps cmdsize in one byte
if [ ! -f "$FILE" ] || [ ! -w "$FILE" ] || [ -z "$DYLIB" ] || [ "${#DYLIB}" -gt 200 ]; then
    echo "Usage: patch_binary.sh FILE DYLIB   (FILE must be a writable executable)" >&2
    exit 1
fi
# A second load command for the same library would make dyld fail
if LC_ALL=C grep -a -q -F "$DYLIB" "$FILE"; then
    echo "[!] $FILE already loads $DYLIB" >&2
    exit 1
fi

# The original identifier (the game's bundle id) keeps the game's own settings and permissions working
SIGN=(codesign -s -)
ID="$(codesign -dv "$FILE" 2>&1 | sed -n 's/^Identifier=//p')"
[ -n "$ID" ] && SIGN+=(-i "$ID")

if ! codesign --remove-signature "$FILE"; then
    echo "[!] Could not remove the signature of $FILE" >&2
    exit 1
fi
if ! add_load_command "$FILE"; then
    echo "[!] $FILE is not a 64-bit Mach-O executable with room for one more load command" >&2
    exit 1
fi
if ! "${SIGN[@]}" "$FILE" 2>/dev/null || ! codesign --verify "$FILE"; then
    echo "[!] Could not sign $FILE again" >&2
    exit 1
fi
exit 0
