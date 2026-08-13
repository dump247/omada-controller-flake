{
  description = "TP-Link Omada SDN Controller as a native NixOS service, with all state under a single backup-friendly directory";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      # The vendor build and MongoDB 8 are both unfree.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
    in
    {
      # The reusable NixOS module. Import this into your configuration:
      #
      #   imports = [ omada-controller.nixosModules.default ];
      #   nixpkgs.config.allowUnfree = true;   # vendor build + MongoDB 8
      #   services.omada-controller.enable = true;
      #
      nixosModules.omada-controller = import ./modules/omada-controller.nix;
      nixosModules.default = self.nixosModules.omada-controller;

      # The packaged controller, for `nix build .#omada-controller` or reuse
      # via the overlay.
      overlays.default = final: _prev: {
        omada-controller = final.callPackage ./pkgs/omada-controller.nix { };
      };

      packages = forAllSystems (system: {
        omada-controller = (pkgsFor system).callPackage ./pkgs/omada-controller.nix { };
        default = self.packages.${system}.omada-controller;
      });

      # A ready-to-copy example host configuration.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.omada-controller
          ./example/configuration.nix
        ];
      };

      # `nix flake check` boots the controller in a VM and asserts the UI
      # comes up. Heavy (downloads the vendor tarball + builds MongoDB closure).
      checks = forAllSystems (system: {
        integration = (pkgsFor system).callPackage ./tests/integration.nix {
          module = self.nixosModules.omada-controller;
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
