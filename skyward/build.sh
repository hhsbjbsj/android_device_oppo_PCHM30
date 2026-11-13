#!/bin/bash
# Build Skyward for PCHM30 and pack a header v1 recovery image.
# Runs on GitHub Actions. Does not run on the phone.
set -euo pipefail

DEVICE="${GITHUB_WORKSPACE}/device"
SKYWARD="${GITHUB_WORKSPACE}/skyward"
OUT="${GITHUB_WORKSPACE}/out"
BIONIC="${GITHUB_WORKSPACE}/bionic"
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME is required}"

PREBUILT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
CLANG="$PREBUILT/aarch64-linux-android30-clang"
READELF="$PREBUILT/llvm-readelf"
mkdir -p "$OUT"

"$CLANG" -static -Os -Wall -Wextra -o "$OUT/init" "$DEVICE/skyward/init.c"
if "$READELF" -d "$OUT/init" 2>/dev/null | grep -q '(NEEDED)'; then
    echo "init is not static" >&2
    "$READELF" -d "$OUT/init" >&2 || true
    exit 1
fi
echo "init is static"

needed() {
    "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' || true
}

cd "$SKYWARD"
echo "building skyward"
set +e
RUSTFLAGS="-C target-feature=+crt-static" cargo ndk -t arm64-v8a --platform 30 build --locked --release -p skyward
static_rc=$?
set -e
BIN="$SKYWARD/target/aarch64-linux-android/release/skyward"
if [[ $static_rc -ne 0 || ! -f "$BIN" ]]; then
    echo "static skyward link failed; building it against bionic"
    cargo ndk -t arm64-v8a --platform 30 build --locked --release -p skyward
fi

echo "building system-init"
set +e
RUSTFLAGS="-C target-feature=+crt-static" cargo ndk -t arm64-v8a --platform 30 build --locked --release -p skyward-system-init --target-dir target/system-init
sinit_rc=$?
set -e
SINIT="$SKYWARD/target/system-init/aarch64-linux-android/release/system-init"
if [[ $sinit_rc -ne 0 || ! -f "$SINIT" ]]; then
    echo "static system-init link failed; building it dynamic"
    cargo ndk -t arm64-v8a --platform 30 build --locked --release -p skyward-system-init --target-dir target/system-init
fi

mapfile -t NEEDS < <(needed "$BIN")
LIBS_ARGS=()
if [[ ${#NEEDS[@]} -gt 0 ]]; then
    echo "skyward needs: ${NEEDS[*]}"
    bash "$DEVICE/skyward/bionic.sh" "$BIONIC" "$ANDROID_NDK_HOME"
    LIBS="$OUT/libs"
    rm -rf "$LIBS"
    mkdir -p "$LIBS"
    cp -a "$BIONIC/linker64" "$LIBS/linker64"
    for lib in "${NEEDS[@]}"; do
        if [[ -e "$BIONIC/$lib" ]]; then
            cp -a "$BIONIC/$lib" "$LIBS/$lib"
        else
            echo "no provider for $lib" >&2
            ls -l "$BIONIC" >&2
            exit 1
        fi
    done
    # system-init may need a library the recovery service did not.
    mapfile -t SNEEDS < <(needed "$SINIT")
    for lib in "${SNEEDS[@]}"; do
        if [[ -e "$LIBS/$lib" ]]; then
            continue
        fi
        if [[ -e "$BIONIC/$lib" ]]; then
            cp -a "$BIONIC/$lib" "$LIBS/$lib"
        else
            echo "system-init needs $lib, which was not extracted" >&2
            exit 1
        fi
    done
    LIBS_ARGS=(--libs "$LIBS")
else
    echo "skyward has no DT_NEEDED entries"
fi

python3 "$DEVICE/skyward/pack.py" \
    --kernel "$DEVICE/prebuilt/kernel" \
    --dtbo "$DEVICE/prebuilt/dtbo.img" \
    --binary "$BIN" \
    --system-init "$SINIT" \
    --init "$OUT/init" \
    --config "$DEVICE/skyward/pchm30.toml" \
    --font "$SKYWARD/resources/fonts/MiSansVF.ttf" \
    --mono "$SKYWARD/resources/fonts/KirkMono-Regular.ttf" \
    --mono-license "$SKYWARD/resources/fonts/KirkMono-OFL.txt" \
    --task-profiles "$SKYWARD/crates/skyward-pack/src/task_profiles.json" \
    "${LIBS_ARGS[@]}" \
    --out "$OUT/skyward-pchm30.img"

(
    cd "$OUT"
    sha256sum skyward-pchm30.img | tee SHA256SUMS
)
