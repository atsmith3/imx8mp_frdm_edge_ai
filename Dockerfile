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
