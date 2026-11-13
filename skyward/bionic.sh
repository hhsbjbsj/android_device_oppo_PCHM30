#!/bin/bash
# Copy the arm64 dynamic linker and the libraries a NDK binary needs.
# Used only when the recovery service is not fully static. Real bionic
# comes from the Android 11 API 30 emulator system image. NDK copies are
# used only when they are ELF, not linker stubs.
set -euo pipefail

DEST="${1:?destination}"
NDK="${2:?ndk}"
mkdir -p "$DEST"

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

if [[ ! -f "$DEST/linker64" || ! -f "$DEST/libc.so" ]]; then
    sudo apt-get update
    sudo apt-get install -y android-sdk-libsparse-utils e2fsprogs unzip curl ca-certificates
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
    RAW=/tmp/system.raw.img
    if file "$IMG" | grep -qi "Android sparse"; then
        simg2img "$IMG" "$RAW"
    else
        cp -a "$IMG" "$RAW"
    fi
    ROOT=""
    if debugfs -R "stat bin/linker64" "$RAW" 2>/dev/null | grep -q "Inode:"; then
        ROOT=""
    elif debugfs -R "stat system/bin/linker64" "$RAW" 2>/dev/null | grep -q "Inode:"; then
        ROOT="system/"
    else
        echo "linker64 is not in the system image" >&2
        debugfs -R "ls -l" "$RAW" | head
        exit 1
    fi
    echo "system image root prefix '${ROOT}'"
    copy_elf_or_link "$RAW" "${ROOT}bin/linker64" "$DEST/linker64"
    chmod 755 "$DEST/linker64"
    for lib in libc.so libm.so libdl.so liblog.so libunwind.so libc++.so libstdc++.so; do
        copy_elf_or_link "$RAW" "${ROOT}lib64/$lib" "$DEST/$lib" || echo "no $lib in the image"
    done
fi

NDK_LIB="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
shopt -s nullglob
for src in "$NDK_LIB"/libc++_shared.so "$NDK_LIB"/libunwind.so "$NDK"/sources/cxx-stl/llvm-libc++/libs/arm64-v8a/libc++_shared.so; do
    if [[ -f "$src" ]] && file "$src" | grep -q ELF; then
        cp -a "$src" "$DEST/$(basename "$src")"
        echo "ndk $(basename "$src")"
    fi
done

echo "bionic files:"
ls -l "$DEST"
file "$DEST"/* || true
