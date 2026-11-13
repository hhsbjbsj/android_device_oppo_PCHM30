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
    if mountpoint -q /tmp/bionic-root; then
        sudo umount /tmp/bionic-root || true
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
        if start + 1024 + 16 > size:
            continue
        f.seek(start)
        head = f.read(4)
        f.seek(start + 0x438)
        ext = f.read(2)
        f.seek(start + 1024)
        at = f.read(4)
        f.seek(start + 4096)
        geo = f.read(4)
        kind = "unknown"
        if head == b"\x3a\xff\x26\xed":
            kind = "sparse"
        elif ext == b"\x53\xef":
            kind = "ext4"
        elif at == b"\xe2\xe1\xf5\xe0":
            kind = "erofs"
        elif at == b"\x10\x20\xf5\xf2":
            kind = "f2fs"
        elif geo == b"gDla":
            kind = "super"
        print(
            f"gpt entry {i}: {kind} offset {start} bytes {length} head {head.hex()} at1024 {at.hex()} at4096 {geo.hex()}",
            file=sys.stderr,
        )
        if best is None or length > best[0]:
            best = (length, start, kind)
if best is None:
    sys.exit(3)
print(f"{best[1]} {best[2]} {best[0]}")
PY
}

# The API 30 system partition is an Android sparse image inside the GPT entry.
unsparse_at() {
    python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
path, offset, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
RAW, FILL, DONT, CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
with open(path, "rb") as src, open(out_path, "wb") as out:
    src.seek(offset)
    hdr = src.read(28)
    magic, major, minor, file_hdr_sz, chunk_hdr_sz, blk_sz, total_blks, total_chunks, _sum = struct.unpack("<IHHHHIIII", hdr)
    if magic != 0xED26FF3A:
        sys.exit(f"not a sparse image at {offset}: {hdr[:4].hex()}")
    if file_hdr_sz > 28:
        src.read(file_hdr_sz - 28)
    out_size = blk_sz * total_blks
    print(f"sparse {total_chunks} chunks, {blk_sz}*{total_blks} = {out_size} bytes", file=sys.stderr)
    if out_size > 8 * 1024 ** 3:
        sys.exit(f"unsparse output is {out_size} bytes")
    for _ in range(total_chunks):
        ch = src.read(chunk_hdr_sz)
        if len(ch) < 12:
            sys.exit("short chunk header")
        ctype, _res, csz, total_sz = struct.unpack("<HHII", ch[:12])
        data_sz = total_sz - chunk_hdr_sz
        blen = csz * blk_sz
        if ctype == RAW:
            left = blen
            while left:
                buf = src.read(min(left, 8 << 20))
                if not buf:
                    sys.exit("short raw chunk")
                out.write(buf)
                left -= len(buf)
            extra = data_sz - blen
            if extra:
                src.read(extra)
        elif ctype == FILL:
            fill = src.read(4)
            if data_sz > 4:
                src.read(data_sz - 4)
            block = fill * (1 << 18)
            left = blen
            while left:
                n = min(left, len(block))
                out.write(block[:n])
                left -= n
        elif ctype == DONT:
            out.seek(blen, 1)
            if data_sz:
                src.read(data_sz)
        elif ctype == CRC:
            src.read(data_sz)
        else:
            sys.exit(f"unknown sparse chunk {ctype:#x}")
    out.truncate(out_size)
PY
}

# API 30 emulator images store system inside a dynamic "super" partition.
# Geometry magic gDla sits 4096 bytes into that partition.
extract_logical_system() {
    python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
image, super_off, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
GEOMETRY = 0x616C4467
HEADER = 0x414C5030
with open(image, "rb") as src:
    src.seek(super_off + 4096)
    magic, struct_size = struct.unpack("<II", src.read(8))
    if magic != GEOMETRY:
        sys.exit(f"super geometry magic {magic:#x}")
    meta = super_off + 4096 * 3
    src.seek(meta)
    hdr = src.read(256)
    hmagic, major, minor, header_size = struct.unpack_from("<IHH I", hdr, 0)
    if hmagic != HEADER:
        sys.exit(f"lp header magic {hmagic:#x}")
    tables_size = struct.unpack_from("<I", hdr, 44)[0]
    def desc(at):
        return struct.unpack_from("<III", hdr, at)
    part_off, part_n, part_esz = desc(80)
    ext_off, ext_n, ext_esz = desc(92)
    src.seek(meta + header_size)
    tables = src.read(tables_size)
    parts = []
    for i in range(part_n):
        raw = tables[part_off + i * part_esz: part_off + i * part_esz + 52]
        name, _attr, first, num, _group = struct.unpack("<36s4I", raw[:52])
        name = name.split(b"\x00", 1)[0].decode()
        parts.append((name, first, num))
        print(f"lp {name} extents {num} first {first}", file=sys.stderr)
    extents = []
    for i in range(ext_n):
        raw = tables[ext_off + i * ext_esz: ext_off + i * ext_esz + 24]
        extents.append(struct.unpack("<QIQI", raw[:24]))
    chosen = None
    for want in ("system", "system_a"):
        for part in parts:
            if part[0] == want:
                chosen = part
                break
        if chosen:
            break
    if chosen is None:
        sys.exit("super has no system partition")
    print(f"extracting {chosen[0]}", file=sys.stderr)
    written = 0
    with open(out_path, "wb") as out:
        for n in range(chosen[2]):
            num_sectors, target_type, target_data, _source = extents[chosen[1] + n]
            blen = num_sectors * 512
            if target_type == 1:
                out.seek(blen, 1)
            elif target_type == 0:
                src.seek(super_off + target_data * 512)
                left = blen
                while left:
                    buf = src.read(min(left, 8 << 20))
                    if not buf:
                        sys.exit("short system extent")
                    out.write(buf)
                    left -= len(buf)
            else:
                sys.exit(f"unsupported extent type {target_type}")
            written += blen
        out.truncate(written)
    print(f"logical system {written} bytes", file=sys.stderr)
PY
}

