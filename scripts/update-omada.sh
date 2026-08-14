#!/usr/bin/env bash
# Add a new Omada release to pkgs/sources/: derives the version from the
# tarball filename, prefetches its hash, and writes pkgs/sources/<version>.json.
#
# Existing files are left alone — the version-prefix attributes
# (omada-controller_6_2 and friends) are derived from the whole directory, so a
# new release adds a file rather than replacing one. Delete a file to retire
# that version.
#
# Usage: scripts/update-omada.sh <tarball-url>
#   The URL is the vendor Linux x64 tarball, from the TP-Link download page or
#   the "New Version Available" issues on mbentley/docker-omada-controller:
#   https://static.tp-link.com/upload/software/YYYY/.../Omada_SDN_Controller_vX.Y.Z_linux_x64.tar.gz
#
# Uses a native nix if present, otherwise nix inside podman (like scripts/nix.sh).
set -euo pipefail

url="${1:-}"
if [ -z "$url" ]; then
  echo "usage: $0 <Omada tarball URL>" >&2
  exit 1
fi

FLAKE_FEATURES="nix-command flakes"
NIX_IMAGE="${NIX_IMAGE:-docker.io/nixos/nix:latest}"
STORE_VOLUME="${OMADA_NIX_STORE_VOLUME:-omada-nix-store}"
sources="$(cd "$(dirname "$0")/.." && pwd)/pkgs/sources"

# Version from the filename: Omada_SDN_Controller_v<version>_linux_x64.tar.gz
fname="${url##*/}"
ver="${fname#Omada_SDN_Controller_v}"
ver="${ver%_linux_x64.tar.gz}"
if [ "$ver" = "$fname" ] || [ -z "$ver" ]; then
  echo "error: could not parse a version from '$fname'" >&2
  echo "       expected Omada_SDN_Controller_v<version>_linux_x64.tar.gz" >&2
  exit 1
fi

json="$sources/$ver.json"
if [ -e "$json" ]; then
  echo "note: $ver is already packaged; re-hashing and rewriting $json" >&2
fi

in_nix() {
  # Run a command with nix tooling on PATH, native or via podman.
  if command -v nix >/dev/null 2>&1; then
    "$@"
  else
    if ! command -v podman >/dev/null 2>&1; then
      echo "error: need 'nix' or 'podman' to compute the hash." >&2
      exit 1
    fi
    podman run --rm --volume "${STORE_VOLUME}:/nix" "${NIX_IMAGE}" "$@"
  fi
}

echo ">> prefetching $url (downloads the ~291 MB tarball to hash it) ..." >&2
# --unpack hash matches fetchzip stripRoot=false; the base32 is on stdout.
b32="$(in_nix nix-prefetch-url --unpack --type sha256 "$url" | tail -n1)"
sri="$(in_nix nix --extra-experimental-features "${FLAKE_FEATURES}" \
  hash convert --hash-algo sha256 --to sri "$b32" | tail -n1)"

cat > "$json" <<EOF
{
  "version": "$ver",
  "url": "$url",
  "hash": "$sri"
}
EOF

echo ">> added Omada $ver"
echo ">> wrote $json ($sri)"
echo ">> now reachable as .#omada-controller_${ver//./_} (and the shorter prefixes it heads)"
echo ">> verify:  just test    (boots a VM and checks the UI)"
