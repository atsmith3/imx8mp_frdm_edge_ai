# i.MX8MP Freedom Board Bringup Guide

This guide walks you through a complete hardware and software bringup from zero: building a Yocto Linux image with machine learning tooling, flashing it to the i.MX8MP Freedom board, verifying NPU acceleration with TFLite, and enabling local SLM inference with a Kinara Ara240 PCIe accelerator. The workflow is linear — follow each section in order.

**Intended audience:** Embedded Linux engineers.  
**Estimated time:** 8-16 hours (most spent on the Yocto build).

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Build the Yocto Image](#2-build-the-yocto-image)
3. [Flash the SD Card](#3-flash-the-sd-card)
4. [First Boot and Network Setup](#4-first-boot-and-network-setup)
5. [Verify TFLite NPU Acceleration](#5-verify-tflite-npu-acceleration)
6. [Install the Kinara Ara240 SDK](#6-install-the-kinara-ara240-sdk)
7. [Download Models and Run Inference](#7-download-models-and-run-inference)
8. [Troubleshooting](#8-troubleshooting)
9. [References](#9-references)

---

## 1. Prerequisites

### 1.1 Host Machine Requirements

To build the Yocto image efficiently:

- **RAM:** 16 GB minimum (32 GB recommended for parallel builds at higher thread counts)
- **CPU:** 8 cores or more
- **Disk space:** 200 GB minimum free space (the build tree plus sstate cache can exceed this)
- **Docker Engine:** Latest version installed and running
- **Architecture:** x86-64 (the Docker-based build isolates host OS dependencies, so no specific Linux distro is required)

### 1.2 Hardware Required

- i.MX8MP Freedom board (imx8mpfrdm) with LPDDR4 memory
- SD card (minimum 16 GB, Class 10 or faster recommended)
- USB-to-serial adapter (3.3V UART, 115200 baud) for U-Boot console access
- Host machine with SD card writer
- Kinara Ara240 PCIe accelerator module (M.2 form factor or wired to PCIe)

### 1.3 Software and Accounts

**Hugging Face account and token:**  
Model weights are gated on Hugging Face and require authentication. Create a free account at [huggingface.co](https://huggingface.co), navigate to **Settings > Access Tokens**, and generate a read-scoped token. You will export this later as `HF_TOKEN` during model downloads.

**Kinara Ara240 SDK .deb packages:**  
Download the following packages from the [Kinara SDK page](https://www.nxp.com/design/design-center/software/embedded-software/ara-software-development-kit:ARA-SDK):
- `rt-sdk-ara2_2.0.4.deb` (required base SDK)
- `eiq-aaf-connector_2.0.deb` (optional, enables REST API)
- `llm-edge-studio_2.0.0.deb` (optional, GUI for LLM inference)
- `vlm-edge-studio_1.0.0.deb` (optional, Vision-Language Model studio)
- `ara2-vision-examples_1.0.deb` (optional, YOLOv8 examples)

These packages are also mirrored on the [NXP i.MX SW downloads page](https://www.nxp.com).

**Host tools:**  
Install `bmaptool` on your host for fast, verified SD card flashing:
```bash
sudo apt-get install bmap-tools
```

### 1.4 Conventions Used in This Guide

- **Commands prefixed with `$`:** Run on the host machine.
- **Commands prefixed with `#`:** Run as root on the target board (after SSH or serial console).
- **No prefix in fenced blocks:** Config file excerpts or U-Boot commands.
- **`<value>`:** Substitute with your specific value (e.g., `<board-ip>`, `/dev/sdX`).

---

## 2. Build the Yocto Image

**Goal:** Build a complete `imx-image-full` Yocto image inside a reproducible Docker container with NXP BSP support and TFLite/ONNX ML tooling included.

### 2.1 Build the Docker Container

The Docker container isolates all Yocto host dependencies on any Linux system. The build requires a non-root user (`builder`) because Yocto refuses to run as root.

Create a `Dockerfile` in your build workspace:

```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Basic packages  
RUN apt-get update && apt-get install -y \
    locales \       
    sudo \        
    tzdata \       
    git \   
    curl \ 
    wget \
    python3 \
    python3-distutils \
    python3-venv \
    python3-pip \               
    gawk \
    diffstat \                    
    unzip \
    texinfo \ 
    gcc \
    g++ \           
    build-essential \ 
    chrpath \
    socat \        
    cpio \                      
    python3-pexpect \                       
    xz-utils \                   
    debianutils \
    iputils-ping \ 
    python3-git \                     
    python3-jinja2 \ 
    libegl1-mesa \
    libsdl1.2-dev \
    pylint \    
    xterm \     
    file \
    rsync \
    git-lfs \
    bc \
    vim \
    lz4 liblz4-dev liblz4-tool \
    zstd \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install repo tool
RUN mkdir -p /usr/local/bin && \
    curl https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && \
    chmod a+x /usr/local/bin/repo

# Create a non-root user (Yocto dislikes root builds)
RUN useradd -ms /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER builder
WORKDIR /workdir
```

Build the Docker image:

```bash
$ docker build -t yocto-ubuntu22 .
```

### 2.2 Initialize the NXP BSP Manifest

Create the build workspace on your host:

```bash
$ mkdir -p yocto/imx8mp_frdm_lpddr4/linux-6.18.2_1.0.0 && cd yocto/imx8mp_frdm_lpddr4/linux-6.18.2_1.0.0
```

Start the Docker container with bind-mounted workspace and SSH keys (needed for `repo sync` over SSH):

```bash
$ docker run --rm -it -v $PWD:/workdir:z -v $HOME/.ssh:/home/builder/.ssh:z --network=host yocto-ubuntu22 /bin/bash
```

Inside the container, fetch the NXP i.MX BSP manifest:

```bash
$ repo init -u https://github.com/nxp-imx/imx-manifest -b imx-linux-whinlatter -m imx-6.18.2-1.0.0.xml
$ repo sync
```

This downloads roughly 8–10 GB of NXP kernel sources and recipe layers. Expected time: 10–30 minutes depending on network.

### 2.3 Configure the Build Environment

Set the machine and distro variables, then initialize the build directory:

```bash
$ export MACHINE=imx8mp-lpddr4-frdm
$ export DISTRO=fsl-imx-xwayland
$ source imx-setup-release.sh -b core-image-base-ml
$ cd ..
```

This creates a `build-ml/` directory with Bitbake configuration.

### 2.4 Edit local.conf

The postinst configuration file determines which packages are built and included. Edit `build-ml/conf/local.conf` to add ML essentials, SSH, networking, and development tools. Append the following to the existing file (do not replace it):

```ini
# Switch to Debian packaging (required for Ara240 SDK compatibility)
PACKAGE_CLASSES = "package_deb"
EXTRA_IMAGE_FEATURES += "package-management"

# Include essential packages for ML inference and board administration
IMAGE_INSTALL:append = " \
    bash bash-completion bzip2 ca-certificates cmake coreutils \
    curl dhcpcd e2fsprogs-resize2fs ethtool file findutils \
    fwupd g++ gcc gdb git glibc gzip htop imx-gpu-g2d \
    iproute2 iputils iw iwd kmod ldconfig less \
    libatomic libgcc libopencl-imx libstdc++ linux-firmware \
    logrotate lsof make nano net-tools networkmanager \
    networkmanager-nmcli onnxruntime openssh \
    openssh-sftp-server openssh-sshd packagegroup-imx-ml \
    parted pciutils perf procps python3 python3-numpy \
    python3-pip python3-setuptools python3-venv quota rsync \
    shadow strace sudo systemd-analyze tar tcpdump tmux tzdata \ 
    udev unzip usbutils util-linux vim wget which wpa-supplicant \
    xz zip zlib \
    libxcb libx11 libxext libxrender libxfixes libxrandr libxtst \
"

# Include TFLite and ONNX runtime developer libraries
TOOLCHAIN_TARGET_TASK:append = " tensorflow-lite-dev onnxruntime-dev"

# Enable WiFi and Bluetooth, systemd, IP v4/v6 networking
MACHINE_FEATURES:append = " wifi bluetooth"
DISTRO_FEATURES:append = " wifi systemd ipv4 ipv6"
VIRTUAL-RUNTIME_network_manager = "networkmanager"
VIRTUAL-RUNTIME_network_manager_wifi = "networkmanager"
VIRTUAL-RUNTIME_init_manager = "systemd"

# Remove unnecessary firmware
IMAGE_INSTALL:remove = "linux-firmware-nxp8997-common"
IMAGE_INSTALL:remove = "packagegroup-core-tools-testapps"
PACKAGE_EXCLUDE += " linux-firmware-nxp8997-common"
PACKAGE_EXCLUDE += " packagegroup-core-tools-testapps"

# Parallelism: 4 threads is conservative; raise to 8 or 16 if your CPU has more cores
BB_NUMBER_THREADS = "4"
PARALLEL_MAKE = "-j 8"

# Save disk space by removing work directories after each recipe completes
INHERIT += "rm_work"
```

### 2.5 Run the Build

Start the build inside the Docker container (make sure you are in the workspace root, not `build-ml/`):

```bash
$ bitbake imx-image-full
```

**Expected duration:** 8-16 hours on a modern workstation at 8 threads. Monitor progress with:

```bash
$ tail -f build-ml/tmp/log.do_build
```

On successful completion, the built image appears at:
```
build-ml/tmp/deploy/images/imx8mp-lpddr4-frdm/imx-image-full-imx8mp-lpddr4-frdm.rootfs.wic.zst
```

If the build is interrupted, rerun `bitbake imx-image-full` — it will resume from the last successful step.

---

## 3. Flash the SD Card

**Goal:** Write the built image to an SD card using bmaptool for fast, verified flashing.

### 3.1 Identify the SD Card Device

Insert the SD card into your host machine and run `lsblk` to identify its device node:

```bash
$ lsblk
```

Look for an entry with a size around 58–64 GB (depending on your card). For example:

```
NAME                      MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
...
sdc                         8:32   1    58G  0 disk
...
```

**Warning:** Double-check the device name. Flashing to the wrong device will destroy data.

### 3.2 Flash with bmaptool

Copy the image from the Docker workspace to your host (exit the container first), then flash:

```bash
$ sudo bmaptool copy ./imx-image-full-imx8mp-lpddr4-frdm.rootfs.wic.zst /dev/sdX
```

Replace `/dev/sdX` with the device identified above (e.g., `/dev/sdc`).

bmaptool uses the `.bmap` sidecar file (shipped with the image) to skip empty blocks, making flashing 5–10× faster than `dd`. Expected duration: 2–5 minutes.

---

## 4. First Boot and Network Setup

**Goal:** Bring the board up, establish a serial console session, configure networking, and verify SSH access before installing additional software.

### 4.1 Connect the Serial Console

Connect a USB-to-serial adapter to the board's UART pins (refer to the board's Quick Reference Guide for pin locations). On your host, open a terminal emulator at 115200 8N1:

```bash
$ picocom -b 115200 /dev/ttyUSB0
```

Alternatively, use `minicom` or `screen`:

```bash
$ minicom -b 115200 -D /dev/ttyUSB0
$ screen /dev/ttyUSB0 115200
```

Power on the board. The U-Boot prompt should appear within 2–3 seconds:

```
U-Boot 2023.04-imx_v2023.04 ...
```

### 4.2 U-Boot Boot Arguments

By default, the board boots automatically with stored boot arguments. You only need to edit boot arguments if you are performing a firmware upgrade (see Section 6.7). To manually override boot arguments:

1. Interrupt the automatic boot by pressing a key when prompted.
2. At the U-Boot prompt, edit the boot arguments:

```
u-boot> editenv mmcargs
edit: setenv bootargs ${jh_clk} ${mcore_clk} console=${console} root=${mmcroot} pcie_aspm=off
u-boot> saveenv
u-boot> boot
```

(The `pcie_aspm=off` flag is only needed during firmware upgrade. For normal boot, you can omit it.)

### 4.3 Configure Networking with NetworkManager

After Linux boots, log in as root (default password may be empty; set one with `passwd` if prompted). NetworkManager is pre-installed. Connect to the network using `nmcli`:

For wired Ethernet:

```bash
# root@board:~# nmcli device connect eth0
```


Verify the connection:

```bash
# root@board:~# ip addr show
```

Note the board's IP address (e.g., `192.168.1.100`).

### 4.4 Verify SSH Access

From your host machine, SSH into the board:

```bash
$ ssh root@<board-ip>
```

You should land in the root shell. If SSH is not working, verify NetworkManager is running:

```bash
# root@board:~# systemctl status NetworkManager
```

### 4.5 Resize the Root Partition

The Yocto image is sized to fit the minimal root content, not the full SD card. Resize it to use all available space on the board:

```bash
# root@board:~# parted /dev/mmcblk1 resizepart 2 100%
# root@board:~# resize2fs /dev/mmcblk1p2
```

Verify with `df -h`:

```bash
# root@board:~# df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/mmcblk1p2   58G  2.5G   55G   5% /
```

---

## 5. Verify TFLite NPU Acceleration

**Goal:** Confirm that the i.MX8MP NPU is accessible and that TFLite can dispatch inference to it, before adding the external Ara240 accelerator.

### 5.1 Check NPU Device Node

Verify the NPU device is enumerated and the kernel driver is loaded:

```bash
# root@board:~# ls -la /dev/galcore
crw-rw---- 1 root input 248,   0 Apr 17 12:34 /dev/galcore
```

The NPU driver (`galcore`) is a character device provided by the VeriSilicon Vivante GPU stack. If the device does not exist, the NPU driver may not have loaded — check `dmesg`:

```bash
# root@board:~# dmesg | grep -i vivante
```

### 5.2 Run a TFLite Benchmark

Run the TFLite benchmark tool (included via `packagegroup-imx-ml` in the Yocto build) with the NPU delegate:

```bash
# root@board:~# tensorflow_lite_benchmark --graph=/path/to/model.tflite --use_nnapi=true
```

If you do not have a model file on the board yet, download a small test model:

```bash
# root@board:~# wget https://tfhub.dev/google/lite-model/mobilenet_v2_100_224/1/default/1 -O mobilenet_v2.tflite
# root@board:~# tensorflow_lite_benchmark --graph=mobilenet_v2.tflite --use_nnapi=true
```

Expected output: non-zero inference throughput (inferences/sec) with the delegate active. If throughput is very low or the delegate fails to load, the NPU is not correctly enumerated.

---

## 6. Install the Kinara Ara240 SDK

**Goal:** Install the Ara240 runtime SDK, patch the systemd service for correct startup ordering, and verify the PCIe accelerator is healthy.

### 6.1 Download the SDK Packages

The Kinara Ara240 SDK .deb packages are not distributed with this repository. Download them from the [Kinara SDK page](https://www.nxp.com/design/design-center/software/embedded-software/ara-software-development-kit:ARA-SDK) or the [NXP i.MX SW downloads page](https://www.nxp.com).

Transfer the packages to the board via `scp`:

```bash
$ scp rt-sdk-ara2_2.0.4.deb root@<board-ip>:~/
$ scp eiq-aaf-connector_2.0.deb root@<board-ip>:~/
$ scp llm-edge-studio_2.0.0.deb root@<board-ip>:~/
$ scp vlm-edge-studio_1.0.0.deb root@<board-ip>:~/
$ scp ara2-vision-examples_1.0.deb root@<board-ip>:~/
```

Or, if you placed the `.deb` files on the SD card before flashing, they will be present in the root home directory after boot.

### 6.2 Set HF_HUB_DISABLE_XET Environment Variable

The optional package postinst scripts pull large models from Hugging Face. The xet transport must be disabled or it will saturate the network interface for the entire system. Set this environment variable in three places for persistence and systemd compatibility.

On the board, edit `/etc/environment` to persist across reboots:

```bash
# root@board:~# echo 'HF_HUB_DISABLE_XET=1' >> /etc/environment
```

Create the service environment file for systemd:

```bash
# root@board:~# mkdir -p /run/ara240
# root@board:~# echo 'HF_HUB_DISABLE_XET=1' > /run/ara240/env
```

Export into the current shell:

```bash
# root@board:~# export HF_HUB_DISABLE_XET=1
```

### 6.3 Install the Runtime SDK

Install the base Kinara SDK. This is required; the optional packages depend on it:

```bash
# root@board:~# cd ~
# root@board:~# dpkg -i rt-sdk-ara2_2.0.4.deb
# root@board:~# ldconfig
```

The postinst script automatically:
- Resizes `/dev/mmcblk1p2` to fill available space (if not already done in Section 4.5)
- Creates a 5 GB swap file at `/swapfile`
- Creates `/usr/share/cnn` and `/usr/share/llm` model directories
- Installs the `uv` Python package manager
- Enables the `rt-sdk-ara2.service` systemd unit

### 6.4 Patch the Systemd Service Unit

The shipped service unit has `After=multi-user.target`, which creates a dependency loop and causes the service to fail at boot. Patch this **before** starting the service:

```bash
# root@board:~# cat > /etc/systemd/system/rt-sdk-ara2.service << 'EOF'
[Unit]
Description=Run rt-sdk-ara2 script at boot
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/share/rt-sdk-ara240/scripts/rt-sdk-ara2_pre.sh
ExecStart=/bin/bash /usr/share/rt-sdk-ara240/scripts/rt-sdk-ara2_script.sh
ExecStartPost=/bin/bash /usr/share/rt-sdk-ara240/scripts/rt-sdk-ara2_post.sh
EnvironmentFile=-/run/ara240/env
KillMode=control-group
RemainAfterExit=true

StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
```

Reload the systemd daemon:

```bash
# root@board:~# systemctl daemon-reload
```

### 6.5 Start and Verify the Service

The service was already enabled by the postinst script; start it now:

```bash
# root@board:~# systemctl start rt-sdk-ara2
# root@board:~# systemctl status rt-sdk-ara2
```

Expected output:

```
● rt-sdk-ara2.service - Run rt-sdk-ara2 script at boot
     Loaded: loaded (/etc/systemd/system/rt-sdk-ara2.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-04-17 15:30:42 UTC; 5s ago
...
Hardware bringup is done (1 device(s) configured) and proxy is launched successfully in the background.
```

### 6.6 Verify PCIe and Chip Health

Check PCIe enumeration:

```bash
# root@board:~# lspci | grep -i kinara
01:00.0 Unclassified device [1e58:0002]: Kinara Inc. ARA2 (rev 02)
```

Run the Kinara diagnostic tools:

```bash
# root@board:~# chip_info.sh
# root@board:~# ara2_metrics.sh
# root@board:~# lspci -vv -s 01:00.0 | grep -E "driver|LnkSta"
```

Expected output for `chip_info.sh`:

```
Ara2 A01
PCIe
Firmware version: 2.0.0
...
```

> **Important:** The firmware version must be **`2.0.0` or higher**. If it shows `1.1.2` or earlier, proceed to Section 6.7 for a firmware upgrade.

### 6.7 Firmware Upgrade (Required if chip firmware < 2.0.0)

**This step is only required if `chip_info.sh` shows firmware version below `2.0.0`.**

Older firmware (v1.1.2 and earlier) have a known issue where hard system crashes occur during inference on marginal PCIe links (see Section 8.1). Firmware v2.0.0 resolves this.

**Step 1:** Reboot the board and enter U-Boot by pressing a key at the U-Boot prompt:

```bash
# root@board:~# reboot
```

**Step 2:** In U-Boot, add the `pcie_aspm=off` boot argument to prevent PCIe link power state transitions during firmware programming (which can cause instability):

```
u-boot> editenv mmcargs
edit: setenv bootargs ${jh_clk} ${mcore_clk} console=${console} root=${mmcroot} pcie_aspm=off
u-boot> saveenv
u-boot> boot
```

**Step 3:** After Linux boots, stop the connector service and run the firmware upgrade script:

```bash
# root@board:~# systemctl stop eiq-aaf-connector
# root@board:~# program_flash.sh
```

The script will download and flash the latest firmware (v2.0.0) to the Ara240 chip. Ensure the board has network connectivity during this step. Expected duration: 3–5 minutes.

**Step 4:** Reboot and verify the firmware upgraded successfully:

```bash
# root@board:~# reboot
```

After reboot, verify:

```bash
# root@board:~# chip_info.sh | grep -i firmware
Firmware version: 2.0.0
```

### 6.8 Install Optional SDK Packages

If you are installing the GUI tools (`llm-edge-studio`, `vlm-edge-studio`) or example code (`ara2-vision-examples`), ensure `HF_HUB_DISABLE_XET=1` is still exported (Section 6.2). Then install all optional packages in one call:

```bash
# root@board:~# dpkg -i eiq-aaf-connector_2.0.deb \
                        llm-edge-studio_2.0.0.deb \
                        vlm-edge-studio_1.0.0.deb \
                        ara2-vision-examples_1.0.deb
```

These packages pull large model files (GBs) from Hugging Face during postinstall. This can take 10–30 minutes on a typical home Internet connection.

> **Note:** Usage documentation for `vlm-edge-studio` and `ara2-vision-examples` is maintained by Kinara. Refer to the [Kinara SDK documentation portal](https://www.nxp.com/design/design-center/software/embedded-software/ara-software-development-kit:ARA-SDK) for detailed usage guides.

---

## 7. Download Models and Run Inference

**Goal:** Obtain a quantized SLM, load it onto the Ara240 accelerator, and execute a test inference to confirm end-to-end acceleration.

### 7.1 Obtain a Hugging Face Access Token

Model weights are gated on Hugging Face and require authentication. Create a free account at [huggingface.co](https://huggingface.co), navigate to **Settings > Access Tokens**, and generate a read-scoped token. The token looks like `hf_xxxxxxxxxxxxxxxxxxxx`.

On the board, export the token in the current shell:

```bash
# root@board:~# export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

To persist it across sessions, append it to `/etc/environment`:

```bash
# root@board:~# echo 'HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx' >> /etc/environment
```

(Replace `hf_xxxxxxxxxxxxxxxxxxxx` with your actual token.)

### 7.2 Fetch Models with uvx

The Kinara SDK includes `uvx`, a model fetch utility. Download Hugging Face models gated for NXP/Ara240:

```bash
# root@board:~# uvx --from /usr/share/python-wheels/fetch_models-1.0.0-py3-none-any.whl \
                        fetch_models --repo-id nxp/Qwen2.5-7B-Instruct-Ara240
```

Models are downloaded to `/usr/share/llm/` and are roughly 3.5–7 GB uncompressed. On a 10 Mbps connection, expect 30–60 minutes per model. You can fetch multiple models:

```bash
# root@board:~# uvx --from /usr/share/python-wheels/fetch_models-1.0.0-py3-none-any.whl \
                        fetch_models --repo-id nxp/Qwen2.5-Coder-1.5B-Ara240
```

Verify the models are in place:

```bash
# root@board:~# ls /usr/share/llm/
```

### 7.3 Run Inference

If you installed `eiq-aaf-connector` (Section 6.8), the REST API endpoint is already running. Query the loaded models:

```bash
# root@board:~# curl http://localhost:8000/v1/models
```

Send a test inference request:

```bash
# root@board:~# curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen2.5-7B-Instruct-Ara240",
    "messages": [{"role": "user", "content": "Hello, what is your name?"}],
    "max_tokens": 100
  }'
```

Expected output: a JSON response with token-by-token completions from the model running on the Ara240 accelerator.

Monitor accelerator utilization during inference:

```bash
# root@board:~# ara2_metrics.sh
```

This shows DMA bandwidth, memory usage, and processing latency during the inference run.

### 7.4 Change the Default Model

By default, `eiq-aaf-connector` loads a default model on startup. To change which model is loaded by default, edit the connector configuration file:

```bash
# root@board:~# nano /usr/share/eiq/aaf-connector/server_config.json
```

Look for the `default_model` field and update it to point to your desired model:

```json
{
  "default_model": "Qwen2.5-Coder-1.5B-Ara240",
  ...
}
```

Save the file and restart the connector service:

```bash
# root@board:~# systemctl restart eiq-aaf-connector
```

Verify the new default model is loaded:

```bash
# root@board:~# curl http://localhost:8000/v1/models
```

The response should now show your selected model in the default position.

---

## 8. Troubleshooting

### 8.1 Hard System Hang During Inference (PCIe Link Degradation)

**Symptom:** The system hard-crashes (complete, unrecoverable hang) when an inference request is sent to the REST API. No serial console output appears; recovery requires a physical power cycle.

**Root cause:** Older Ara240 firmware (v1.1.2 and earlier) has a bug where a marginal PCIe link (operating at 2.5 GT/s ×1, downgraded from expected speed) fails under the DMA load generated during neural inference, causing a kernel panic or machine check error that halts the CPU before the UART can flush output.

**Diagnosis:**

Check the firmware version:

```bash
# root@board:~# chip_info.sh | grep -i firmware
```

Check the PCIe link status:

```bash
# root@board:~# lspci -vv -s 01:00.0 | grep -i "linksta\|speed\|width"
```

**Resolution:** Upgrade the Ara240 firmware to v2.0.0 as documented in Section 6.7. The firmware upgrade resolves the DMA stability issue. The `pcie_aspm=off` boot argument during the firmware upgrade prevents ASPM from downgrading the link during programming, which can cause instability.

---

### 8.2 rt-sdk-ara2.service Fails to Start

**Symptom:** After rebooting or starting the service manually, systemd reports the service as failed:

```
● rt-sdk-ara2.service - Run rt-sdk-ara2 script at boot
     Loaded: loaded (/etc/systemd/system/rt-sdk-ara2.service; enabled; vendor preset: enabled)
     Active: failed (Result: exit-code) since Thu 2026-04-17 15:30:42 UTC; 5s ago
```

**Diagnosis:** Check the service logs:

```bash
# root@board:~# journalctl -u rt-sdk-ara2.service --no-pager
```

Common causes:
1. **EnvironmentFile missing or wrong path:** The systemd service unit patch (Section 6.4) sets `EnvironmentFile=-/run/ara240/env`. Verify this file exists and contains `HF_HUB_DISABLE_XET=1`.
2. **Network not yet up at service start time:** Systemd may try to start the service before the network is ready. Check `systemctl status NetworkManager` and verify the service unit has `After=network.target`.
3. **`HF_HUB_DISABLE_XET` not set:** If the optional packages (GUI tools) are installed but `HF_HUB_DISABLE_XET` is not set, the postinst scripts may fail during model downloads and leave the service in a bad state.

**Resolution:**
1. Verify the service unit patch was applied correctly (Section 6.4).
2. Verify `/run/ara240/env` exists and contains `HF_HUB_DISABLE_XET=1`.
3. Manually restart the service:

```bash
# root@board:~# systemctl daemon-reload
# root@board:~# systemctl restart rt-sdk-ara2
# root@board:~# systemctl status rt-sdk-ara2
```

---

### 8.3 Ara240 Not Visible on PCIe Bus

**Symptom:** `lspci | grep -i kinara` returns nothing, or the Ara240 is listed but the driver is not loaded.

**Diagnosis:**

Check PCIe enumeration:

```bash
# root@board:~# lspci -v
# root@board:~# dmesg | grep -i pcie
# root@board:~# dmesg | grep -i uiodma
```

Check for PCIe enumeration errors or driver load failures.

**Resolution:**
1. Verify the Ara240 module is physically seated correctly in the M.2 slot.
2. If you recently upgraded the firmware (Section 6.7), verify the `pcie_aspm=off` boot argument is **removed** from the normal boot (it should only be present during the firmware upgrade). Reboot without it:

```
u-boot> editenv mmcargs
edit: setenv bootargs ${jh_clk} ${mcore_clk} console=${console} root=${mmcroot}
u-boot> saveenv
u-boot> boot
```

3. Check the board's BIOS/U-Boot for PCIe slot configuration. Ensure the slot is enabled in U-Boot settings.

---

### 8.4 Model Download Fails with Authentication Error

**Symptom:** `uvx fetch_models` exits with HTTP 401 (Unauthorized) or "repository not found."

**Diagnosis:**

```bash
# root@board:~# echo $HF_TOKEN
# root@board:~# uvx fetch_models --repo-id nxp/Qwen2.5-7B-Instruct-Ara240
```

**Resolution:**
1. Confirm `HF_TOKEN` is exported in the current shell: `echo $HF_TOKEN` should print your token.
2. Confirm the token is valid and has **read** scope. Log into [huggingface.co](https://huggingface.co), navigate to **Settings > Access Tokens**, and verify the token exists and is not expired.
3. Some NXP-gated model repositories may require additional approval on the Hugging Face website. Navigate to the model repository (e.g., `https://huggingface.co/nxp/Qwen2.5-7B-Instruct-Ara240`) and click **Agree and access repository** if prompted.
4. Ensure the model repository name is spelled correctly. NXP Ara240-optimized models follow the naming pattern `nxp/Qwen2.5-*-Ara240`.

---

## 9. References

### 9.1 NXP Documentation

| Resource | Link |
|----------|------|
| i.MX8MP FRDM Product Page | https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX8MPLUS |
| i.MX8MP Quick Reference Guide | https://www.nxp.com/docs/en/quick-reference-guide/FRDMIMX8MPLUSQSG.pdf |
| i.MX Linux User's Guide | https://www.nxp.com/docs/en/user-guide/UG10163.pdf |
| i.MX Machine Learning User's Guide | https://www.nxp.com/docs/en/user-guide/UG10166.pdf |
| i.MX Yocto Project User's Guide | https://www.nxp.com/docs/en/user-guide/UG10164.pdf |
| NXP i.MX SW Downloads | https://www.nxp.com |

### 9.2 Kinara Documentation

| Resource | Link |
|----------|------|
| Kinara Ara240 Product Page | https://www.nxp.com/products/ARA240 |
| Kinara SDK Portal | https://www.nxp.com/design/design-center/software/embedded-software/ara-software-development-kit:ARA-SDK |

Full usage documentation for `llm-edge-studio`, `vlm-edge-studio`, and `ara2-vision-examples` is maintained by Kinara on the SDK portal.

### 9.3 Upstream Tools and Resources

| Resource | Link |
|----------|------|
| Hugging Face Tokens | https://huggingface.co/settings/tokens |
| Hugging Face Hub Documentation | https://huggingface.co/docs/hub |
| bmaptool (Intel) | https://github.com/01org/bmap-tools |
| Yocto Project Documentation | https://www.yoctoproject.org/docs |
| NXP i.MX Manifest Repository | https://github.com/nxp-imx/imx-manifest |
| Google repo Tool | https://gerrit.googlesource.com/git-repo |

---

**End of guide.** For questions or issues, refer to the troubleshooting section or consult the NXP and Kinara documentation portals above.