mount_image() {
    local image="$1" point="$2"
    sudo mkdir -p "$point"
    if debugfs -R "stat ." "$image" 2>/dev/null | grep -q "Inode:"; then
        sudo mount -o ro,loop "$image" "$point"
        return 0
    fi
    local line off kind length fs
    line=$(partition_of "$image")
    read -r off kind length <<<"$line"
    echo "mount $image offset $off as $kind ($length bytes) on $point"
    if [[ "$kind" == "super" ]]; then
        extract_logical_system "$image" "$off" /tmp/logical-system.img
        file /tmp/logical-system.img || true
        if ! sudo mount -o ro,loop /tmp/logical-system.img "$point"; then
            echo "read-only mount failed; clearing shared_blocks so debugfs can read it" >&2
            e2fsck -fy -E unshare_blocks /tmp/logical-system.img || true
            sudo mount -o ro,loop /tmp/logical-system.img "$point"
        fi
        return 0
    fi
    fs="$image"
    if [[ "$kind" == "sparse" ]]; then
        unsparse_at "$image" "$off" /tmp/part.raw
        file /tmp/part.raw
        fs=/tmp/part.raw
        kind=""
        if debugfs -R "stat ." "$fs" 2>/dev/null | grep -q "Inode:"; then
            sudo mount -o ro,loop "$fs" "$point"
            return 0
        fi
        # Unsparse output can itself be a filesystem with a normal superblock.
        local at
        at=$(od -An -t x1 -N 2 -j 1080 "$fs" | tr -d ' \n')
        if [[ "$at" == "53ef" ]]; then
            kind=ext4
        fi
        off=0
    fi
    if [[ "$kind" != "ext4" && "$kind" != "erofs" && "$kind" != "f2fs" ]]; then
        echo "unrecognized filesystem (kind ${kind:-empty})" >&2
        xxd -l 64 -s "$off" "$fs" >&2 || true
        exit 1
    fi
    sudo mount -o ro,loop,offset="$off" -t "$kind" "$fs" "$point"
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
        sudo ls -l "$SYSROOT" "$SYSROOT/system/bin/linker64" "$SYSROOT/system/lib64" 2>/dev/null | head -40 || true
        # Directories in the image are not searchable by the runner user.
        # Copy the linker, libraries and apex payloads out as root.
        VIEW=/tmp/bionic-view
        sudo rm -rf "$VIEW"
        sudo mkdir -p "$VIEW"
        for rel in bin lib64 system/bin system/lib64 system/lib system/apex apex; do
            if sudo test -e "$SYSROOT/$rel"; then
                sudo mkdir -p "$VIEW/$(dirname "$rel")"
                sudo cp -a "$SYSROOT/$rel" "$VIEW/$rel"
            fi
        done
        sudo chown -R "$(id -u):$(id -g)" "$VIEW"
        SYSROOT="$VIEW"
        LINKER=""
        if [[ -e "$SYSROOT/bin/linker64" || -L "$SYSROOT/bin/linker64" ]]; then
            LINKER="$SYSROOT/bin/linker64"
        elif [[ -e "$SYSROOT/system/bin/linker64" || -L "$SYSROOT/system/bin/linker64" ]]; then
            LINKER="$SYSROOT/system/bin/linker64"
        else
            LINKER=$(find "$SYSROOT" -name linker64 \( -type f -o -type l \) 2>/dev/null | head -1 || true)
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
