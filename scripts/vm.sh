#!/usr/bin/env bash
# Build and boot the example NixOS VM. Adapts to the environment the same way
# scripts/nix.sh does:
#
#   * native nix  -> build, then run the graphical QEMU VM directly
#   * podman only -> build + run the VM *inside* the container, headless, with
#                    --network host so QEMU's forwarded UI port (8043/8088)
#                    lands on this host's localhost
#
# Either way the Omada UI ends up at https://localhost:8043 once it boots (give
# it a few minutes for MongoDB init + first-run setup). Self-signed cert.
set -euo pipefail

FLAKE_FEATURES="nix-command flakes"
ATTR=".#nixosConfigurations.example.config.system.build.vm"
NIX_IMAGE="${NIX_IMAGE:-docker.io/nixos/nix:latest}"
STORE_VOLUME="${OMADA_NIX_STORE_VOLUME:-omada-nix-store}"

banner() {
  echo ">> VM booting. Open https://localhost:8043 in a few minutes (self-signed cert)." >&2
  echo ">> Quit QEMU with Ctrl-a x (headless) or by closing the window." >&2
}

if command -v nix >/dev/null 2>&1; then
  nix --extra-experimental-features "${FLAKE_FEATURES}" build "${ATTR}"
  banner
  # shellcheck disable=SC2211
  exec ./result/bin/run-*-vm
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "error: neither 'nix' nor 'podman' is available on PATH." >&2
  exit 1
fi

if [ ! -e /dev/kvm ]; then
  echo "error: /dev/kvm not present — the VM needs KVM acceleration." >&2
  exit 1
fi

echo ">> nix not found; building + running the VM via podman (${NIX_IMAGE})" >&2
banner

# One shot: build inside the container, then exec the VM runner from an
# ephemeral cwd (/tmp) so the disk image is thrown away on exit (fresh VM each
# run) and the project dir stays clean. --network host makes QEMU's user-mode
# hostfwd (from the example's forwardPorts) reachable on this host's localhost.
exec podman run --rm -it \
  --network host \
  --device /dev/kvm \
  --volume "${STORE_VOLUME}:/nix" \
  --volume "${PWD}:/workdir" \
  --workdir /workdir \
  --env QEMU_OPTS="-nographic" \
  "${NIX_IMAGE}" \
  sh -c '
    set -e
    vm=$(nix --extra-experimental-features "'"${FLAKE_FEATURES}"'" \
      build "'"${ATTR}"'" --no-link --print-out-paths)
    cd /tmp
    exec "$vm"/bin/run-*-vm
  '
