# Skyward on OPPO A11x (PCHM30)

Skyward ([kirklin/skyward](https://github.com/kirklin/skyward) `ff1668fdb72a46f22152a6540f49728c42081aba`, GPL-3.0-or-later) packed as a header v1 recovery image for this phone. The phone is not A/B and has no super partition. `non-ab.patch` mounts `system`, `vendor`, `odm`, `persist`, `cache`, `metadata`, and `modem` by GPT name. `init.c` is pid 1: it links `/dev/block/by-name`, then execs `/system/bin/recovery`.

GitHub Actions workflow `Skyward PCHM30` builds the image. The artifact is `skyward-pchm30` and contains `skyward-pchm30.img`. The image is not padded to 64 MiB and has no AVB footer. It must stay at or under 67108864 bytes.

Flash only after the bootloader is unlocked and vbmeta verification is off, the same requirement as this device tree's TWRP notes:

```
fastboot flash recovery skyward-pchm30.img
```

This image has not been booted on hardware. Userdata decryption is not included. WLAN is left out of the first image so a missing driver does not stop the UI.
