#!/usr/bin/env python3
"""Pack a header v1 recovery image for PCHM30.

Skyward's own packer only reads boot header v3/v4. This phone's recovery
is header v1: kernel, gzip ramdisk, then the dtbo at recovery_dtbo_offset.
The image is not padded to the partition and has no AVB footer. vbmeta is
a separate partition.
"""

import argparse
import gzip
import hashlib
import os
import struct
import sys
from pathlib import Path

PAGE = 4096
HEADER_BYTES = 1648
PARTITION = 67108864
KERNEL_ADDR = 0x00008000
RAMDISK_ADDR = 0x01000000
SECOND_ADDR = 0x00F00000
TAGS_ADDR = 0x00000100

# BoardConfig.mk BOARD_KERNEL_CMDLINE, then permissive SELinux. The kernel
# reads enforcing=; Android init reads androidboot.selinux=.
CMDLINE = (
    "console=ttyMSM0,115200n8 androidboot.hardware=qcom androidboot.console=ttyMSM0 "
    "androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 "
    "msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=1 earlycon=msm_geni_serial,0x4a90000 "
    "loop.max_part=7 cgroup.memory=nokmem,nosocket buildvariant=user "
    "androidboot.selinux=permissive enforcing=0"
)

# 11.0.0 / 2022-05, the ColorOS 11 build named by the device fingerprint.
OS_VERSION = (11 << 25) | ((2022 - 2000) << 4) | 5

PROP_DEFAULT = """\
ro.secure=0
ro.adb.secure=0
ro.debuggable=1
ro.ota.allow_downgrade=true
ro.boot.dynamic_partitions=false
ro.build.version.release=11
ro.build.display.id=RKQ1.200903.002
ro.product.brand=OPPO
ro.product.model=OPPO A11x
ro.product.device=PCHM30
ro.product.name=PCHM30
"""

DIRS = [
    "proc",
    "sys",
    "dev",
    "dev/input",
    "dev/dri",
    "dev/block",
    "dev/block/by-name",
    "tmp",
    "data",
    "cache",
    "metadata",
    "mnt",
    "mnt/vendor",
    "mnt/vendor/persist",
    "persist",
    "odm",
    "vendor",
    "vendor/firmware_mnt",
    "system",
    "system/bin",
    "system/lib64",
    "system/etc",
    "skyward",
    "skyward/run",
]

COMMANDS = ["7za", "avbctl", "resetprop", "unzip", "zstd"]


def pad4(blob: bytes) -> bytes:
    return blob + b"\0" * ((4 - (len(blob) % 4)) % 4)


def cpio_newc(entries) -> bytes:
    """entries: (name, mode, data_or_target). Symlinks are mode 0o120777 and data is the target bytes."""
    out = bytearray()
    ino = 1
    for name, mode, data in entries:
        if name.startswith("/"):
            raise SystemExit(f"ramdisk path must not start with /: {name}")
        name_b = name.encode() + b"\0"
        header = (
            "070701"
            f"{ino:08X}"
            f"{mode:08X}"
            "00000000"
            "00000000"
            "00000001"
            "00000000"
            f"{len(data):08X}"
            "00000000"
            "00000000"
            "00000000"
            "00000000"
            f"{len(name_b):08X}"
            "00000000"
        ).encode()
        if len(header) != 110:
            raise SystemExit(f"cpio header is {len(header)} bytes")
        out += pad4(header + name_b)
        out += pad4(data)
        ino += 1
    trailer = "TRAILER!!!\0".encode()
    header = (
        "070701"
        f"{ino:08X}"
        "00000000"
        "00000000"
        "00000000"
        "00000001"
        "00000000"
        "00000000"
        "00000000"
        "00000000"
        "00000000"
        "00000000"
        f"{len(trailer):08X}"
        "00000000"
    ).encode()
    out += pad4(header + trailer)
    return bytes(out)


def page_pad(blob: bytes) -> bytes:
    extra = (PAGE - (len(blob) % PAGE)) % PAGE
    return blob + b"\0" * extra


def pages(size: int) -> int:
    return (size + PAGE - 1) // PAGE


