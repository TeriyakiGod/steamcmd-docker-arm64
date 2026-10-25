#!/usr/bin/env bash
# Container entrypoint.
#
#   (no arguments)        interactive SteamCMD prompt
#   +login anonymous ...  SteamCMD with those arguments
#   steamcmd [args...]    same, spelled out
#   fex <x86-binary> ...  run any x86/x86-64 program, e.g. a game server
#   anything else         run it as a normal (arm64) command, e.g. bash
set -euo pipefail

log() { printf '[steamcmd-arm64] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

preflight() {
    local arch page
    arch=$(uname -m)
    [[ $arch == aarch64 ]] || die "this image needs an arm64 (aarch64) host, got $arch"

    page=$(getconf PAGESIZE)
    if [[ $page != 4096 ]]; then
        die "the kernel uses ${page}-byte pages, but FEX needs 4K pages.
  Raspberry Pi 5: add 'kernel=kernel8.img' to /boot/firmware/config.txt and reboot.
  Asahi Linux and other 16K kernels need a 4K-page kernel or a 4K VM."
    fi

    FEX_VARIANT=${FEX_VARIANT:-$(fex-variant)}
    [[ -x /opt/fex/$FEX_VARIANT/FEX ]] ||
        die "unknown FEX_VARIANT '$FEX_VARIANT' (use armv8.0, armv8.2 or armv8.4)"
    export FEX_VARIANT PATH="/opt/fex/$FEX_VARIANT:$PATH"
}

# Unpack SteamCMD on first start, so an empty bind mount on $STEAMCMD_DIR works.
bootstrap_steamcmd() {
    [[ -x $STEAMCMD_DIR/steamcmd.sh ]] && return
    mkdir -p "$STEAMCMD_DIR" 2>/dev/null || true
    [[ -w $STEAMCMD_DIR ]] ||
        die "$STEAMCMD_DIR is not writable by uid $(id -u). Fix the mount, e.g.: sudo chown -R $(id -u):$(id -g) <host-dir>"
    log "installing SteamCMD bootstrapper into $STEAMCMD_DIR"
    tar -xzf /opt/steamcmd/steamcmd_linux.tar.gz -C "$STEAMCMD_DIR"
}

run_steamcmd() {
    bootstrap_steamcmd
    cd "$STEAMCMD_DIR"
    # steamcmd.sh is an x86 bash script; run it with the rootfs's bash.
    exec FEX /bin/bash ./steamcmd.sh "$@"
}

preflight

if [[ $# -eq 0 || $1 == +* ]]; then
    run_steamcmd "$@"
fi

case $1 in
    steamcmd) shift; run_steamcmd "$@" ;;
    fex)      shift; exec FEX "$@" ;;
    *)        exec "$@" ;;
esac
