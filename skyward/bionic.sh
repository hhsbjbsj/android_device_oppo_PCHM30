#!/bin/bash
# Copy the arm64 dynamic linker and the libraries a NDK binary needs.
# Used only when the recovery service is not fully static. Real bionic
# comes from the Android 11 API 30 emulator system image. That image is a
# GPT disk with an ext4 partition, and libc lives in the runtime apex.
# NDK copies are used only when they are ELF, not linker stubs.
set -euo pipefail

DEST="${1:?destination}"
NDK="${2:?ndk}"
mkdir -p "$DEST"

SYSROOT=""
APEX_ROOT=""
cleanup_mounts() {
    if [[ -n "$APEX_ROOT" ]] && mountpoint -q "$APEX_ROOT"; then
        sudo umount "$APEX_ROOT" || true
    fi
    if [[ -n "$SYSROOT" ]] && mountpoint -q "$SYSROOT"; then
        sudo umount "$SYSROOT" || true
    fi
}
trap cleanup_mounts EXIT

copy_elf_or_link() {
    local image="$1" src="$2" dst="$3"
    local stat
    stat=$(debugfs -R "stat $src" "$image" 2>/dev/null || true)
    if ! grep -q "Inode:" <<<"$stat"; then
        return 1
    fi
    if grep -qi "Type: symlink" <<<"$stat"; then
        local target
        target=$(sed -n 's/.*Fast link dest: "//p' <<<"$stat" | head -1 | tr -d '"')
        if [[ -z "$target" ]]; then
            target=$(sed -n 's/.*Fast link dest: //p' <<<"$stat" | head -1 | tr -d '"')
        fi
        ln -sfn "$target" "$dst"
        echo "link $src -> $target"
        return 0
    fi
    rm -f "$dst"
    debugfs -R "dump $src $dst" "$image" >/dev/null
    echo "file $src ($(wc -c <"$dst") bytes)"
}

# Print "offset kind" for the largest ext4 or erofs partition. kind is ext4 or erofs.
partition_of() {
    python3 - "$1" <<'PY'
import struct, sys
path = sys.argv[1]
with open(path, "rb") as f:
    size = f.seek(0, 2)
    sector = None
    hdr = b""
    for sec in (512, 4096):
        if size < sec + 92:
            continue
        f.seek(sec)
        hdr = f.read(92)
        if hdr[:8] == b"EFI PART":
            sector = sec
            break
    if sector is None:
        sys.exit(2)
    entry_lba, nent, esize = struct.unpack_from("<QII", hdr, 72)
    f.seek(entry_lba * sector)
    blob = f.read(nent * esize)
    best = None
    for i in range(nent):
        e = blob[i * esize:(i + 1) * esize]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        if last < first:
            continue
        start = first * sector
        length = (last - first + 1) * sector
        if start + 0x438 + 2 > size:
            continue
        f.seek(start + 0x438)
        ext = f.read(2)
        f.seek(start + 1024)
        ero = f.read(4)
        kind = ""
        if ext == b"\x53\xef":
            kind = "ext4"
        elif ero == b"\xe2\xe1\xf5\xe0":
            kind = "erofs"
        print(f"gpt entry {i}: {kind or 'other'} offset {start} bytes {length}", file=sys.stderr)
        if kind and (best is None or length > best[0]):
            best = (length, start, kind)
if best is None:
    sys.exit(3)
print(f"{best[1]} {best[2]}")
PY
}

