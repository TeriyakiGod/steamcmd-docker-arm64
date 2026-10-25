# syntax=docker/dockerfile:1
#
# SteamCMD for arm64, running the x86 SteamCMD client through the FEX emulator.
#
# Nothing is compiled: FEX comes from the official FEX PPA and the x86 root
# filesystem from rootfs.fex-emu.gg, both verified while building.

ARG UBUNTU_VERSION=24.04

# ---------------------------------------------------------------------------
# fetch: downloads and unpacks everything. Runs on the build machine's own
# architecture, so cross-building from x86_64 doesn't emulate this work.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ubuntu:${UBUNTU_VERSION} AS fetch

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG FEX_VERSION=latest
ARG ROOTFS_URL=https://rootfs.fex-emu.gg/Ubuntu_24_04/2026-08-11/Ubuntu_24_04.sqsh
ARG ROOTFS_SHA256=2854b06d3ff1b8f6e526135bfb6dd5b7b30ab3ab73e79ae933a3d9fed959a178
ARG STEAMCMD_URL=https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg squashfs-tools \
 && rm -rf /var/lib/apt/lists/*

COPY docker/fetch-fex.sh /usr/local/bin/fetch-fex.sh
RUN fetch-fex.sh /out "$FEX_VERSION"

RUN curl -fsSL "$ROOTFS_URL" -o /tmp/rootfs.sqsh \
 && echo "$ROOTFS_SHA256  /tmp/rootfs.sqsh" | sha256sum -c - \
 && mkdir -p /out/opt/fex-rootfs \
 && unsquashfs -q -no-xattrs -d /out/opt/fex-rootfs/x86 /tmp/rootfs.sqsh \
 && rm /tmp/rootfs.sqsh

# The tarball stays in the image so the entrypoint can unpack it into an
# empty bind mount; the unpacked copy seeds named volumes.
RUN mkdir -p /out/opt/steamcmd /steamcmd \
 && curl -fsSL "$STEAMCMD_URL" -o /out/opt/steamcmd/steamcmd_linux.tar.gz \
 && tar -xzf /out/opt/steamcmd/steamcmd_linux.tar.gz -C /steamcmd \
 && test -x /steamcmd/steamcmd.sh

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libstdc++6 tini \
 && rm -rf /var/lib/apt/lists/* \
 # The base image ships an "ubuntu" user on uid 1000; give that uid to steam.
 && userdel --remove ubuntu \
 && useradd --create-home --uid 1000 --shell /bin/bash steam \
 && install -d -o steam -g steam /data

COPY --link --from=fetch /out/ /
COPY --chown=1000:1000 --from=fetch /steamcmd /home/steam/steamcmd
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint
COPY --chmod=755 docker/fex-variant /usr/local/bin/fex-variant

ENV FEX_ROOTFS=/opt/fex-rootfs/x86 \
    STEAMCMD_DIR=/home/steam/steamcmd

# Numeric so `runAsNonRoot`-style checks can verify it without /etc/passwd.
USER 1000:1000
WORKDIR /home/steam

LABEL org.opencontainers.image.title="steamcmd-arm64" \
      org.opencontainers.image.description="SteamCMD on arm64 via the FEX x86 emulator" \
      org.opencontainers.image.source="https://github.com/TeriyakiGod/steamcmd-docker-arm64"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
