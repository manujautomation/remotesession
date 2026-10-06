FROM debian:trixie-slim

WORKDIR /
ARG DEBIAN_FRONTEND=noninteractive
ENV VCPKG_FORCE_SYSTEM_BINARIES=1
RUN apt update -y && \
    apt install --yes --no-install-recommends \
        g++ \
        gcc \
        git \
        curl \
        nasm \
        yasm \
        libgtk-3-dev \
        clang \
        libxcb-randr0-dev \
        libxdo-dev \
        libxfixes-dev \
        libxcb-shape0-dev \
        libxcb-xfixes0-dev \
        libasound2-dev \
        libpulse-dev \
        make \
        wget \
        libssl-dev \
        unzip \
        zip \
        sudo \
        libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev \
        ca-certificates \
        ninja-build && \
        rm -rf /var/lib/apt/lists/*

# Build hosts without working IPv6 stall here: wget and git resolve AAAA first and have no
# happy-eyeballs fallback, so they hang indefinitely rather than retrying over IPv4. Curl
# falls back, which is why a curl-based reachability test passes while the build hangs.
# Prefer IPv4 for every resolver call in this image.
RUN echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

RUN wget https://github.com/Kitware/CMake/releases/download/v3.30.6/cmake-3.30.6.tar.gz --no-check-certificate && \
    tar xzf cmake-3.30.6.tar.gz && \
    cd cmake-3.30.6 && \
    ./configure  --prefix=/usr/local && \
    make -j4 && \
    make install

RUN git clone --branch 2023.04.15 --depth=1 https://github.com/microsoft/vcpkg && \
    /vcpkg/bootstrap-vcpkg.sh -disableMetrics && \
    /vcpkg/vcpkg --disable-metrics install libvpx libyuv opus aom

RUN groupadd -r user && \
    useradd -r -g user user --home /home/user && \
    mkdir -p /home/user/rustdesk && \
    chown -R user: /home/user && \
    echo "user ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/user

WORKDIR /home/user
RUN curl -LO https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so

USER user
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rustup.sh && \
    chmod +x rustup.sh && \
    ./rustup.sh -y

USER root
ENV HOME=/home/user
COPY ./entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]
