{ ... }:

# Example host running the Omada controller natively. Copy the relevant bits
# into your own configuration.
{
  # The vendor build and MongoDB 8 (mongodb-ce) are unfree.
  nixpkgs.config.allowUnfree = true;

  services.omada-controller.enable = true;

  # VM-only overrides so `nixos-rebuild build-vm` / `just vm` gives a throwaway
  # box you can actually poke at: the web UI is forwarded to the host and root
  # logs in without a password. None of this touches a real deployment.
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
      # MongoDB 8 needs AVX, which QEMU's default CPU hides; `-cpu max` exposes it.
      qemu.options = [ "-cpu max" ];
      forwardPorts = [
        {
          from = "host";
          host.port = 8043;
          guest.port = 8043;
        }
        {
          from = "host";
          host.port = 8088;
          guest.port = 8088;
        }
      ];
    };
    users.users.root.password = "";
    services.getty.autologinUser = "root";
  };

  # --- minimal boilerplate so `nixos-rebuild build-vm` / flake check works ---
  boot.loader.grub.device = "/dev/sda";
  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };
  system.stateVersion = "24.05";
}
