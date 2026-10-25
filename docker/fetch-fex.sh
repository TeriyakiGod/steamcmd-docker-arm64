#!/usr/bin/env bash
# Download the prebuilt FEX packages for every arm64 CPU tier from the
# official FEX PPA and verify them against the PPA's signed index.
#
# Usage: fetch-fex.sh <out-dir> [version|latest]
#
# Result:
#   <out-dir>/opt/fex/armv8.{0,2,4}/   FEX, FEXBash, FEXServer, FEXGetConfig
#   <out-dir>/usr/share/fex-emu/       shared FEX data (AppConfig)
#   <out-dir>/opt/fex/VERSION          resolved package version
set -euo pipefail

OUT=${1:?usage: fetch-fex.sh <out-dir> [version|latest]}
WANT=${2:-latest}

PPA=https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu
SUITE=${FEX_SUITE:-noble}
# Launchpad signing key of ppa:fex-emu/fex. This fingerprint is the trust anchor.
KEY_FPR=EDB98BFE8A2310DC9C4A376E76DBFEBEA206F5AC
VARIANTS=(armv8.0 armv8.2 armv8.4)
BINARIES=(FEX FEXBash FEXServer FEXGetConfig)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"

echo "Fetching PPA signing key $KEY_FPR"
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$KEY_FPR" -o key.asc
got_fpr=$(gpg --batch --with-colons --show-keys key.asc | awk -F: '$1 == "fpr" { print $10; exit }')
if [[ $got_fpr != "$KEY_FPR" ]]; then
    echo "Keyserver returned key $got_fpr, expected $KEY_FPR" >&2
    exit 1
fi
gpg --batch --dearmor < key.asc > key.gpg

echo "Verifying $SUITE InRelease"
curl -fsSL "$PPA/dists/$SUITE/InRelease" -o InRelease
gpgv --keyring ./key.gpg --output Release InRelease

index=main/binary-arm64/Packages.gz
index_sha=$(awk -v f="$index" '/^SHA256:/ { s = 1; next } /^[A-Za-z]/ { s = 0 } s && $3 == f { print $1 }' Release)
[[ -n $index_sha ]] || { echo "$index missing from Release" >&2; exit 1; }
curl -fsSL "$PPA/dists/$SUITE/$index" -o Packages.gz
echo "$index_sha  Packages.gz" | sha256sum -c -
gunzip Packages.gz

# Print "<version> <filename> <sha256>" for a package, newest version last.
package_entries() {
    awk -v pkg="$1" '
        /^Package: /  { p = $2 }
        /^Version: /  { v = $2 }
        /^Filename: / { f = $2 }
        /^SHA256: /   { s = $2 }
        /^$/          { if (p == pkg) print v, f, s; p = v = f = s = "" }
        END           { if (p == pkg) print v, f, s }
    ' Packages | sort -V
}

if [[ $WANT == latest ]]; then
    WANT=$(package_entries fex-emu-armv8.0 | tail -n1 | cut -d' ' -f1)
fi
echo "Using FEX $WANT"

mkdir -p "$OUT/opt/fex" "$OUT/usr/share/fex-emu"
for v in "${VARIANTS[@]}"; do
    read -r _ file sha < <(package_entries "fex-emu-$v" | awk -v want="$WANT" '$1 == want')
    if [[ -z ${file:-} ]]; then
        echo "fex-emu-$v $WANT is not published in the PPA" >&2
        exit 1
    fi
    curl -fsSL "$PPA/$file" -o "$v.deb"
    echo "$sha  $v.deb" | sha256sum -c -
    dpkg-deb -x "$v.deb" "x-$v"
    install -d "$OUT/opt/fex/$v"
    for b in "${BINARIES[@]}"; do
        install -m 755 "x-$v/usr/bin/$b" "$OUT/opt/fex/$v/$b"
    done
done
# Data files are identical across tiers; thunk libraries are left out because
# a headless server has no GPU/audio to forward.
cp -r x-armv8.0/usr/share/fex-emu/AppConfig "$OUT/usr/share/fex-emu/"
echo "$WANT" > "$OUT/opt/fex/VERSION"
