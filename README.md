# TWRP Device Tree for OPPO A11x (PCHM30 / CPH1937)

基于原厂 9008 固件底层提取并构建的 **OPPO A11x** (全网通版 PCHM30 / 海外版 CPH1937 / OPPO A9 2020) 官方级 TWRP Recovery 设备树。

---

## 📱 设备基本参数 (Device Specifications)

| 项目 (Item) | 参数 (Specification) |
| :--- | :--- |
| **设备型号 (Model)** | OPPO A11x (PCHM30) / OPPO A9 2020 (CPH1937) |
| **主板代号 (Codename)** | `PCHM30` (工程代号 `Brandon` / `19375` / `19376`) |
| **处理器 (SoC)** | Qualcomm Snapdragon 665 (`SM6125` / `trinket`) |
| **架构 (Architecture)** | 64-bit ARMv8-A (4x 2.0 GHz Kryo 260 Gold + 4x 1.8 GHz Kryo 260 Silver) |
| **图形处理器 (GPU)** | Qualcomm Adreno 610 |
| **原厂底包系统** | ColorOS 7.1 / ColorOS 11 (Android 11, SDK 30) |
| **屏幕分辨率** | 720 x 1600 像素 (20:9 水滴屏, 320 DPI) |
| **电池容量** | 5000 mAh (典型值) |
| **主摄配置** | 4800 万像素主摄 + 800 万超广角 + 200 万 + 200 万 |

---

## 🛠 分区映射表 (Partition Layout)

根据 9008 原厂全分区提取，本项目采用**经典高通独立分区架构**（非虚拟动态 super 分区）：

| 分区名 (Partition) | 块设备节点 (Block Device) | 文件系统 (FS) | 说明 (Description) |
| :--- | :--- | :--- | :--- |
| **boot** | `/dev/block/bootdevice/by-name/boot` | emmc | 内核与启动引导 (96 MB) |
| **recovery** | `/dev/block/bootdevice/by-name/recovery` | emmc | Recovery 分区 (64 MB) |
| **dtbo** | `/dev/block/bootdevice/by-name/dtbo` | emmc | 设备树叠加层 (24 MB) |
| **vbmeta** | `/dev/block/bootdevice/by-name/vbmeta` | emmc | AVB 签名验证分区 |
| **system** | `/dev/block/by-name/system` | ext4 | 系统只读分区 (5.4 GB) |
| **vendor** | `/dev/block/by-name/vendor` | ext4 | 厂商驱动与 HAL 层 (1.6 GB) |
| **odm** | `/dev/block/by-name/odm` | ext4 | 运营商/定制驱动层 (268 MB) |
| **cache** | `/dev/block/bootdevice/by-name/cache` | ext4 | 缓存分区 |
| **userdata** | `/dev/block/bootdevice/by-name/userdata` | ext4 / f2fs | 用户数据 (支持 ICE 加密) |
| **persist** | `/dev/block/bootdevice/by-name/persist` | ext4 | 校准与传感器校准数据 |
| **opporeserve2** | `/dev/block/bootdevice/by-name/opporeserve2`| ext4 | OPPO 原厂保留参数分区 |

---

## 🚀 如何在 Linux 环境下编译 TWRP

### 1. 初始化编译环境与同步源码
推荐使用 Ubuntu 20.04 LTS 或 22.04 LTS 环境：

```bash
# 安装基础编译依赖
sudo apt update
sudo apt install git-core gnupg flex bison build-essential zip curl zlib1g-dev \
gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev \
libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig

# 同步 OmniROM TWRP-11 源码树 (推荐)
mkdir twrp-11 && cd twrp-11
repo init --depth=1 -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_omni.git -b twrp-11
repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
```

### 2. 克隆本设备树
将本项目克隆到源码目录的 `device/oppo/PCHM30`：

```bash
git clone https://github.com/<your-username>/android_device_oppo_PCHM30.git device/oppo/PCHM30
```

### 3. 开始编译
```bash
# 初始化环境
source build/envsetup.sh

# 选择目标编译机型
lunch omni_PCHM30-userdebug

# 编译 recovery.img
mka recoveryimage -j$(nproc --all)
```
编译成功后，产物位于 `out/target/product/PCHM30/recovery.img`。

---

## ⚡ 刷入与启动方法 (Flashing Instructions)

手机需提前解开 **Bootloader 锁** 并进入 Fastboot 模式：

```bash
# 刷入 recovery 分区
fastboot flash recovery recovery.img

# (可选) 同时禁用 avb 校验以防卡开机
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

# 启动至 Recovery 界面
fastboot reboot recovery
```

---

## 📤 如何将此仓库推送到你的 GitHub

如果你想将本地这套设备树发布到你自己的 GitHub 主页，请执行以下命令：

1. 在 [GitHub](https://github.com/new) 上新建一个名为 `android_device_oppo_PCHM30` 的公开仓库（**不要勾选** "Initialize with README"）。
2. 在本地执行以下命令推送：

```bash
# 进入当前设备树根目录
cd E:\Rannki\android_device_oppo_PCHM30

# 添加你的 GitHub 远程地址 (替换成你的 GitHub 用户名)
git remote add origin https://github.com/<你的GitHub用户名>/android_device_oppo_PCHM30.git

# 确保分支为主分支 main
git branch -M main

# 推送到 GitHub
git push -u origin main
```

---

## 📄 版权与许可证 (License)
本项目基于 Apache 2.0 许可证开源。底层二进制内核与固件属性版权归属 OPPO 与 Qualcomm 官方所有。
