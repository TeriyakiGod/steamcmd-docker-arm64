#!/usr/bin/env bash
# End-to-end test of a built image.
#
# Usage: tests/smoke.sh [image]            (default: steamcmd-arm64:test)
#
# Set FULL=1 to also download a small app (Steamworks SDK Redist, app 1007)
# into a bind mount, which proves the whole SteamCMD -> /data path works.
#
# On a non-arm64 Docker host (x86_64 with qemu-user binfmt) the 32-bit checks
# are skipped: FEX's 32-bit mode reserves all address space above 4 GB, which
# qemu-user can't provide, so i386 programs (SteamCMD included) hang or crash
# there. Those checks need a real arm64 host, such as the CI runner.
set -euo pipefail

IMAGE=${1:-steamcmd-arm64:test}
FULL=${FULL:-0}
failures=0
skipped=0

native=0
[[ $(docker info -f '{{.Architecture}}') == aarch64 ]] && native=1

# Every container gets a deadline, so a wedged emulator fails a check instead
# of hanging the run.
run() { timeout --foreground 900 docker run --rm --platform linux/arm64 "$@"; }

check() {
    local name=$1; shift
    printf -- '--- %s\n' "$name"
    if "$@"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        failures=$((failures + 1))
    fi
}

image_is_arm64() {
    [[ $(docker image inspect -f '{{.Architecture}}' "$IMAGE") == arm64 ]]
}

runs_as_steam() {
    [[ $(run --entrypoint id "$IMAGE" -un) == steam ]]
}

fex_variant_selected() {
    local out
    # shellcheck disable=SC2016 # expanded inside the container
    out=$(run "$IMAGE" bash -c 'echo "$FEX_VARIANT"; command -v FEX')
    echo "$out"
    grep -qE '^armv8\.[024]$' <<< "$out" && grep -q '^/opt/fex/armv8\.[024]/FEX$' <<< "$out"
}

variant_override() {
    [[ $(run -e FEX_VARIANT=armv8.0 "$IMAGE" bash -c 'command -v FEX') == /opt/fex/armv8.0/FEX ]]
}

bad_variant_rejected() {
    local out
    if out=$(run -e FEX_VARIANT=armv9 "$IMAGE" true 2>&1); then return 1; fi
    grep -q "unknown FEX_VARIANT" <<< "$out"
}

runs_x86_64_binary() {
    local out
    out=$(run "$IMAGE" fex /bin/uname -m)
    echo "$out"
    [[ $out == x86_64 ]]
}

runs_i386_binary() {
    # SteamCMD is 32-bit, so the rootfs must carry a working i386 userland.
    local out
    out=$(run "$IMAGE" fex /usr/lib/i386-linux-gnu/ld-linux.so.2 --version 2>&1 | head -n1)
    echo "$out"
    [[ $out == *ld.so* || $out == *"dynamic linker"* ]]
}

steamcmd_starts() {
    # First start updates SteamCMD itself; +quit must exit cleanly afterwards.
    local out
    out=$(run "$IMAGE" +quit 2>&1 | tail -n 20)
    echo "$out"
    grep -qE 'Loading Steam API\.\.\.OK|Steam Console Client' <<< "$out"
}

empty_bind_mount_bootstraps() {
    local dir
    dir=$(mktemp -d)
    chmod 777 "$dir"
    run -v "$dir:/home/steam/steamcmd" "$IMAGE" +quit > /dev/null 2>&1 || true
    local ok=1
    [[ -x $dir/steamcmd.sh ]] && ok=0
    remove_mount_dir "$dir"
    return $ok
}

unwritable_mount_explained() {
    local dir out
    dir=$(mktemp -d)
    chmod 555 "$dir"   # read-only for every uid, including the container's 1000
    out=$(run -v "$dir:/home/steam/steamcmd" "$IMAGE" +quit 2>&1 || true)
    rmdir "$dir"
    echo "$out"
    grep -q "is not writable by uid 1000" <<< "$out"
}

stops_on_sigterm() {
    # tini must forward SIGTERM through FEX to the emulated process, so
    # `docker stop` doesn't sit out its 10 s grace period and SIGKILL.
    local name start elapsed
    name=smoke-stop-$$
    docker run -d --rm --platform linux/arm64 --name "$name" "$IMAGE" fex /bin/sleep 600 > /dev/null
    sleep 5
    start=$SECONDS
    docker stop -t 30 "$name" > /dev/null
    elapsed=$((SECONDS - start))
    echo "stopped in ${elapsed}s"
    (( elapsed < 10 ))
}

installs_app() {
    local dir
    dir=$(mktemp -d)
    chmod 777 "$dir"
    run -v "$dir:/data" "$IMAGE" \
        +force_install_dir /data/sdk +login anonymous +app_update 1007 validate +quit
    local ok=1
    ls "$dir/sdk"/linux64/steamclient.so && ok=0
    remove_mount_dir "$dir"
    return $ok
}

# Files written by the container belong to uid 1000, so delete them from inside.
remove_mount_dir() {
    run -v "$1:/d" --entrypoint find "$IMAGE" /d -mindepth 1 -delete
    rmdir "$1"
}

# Like check, but only on a native arm64 Docker host.
check_native() {
    if (( native )); then
        check "$@"
    else
        printf 'skip %s (needs an arm64 Docker host)\n' "$1"
        skipped=$((skipped + 1))
    fi
}

check        "image is arm64"                       image_is_arm64
check        "runs as non-root steam user"          runs_as_steam
check        "FEX variant auto-selected"            fex_variant_selected
check        "FEX_VARIANT override"                 variant_override
check        "invalid FEX_VARIANT rejected"         bad_variant_rejected
check        "x86-64 binary runs under FEX"         runs_x86_64_binary
check_native "i386 binary runs under FEX"           runs_i386_binary
check        "unwritable mount gives clear error"   unwritable_mount_explained
check        "docker stop reaches emulated process" stops_on_sigterm
check_native "SteamCMD starts and updates"          steamcmd_starts
check_native "empty bind mount is bootstrapped"     empty_bind_mount_bootstraps
if [[ $FULL == 1 ]]; then
    check_native "SteamCMD installs an app"             installs_app
fi

echo
(( skipped )) && echo "$skipped check(s) skipped: run on an arm64 host for full coverage"
if (( failures )); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
