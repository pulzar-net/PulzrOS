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
        python3-distutils \
        gawk \
        rsync \
        binutils \
        openssl \
        perl \
    && rm -rf /var/lib/apt/lists/*

# ImageBuilder's prereq check specifically wants GNU awk (bookworm-slim ships
# mawk) and the Python3 distutils module, so both are installed explicitly. The
# remaining prereq — a case-sensitive filesystem — cannot hold on a macOS bind
# mount, so build.sh passes FORCE=1 to make; ImageBuilder assembly tolerates it.

WORKDIR /src