def build_ramdisk(args) -> bytes:
    entries = []
    seen = set()

    def add_dir(name: str) -> None:
        if name in seen:
            return
        entries.append((name, 0o040755, b""))
        seen.add(name)

    def add_file(name: str, mode: int, data: bytes) -> None:
        parent = name.rsplit("/", 1)[0] if "/" in name else ""
        if parent:
            parts = parent.split("/")
            for i in range(len(parts)):
                add_dir("/".join(parts[: i + 1]))
        if name in seen:
            raise SystemExit(f"duplicate ramdisk path {name}")
        entries.append((name, mode, data))
        seen.add(name)

    def add_link(name: str, target: str) -> None:
        add_file(name, 0o120777, target.encode())

    for directory in DIRS:
        add_dir(directory)
    add_file("init", 0o100755, Path(args.init).read_bytes())
    add_file("prop.default", 0o100644, PROP_DEFAULT.encode())
    add_file("system/bin/recovery", 0o100755, Path(args.binary).read_bytes())
    for command in COMMANDS:
        add_link(f"system/bin/{command}", "recovery")
    add_file("skyward/device.toml", 0o100644, Path(args.config).read_bytes())
    add_file("skyward/MiSansVF.ttf", 0o100644, Path(args.font).read_bytes())
    add_file("skyward/KirkMono-Regular.ttf", 0o100644, Path(args.mono).read_bytes())
    add_file("skyward/KirkMono-OFL.txt", 0o100644, Path(args.mono_license).read_bytes())
    add_file("skyward/system-init", 0o100755, Path(args.system_init).read_bytes())
    if args.task_profiles:
        add_file("system/etc/task_profiles.json", 0o100644, Path(args.task_profiles).read_bytes())
    if args.libs:
        libdir = Path(args.libs)
        linker = libdir / "linker64"
        if not linker.exists():
            raise SystemExit(f"{linker} is required when --libs is set")
        add_file("system/bin/linker64", 0o100755, linker.read_bytes())
        for path in sorted(libdir.iterdir()):
            if path.name == "linker64" or not path.name.endswith(".so"):
                continue
            dest = f"system/lib64/{path.name}"
            if path.is_symlink():
                target = os.readlink(path)
                if target in ("linker64", "/system/bin/linker64", "../bin/linker64"):
                    target = "../bin/linker64"
                add_link(dest, target)
            else:
                add_file(dest, 0o100755, path.read_bytes())
    cpio = cpio_newc(entries)
    return gzip.compress(cpio, mtime=0)


def cmdline_fields(text: str):
    raw = text.encode()
    if b"\0" in raw:
        raise SystemExit("cmdline contains NUL")
    if len(raw) > 512 + 1024 - 1:
        raise SystemExit(f"cmdline is {len(raw)} bytes")
    blob = raw + b"\0"
    cmdline = blob[:512].ljust(512, b"\0")
    extra = blob[512:512 + 1024].ljust(1024, b"\0")
    return cmdline, extra


def pack(args) -> None:
    kernel = Path(args.kernel).read_bytes()
    dtbo = Path(args.dtbo).read_bytes()
    if kernel.startswith(b"ANDROID!"):
        raise SystemExit(f"{args.kernel} is a boot image, not a raw kernel")
    if not kernel:
        raise SystemExit("kernel is empty")
    if not dtbo:
        raise SystemExit("dtbo is empty")
    ramdisk = build_ramdisk(args)
    kernel_pages = pages(len(kernel))
    ramdisk_pages = pages(len(ramdisk))
    dtbo_offset = PAGE * (1 + kernel_pages + ramdisk_pages)
    digest = hashlib.sha1()
    for blob, size in ((kernel, len(kernel)), (ramdisk, len(ramdisk)), (b"", 0), (dtbo, len(dtbo))):
        digest.update(blob)
        digest.update(struct.pack("<I", size))
    ident = digest.digest().ljust(32, b"\0")
    cmdline, extra = cmdline_fields(CMDLINE)
    name = b"skyward-pchm30".ljust(16, b"\0")
    header = struct.pack(
        "<8s10I",
        b"ANDROID!",
        len(kernel),
        KERNEL_ADDR,
        len(ramdisk),
        RAMDISK_ADDR,
        0,
        SECOND_ADDR,
        TAGS_ADDR,
        PAGE,
        1,
        OS_VERSION,
    )
    header += name + cmdline + ident + extra
    header += struct.pack("<IQI", len(dtbo), dtbo_offset, HEADER_BYTES)
    if len(header) != HEADER_BYTES:
        raise SystemExit(f"header is {len(header)} bytes, want {HEADER_BYTES}")
    image = page_pad(header) + page_pad(kernel) + page_pad(ramdisk) + dtbo
    if dtbo_offset != PAGE + pages(len(kernel)) * PAGE + pages(len(ramdisk)) * PAGE:
        raise SystemExit("dtbo offset drifted")
    if image[dtbo_offset : dtbo_offset + len(dtbo)] != dtbo:
        raise SystemExit("dtbo was not written at recovery_dtbo_offset")
    if len(image) > PARTITION:
        raise SystemExit(
            f"recovery image is {len(image)} bytes and the partition is {PARTITION} bytes"
        )
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(image)
    print(
        f"wrote {out} header v1 kernel {len(kernel)} ramdisk {len(ramdisk)} "
        f"dtbo {len(dtbo)} total {len(image)} of {PARTITION}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--dtbo", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--system-init", required=True)
    parser.add_argument("--init", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--font", required=True)
    parser.add_argument("--mono", required=True)
    parser.add_argument("--mono-license", required=True)
    parser.add_argument("--task-profiles")
    parser.add_argument("--libs")
    parser.add_argument("--out", required=True)
    pack(parser.parse_args())


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
