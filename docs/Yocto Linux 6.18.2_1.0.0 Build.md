## Requirements

### System

Here are the system requirements to be able to efficiently build the Yocto Linux `imx-image-full` build.

| Memory | 16BG +   |
| ------ | -------- |
| CPU    | 8 core + |
| Disk   | 200 GB + |

## Build

#### Host PC
``` Dockerfile
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

Build ubuntu docker image:
```
docker build -t yocto-ubuntu22 .
```

Setup build area on Ubuntu WSL:
``` bash
mkdir -p yocto/imx8mp_frdm_lpddr4/linux-6.18.2_1.0.0 && cd yocto/imx8mp_frdm_lpddr4/linux-6.18.2_1.0.0
```

Start docker container:
```
docker run --rm -it -v $PWD:/workdir:z -v $HOME/.ssh:/home/builder/.ssh:z yocto-ubuntu22 /bin/bash
```

Fetch the i.MX Linux BSP Manifest:
``` bash
repo init -u https://github.com/nxp-imx/imx-manifest \
	-b imx-linux-whinlatter -m imx-6.18.2-1.0.0.xml
repo sync
```

Create the minimal build area:
``` bash
export MACHINE=imx8mp-lpddr4-frdm
export DISTRO=fsl-imx-xwayland
source imx-setup-release.sh -b core-image-base-ml
cd ..
```

Edit the `build-ml/conf/local.conf` to add  ML essentials.
``` build-ml/conf/local.conf
DISTRO ?= 'fsl-imx-xwayland'
MACHINE ??= 'imx8mp-lpddr4-frdm'
USER_CLASSES ?= "buildstats"
PATCHRESOLVE = "noop"
BB_DISKMON_DIRS ??= "\
    STOPTASKS,${TMPDIR},1G,100K \
    STOPTASKS,${DL_DIR},1G,100K \
    STOPTASKS,${SSTATE_DIR},1G,100K \
    STOPTASKS,/tmp,100M,100K \
    HALT,${TMPDIR},100M,1K \
    HALT,${DL_DIR},100M,1K \
    HALT,${SSTATE_DIR},100M,1K \
    HALT,/tmp,10M,1K"
CONF_VERSION = "2"

DL_DIR ?= "${BSPDIR}/downloads/"
ACCEPT_FSL_EULA = "1"

# Switch to Debian packaging and include package-management in the image
PACKAGE_CLASSES = "package_deb"
EXTRA_IMAGE_FEATURES += "package-management"

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

TOOLCHAIN_TARGET_TASK:append = " tensorflow-lite-dev onnxruntime-dev"

MACHINE_FEATURES:append = " wifi bluetooth"

DISTRO_FEATURES:append = " wifi systemd ipv4 ipv6"
VIRTUAL-RUNTIME_network_manager = "networkmanager"
VIRTUAL-RUNTIME_network_manager_wifi = "networkmanager"
VIRTUAL-RUNTIME_init_manager = "systemd"

IMAGE_INSTALL:remove = "linux-firmware-nxp8997-common"
IMAGE_INSTALL:remove = "packagegroup-core-tools-testapps"
PACKAGE_EXCLUDE += " linux-firmware-nxp8997-common"
PACKAGE_EXCLUDE += " packagegroup-core-tools-testapps"

# BB_NUMBER_THREADS = "8"
BB_NUMBER_THREADS = "4"
#BB_NUMBER_THREADS = "16"
PARALLEL_MAKE = "-j 8"

INHERIT += "rm_work"
```

``` bash
bitbake imx-image-full
```
#### Format SD Card

On host system:
``` bash
sudo apt-get install bmap-tools
```

Use `lsblk` to identify SD Card; 64 GB capacity so look for 56 to 60GB disk size.
``` bash
lsblk
```

``` text
NAME                      MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
...
sdb                         8:16   1    58G  0 disk
...
```

Use `bmaptool` to format the system image to the SD Card.
``` bash
sudo bmaptool copy ./core-image-base-xwayland-ml/tmp/deploy/images/imx8mp-lpddr4-frdm/imx-image-full-imx8mp-lpddr4-frdm.rootfs.wic.zst /dev/sdc
```

Resize the filesystem to match the full sd card space:
``` bash
sudo parted /dev/mmcblk1 resizepart 2 100%
sudo resize2fs /dev/mmcblk1p2
```

Manual Boot Args override (U Boot)
``` uboot
setenv bootargs 'console=ttymxc1,115200 root=/dev/mmcblk1p2 rootwait rw'

fatload mmc 1:1 ${loadaddr} Image
fatload mmc 1:1 ${fdt_addr_r} imx8mp-frdm.dtb

booti ${loadaddr} - ${fdt_addr_r}
```