mount_image() {
    local image="$1" point="$2"
    sudo mkdir -p "$point"
    if debugfs -R "stat ." "$image" 2>/dev/null | grep -q "Inode:"; then
        sudo mount -o ro,loop "$image" "$point"
        return 0
    fi
    local line off kind
    line=$(partition_of "$image")
    off=${line%% *}
    kind=${line##* }
    echo "mount $image offset $off as $kind on $point"
    sudo mount -o ro,loop,offset="$off" -t "$kind" "$image" "$point"
}

# Copy a file or a symlink. A symlink to linker64 stays a symlink. Any other
# symlink is copied as the file it names, so the ramdisk does not need /apex.
copy_tree_entry() {
    local src="$1" dst="$2"
    if [[ ! -e "$src" && ! -L "$src" ]]; then
        return 1
    fi
    if [[ -L "$src" ]]; then
        local target resolved=""
        target=$(readlink "$src")
        case "$target" in
            linker64|/system/bin/linker64|../bin/linker64|bin/linker64)
                ln -sfn "$target" "$dst"
                echo "link $(basename "$src") -> $target"
                return 0
                ;;
        esac
        if [[ "$target" == /* ]]; then
            if [[ -n "$SYSROOT" && -e "$SYSROOT$target" ]]; then
                resolved="$SYSROOT$target"
            elif [[ -n "$APEX_ROOT" && -e "$APEX_ROOT${target#/apex/com.android.runtime}" ]]; then
                resolved="$APEX_ROOT${target#/apex/com.android.runtime}"
            fi
        else
            resolved="$(dirname "$src")/$target"
        fi
        if [[ -f "$resolved" ]]; then
            rm -f "$dst"
            cp -a "$resolved" "$dst"
            echo "file $(basename "$src") via $target ($(wc -c <"$dst") bytes)"
            return 0
        fi
        echo "dangling $(basename "$src") -> $target" >&2
        return 1
    fi
    rm -f "$dst"
    cp -a "$src" "$dst"
    echo "file $(basename "$src") ($(wc -c <"$dst") bytes)"
}

take_lib() {
    local name="$1"
    local candidate
    local -a candidates=(
        "$SYSROOT/lib64/$name"
        "$SYSROOT/system/lib64/$name"
        "$SYSROOT/apex/com.android.runtime/lib64/bionic/$name"
    )
    if [[ -n "$APEX_ROOT" ]]; then
        candidates+=(
            "$APEX_ROOT/lib64/bionic/$name"
            "$APEX_ROOT/lib64/$name"
        )
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            if copy_tree_entry "$candidate" "$DEST/$name"; then
                return 0
            fi
        fi
    done
    if [[ -n "$SYSROOT" ]]; then
        local found
        found=$(find "$SYSROOT" ${APEX_ROOT:+"$APEX_ROOT"} -name "$name" -type f 2>/dev/null | head -1 || true)
        if [[ -n "$found" ]]; then
            copy_tree_entry "$found" "$DEST/$name"
            return 0
        fi
    fi
    echo "no $name in the system image" >&2
    return 1
}

mount_runtime_apex() {
    local apex=""
    apex=$(find "$SYSROOT" -name 'com.android.runtime*.apex' -o -name 'com.android.runtime*.capex' 2>/dev/null | head -1 || true)
    if [[ -z "$apex" ]]; then
        echo "no com.android.runtime apex under $SYSROOT"
        return 1
    fi
    echo "runtime apex $apex"
    rm -rf /tmp/apex-unpack
    mkdir -p /tmp/apex-unpack
    unzip -q "$apex" -d /tmp/apex-unpack
    local payload=/tmp/apex-unpack/apex_payload.img
    if [[ ! -f "$payload" ]]; then
        echo "apex has no apex_payload.img" >&2
        find /tmp/apex-unpack -maxdepth 2 -type f -print >&2
        return 1
    fi
    file "$payload" || true
    if file "$payload" | grep -qi 'lz4'; then
        lz4 -d -f "$payload" /tmp/apex-unpack/payload.raw
        payload=/tmp/apex-unpack/payload.raw
    fi
    APEX_ROOT=/tmp/apex-root
    mount_image "$payload" "$APEX_ROOT"
    echo "apex root:"
    ls -l "$APEX_ROOT" "$APEX_ROOT/lib64" "$APEX_ROOT/lib64/bionic" 2>/dev/null || true
}

if [[ ! -f "$DEST/linker64" || ! -e "$DEST/libc.so" ]]; then
    sudo apt-get update
    sudo apt-get install -y android-sdk-libsparse-utils e2fsprogs unzip curl ca-certificates lz4
    ZIP="${BIONIC_ZIP:-/tmp/arm64-v8a-30_r10.zip}"
    URL="https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-30_r10.zip"
    if [[ ! -f "$ZIP" ]]; then
        curl -L --fail --retry 3 -o "$ZIP" "$URL"
    fi
    rm -rf /tmp/sysimg
    mkdir -p /tmp/sysimg
    unzip -q "$ZIP" -d /tmp/sysimg
    IMG=$(find /tmp/sysimg -name system.img -print -quit)
    echo "system image $IMG"
    file "$IMG"
    RAW="$IMG"
    if file "$IMG" | grep -qi "Android sparse"; then
        RAW=/tmp/system.raw.img
        simg2img "$IMG" "$RAW"
        file "$RAW"
    fi
    if debugfs -R "stat bin/linker64" "$RAW" 2>/dev/null | grep -q "Inode:" || \
       debugfs -R "stat system/bin/linker64" "$RAW" 2>/dev/null | grep -q "Inode:"; then
        ROOT=""
        if debugfs -R "stat bin/linker64" "$RAW" 2>/dev/null | grep -q "Inode:"; then
            ROOT=""
        else
            ROOT="system/"
        fi
        echo "system image root prefix '${ROOT}'"
        copy_elf_or_link "$RAW" "${ROOT}bin/linker64" "$DEST/linker64"
        chmod 755 "$DEST/linker64"
        for lib in libc.so libm.so libdl.so liblog.so libunwind.so libc++.so libstdc++.so; do
            copy_elf_or_link "$RAW" "${ROOT}lib64/$lib" "$DEST/$lib" || echo "no $lib in the image"
        done
    else
        echo "system image is a disk image; mounting its filesystem"
        SYSROOT=/tmp/bionic-root
        mount_image "$RAW" "$SYSROOT"
        echo "mounted system root:"
        ls -l "$SYSROOT" | head
        LINKER=""
        if [[ -e "$SYSROOT/bin/linker64" ]]; then
            LINKER="$SYSROOT/bin/linker64"
        elif [[ -e "$SYSROOT/system/bin/linker64" ]]; then
            LINKER="$SYSROOT/system/bin/linker64"
        else
            LINKER=$(find "$SYSROOT" -name linker64 -type f 2>/dev/null | head -1 || true)
        fi
        if [[ -z "$LINKER" ]]; then
            echo "linker64 is not in the system image" >&2
            find "$SYSROOT" -name 'linker*' | head >&2 || true
            exit 1
        fi
        copy_tree_entry "$LINKER" "$DEST/linker64"
        chmod 755 "$DEST/linker64"
        # libc on Android 11 is inside the runtime apex, not a plain file in lib64.
        mount_runtime_apex || echo "runtime apex not mounted; trying lib64 as shipped"
        for lib in libc.so libm.so libdl.so liblog.so libunwind.so libc++.so libstdc++.so; do
            take_lib "$lib" || echo "no $lib in the image"
        done
    fi
fi

NDK_LIB="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
shopt -s nullglob
for src in "$NDK_LIB"/libc++_shared.so "$NDK_LIB"/libunwind.so "$NDK"/sources/cxx-stl/llvm-libc++/libs/arm64-v8a/libc++_shared.so; do
    if [[ -f "$src" ]] && file "$src" | grep -q ELF; then
        cp -a "$src" "$DEST/$(basename "$src")"
        echo "ndk $(basename "$src")"
    fi
done

if ! file -L "$DEST/linker64" | grep -q ELF; then
    echo "linker64 is not an ELF" >&2
    file -L "$DEST/linker64" >&2 || true
    exit 1
fi
if ! file -L "$DEST/libc.so" | grep -q ELF; then
    echo "libc.so is not an ELF" >&2
    file -L "$DEST/libc.so" >&2 || true
    ls -l "$DEST" >&2 || true
    exit 1
fi
echo "bionic files:"
ls -l "$DEST"
file -L "$DEST"/* || true
