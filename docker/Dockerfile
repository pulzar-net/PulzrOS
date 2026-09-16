# The image-assembly container.
#
# Only needed on macOS. OpenWrt's ImageBuilder is a tree of prebuilt x86_64 ELF
# binaries with no macOS build, so `build.sh` runs the parts that work natively
# — the React console, the package feed — on the host, and re-execs just the
# final assembly in here.
#
# It exists as a Dockerfile rather than a long `docker run debian … apt-get
# install …` one-liner so the dependency install is cached. The first build
# takes a minute; every one after it starts instantly.
#
# No Node: the console is already built on the host by the time this runs, and
# its node_modules contain darwin binaries (esbuild, rollup) that would not run
# here anyway. That split is deliberate — see reexec_for_assembly in build.sh.

FROM debian:bookworm-slim

# ImageBuilder's own requirements, plus what our build.sh calls directly.
# libncurses is for its menuconfig machinery, which `make image` touches even
# though we never open it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libncurses-dev \
        zstd \
        unzip \
        gzip \
        file \
        wget \
        curl \
        ca-certificates \
        git \
        python3 \
        rsync \
        binutils \
        openssl \
        perl \
        # The rest is OpenWrt's buildroot, for boards whose ImageBuilder is
        # built from source (OPENWRT_IMAGEBUILDER=source).
        bison \
        bzip2 \
        flex \
        gawk \
        gettext \
        libssl-dev \
        patch \
        python3-dev \
        python3-setuptools \
        swig \
        time \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ImageBuilder resolves a handful of tools by unqualified name and expects a
# GNU userland; bookworm-slim has one, so nothing else is needed here.

WORKDIR /src
