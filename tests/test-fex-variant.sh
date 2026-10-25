#!/usr/bin/env bash
# Unit test for docker/fex-variant. Needs only bash, so it runs on any host.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
variant=$here/../docker/fex-variant
fail=0

expect() {
    local fixture=$1 want=$2 got
    got=$("$variant" "$here/fixtures/$fixture")
    if [[ $got == "$want" ]]; then
        echo "ok   $fixture -> $got"
    else
        echo "FAIL $fixture -> $got (want $want)"
        fail=1
    fi
}

expect cpuinfo-cortex-a72  armv8.0   # Raspberry Pi 4
expect cpuinfo-neoverse-n1 armv8.2   # Oracle Ampere A1, Raspberry Pi 5 (Cortex-A76)
expect cpuinfo-neoverse-v1 armv8.4   # AWS Graviton3

exit $fail
