# Justfile for omada-controller-flake
#
# All recipes go through scripts/nix.sh, which uses a native `nix` if present
# and otherwise runs nix inside podman, so a host without Nix still works.

nix := "./scripts/nix.sh"
system := `uname -m` + "-linux"

# List available recipes.
default:
    @just --list

# Report which backend (native nix vs podman) will be used.
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v nix >/dev/null 2>&1; then
      echo "backend: native nix ($(command -v nix))"
      nix --version
    elif command -v podman >/dev/null 2>&1; then
      echo "backend: podman ($(command -v podman)) -> ${NIX_IMAGE:-docker.io/nixos/nix:latest}"
      podman --version
    else
      echo "backend: NONE — install nix or podman" >&2
      exit 1
    fi

# Format all Nix files with nixfmt.
fmt:
    {{nix}} fmt

# Evaluate the flake and run its checks (includes the VM integration test).
check:
    {{nix}} flake check

# Fast evaluation-only sanity check of the module (no builds).
eval:
    {{nix}} eval --raw .#nixosModules.default --apply 'm: "module ok"'

# Update flake.lock to the latest nixpkgs.
update:
    {{nix}} flake update

# Add an Omada controller release (downloads the tarball to hash it).
#   just update-omada https://static.tp-link.com/.../Omada_SDN_Controller_vX_linux_x64.tar.gz
update-omada url:
    ./scripts/update-omada.sh {{url}}

# Build just the controller package.
build-omada:
    {{nix}} build .#omada-controller

# Build the runnable example VM.
build-vm:
    {{nix}} build .#nixosConfigurations.example.config.system.build.vm

# Build and boot the example VM (needs /dev/kvm). Runs natively when nix is
# present, otherwise headless inside podman with the UI forwarded to localhost.
vm:
    ./scripts/vm.sh

# Build just the VM integration test derivation.
test:
    {{nix}} build .#checks.{{system}}.integration

# Remove build artifacts.
clean:
    rm -f result result-*
