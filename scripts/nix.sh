#!/usr/bin/env bash
# Run nix. Prefer a native `nix` binary; if none exists (e.g. a Fedora box
# without the Nix daemon), transparently run the official nix image under
# podman with this project bind-mounted.
#
# Usage: scripts/nix.sh <nix args...>
#   scripts/nix.sh flake check
#   scripts/nix.sh build .#checks.x86_64-linux.integration
set -euo pipefail

NIX_IMAGE="${NIX_IMAGE:-docker.io/nixos/nix:latest}"
FLAKE_FEATURES="nix-command flakes"

if command -v nix >/dev/null 2>&1; then
  exec nix --extra-experimental-features "${FLAKE_FEATURES}" "$@"
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "error: neither 'nix' nor 'podman' is available on PATH." >&2
  echo "       install one of them to use this project." >&2
  exit 1
fi

echo ">> nix not found; running via podman (${NIX_IMAGE})" >&2

# A named volume persists /nix across runs so the store/downloads are cached.
# The nixos/nix image populates /nix on first use; podman seeds an empty named
# volume from the image contents, so the bundled nix binary survives.
STORE_VOLUME="${OMADA_NIX_STORE_VOLUME:-omada-nix-store}"

run_flags=()
# Interactive TTY only when we actually have one (keeps `just` non-interactive
# invocations working in CI/pipes).
[ -t 0 ] && [ -t 1 ] && run_flags+=(--interactive --tty)
# Expose KVM for VM-based flake checks / build-vm when the host has it.
[ -e /dev/kvm ] && run_flags+=(--device /dev/kvm)

exec podman run --rm \
  "${run_flags[@]}" \
  --volume "${PWD}:/workdir:z" \
  --volume "${STORE_VOLUME}:/nix" \
  --workdir /workdir \
  "${NIX_IMAGE}" \
  nix --extra-experimental-features "${FLAKE_FEATURES}" "$@"
