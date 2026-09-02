{
  description = "TP-Link Omada SDN Controller as a native NixOS service, with all state under a single backup-friendly directory";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f system);
      # The vendor build and MongoDB 8 are both unfree.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      # One attribute per version prefix — see pkgs/omada-versions.nix.
      omadaFor = system: import ./pkgs/omada-versions.nix { inherit (pkgsFor system) lib callPackage; };
      versionAttr = version: "omada-controller_" + lib.replaceStrings [ "." ] [ "_" ] version;

      # The release before the newest, which the upgrade check upgrades from.
      # null until pkgs/sources/ holds a second one.
      packagedVersions = (import ./pkgs/omada-sources.nix { inherit lib; }).versions;
      previousVersion = if lib.length packagedVersions > 1 then lib.elemAt packagedVersions 1 else null;
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

      # The packaged controller, for `nix build .#omada-controller` or reuse via
      # the overlay. Each version is also exposed under every prefix of its
      # version number (omada-controller_6, _6_2, ...), so a consumer chooses
      # how narrowly to hold; the unsuffixed attribute is the newest version.
      # lib comes from prev: the attribute *names* are computed with it, and
      # final's would need the fixpoint this overlay is still defining.
      overlays.default =
        final: prev:
        import ./pkgs/omada-versions.nix {
          inherit (prev) lib;
          inherit (final) callPackage;
        };

      packages = forAllSystems (
        system:
        (omadaFor system)
        // {
          default = self.packages.${system}.omada-controller;
        }
      );

      # A ready-to-copy example host configuration.
      nixosConfigurations.example = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.omada-controller
          ./example/configuration.nix
        ];
      };

      # `nix flake check` boots the controller in a VM and asserts the UI comes
      # up. Heavy (downloads the vendor tarball + builds MongoDB closure), so it
      # covers the newest version only, not every version in pkgs/sources/.
      #
      # `upgrade` is a second VM for the state the newest version alone can't
      # produce: the previous release boots first and the system is switched
      # under it. It costs another tarball and another first start, and it only
      # exists once pkgs/sources/ holds two releases.
      checks = forAllSystems (
        system:
        {
          integration = (pkgsFor system).callPackage ./tests/integration.nix {
            module = self.nixosModules.omada-controller;
            package = (omadaFor system).omada-controller;
          };
        }
        // lib.optionalAttrs (previousVersion != null) {
          upgrade = (pkgsFor system).callPackage ./tests/upgrade.nix {
            module = self.nixosModules.omada-controller;
            oldPackage = (omadaFor system).${versionAttr previousVersion};
            newPackage = (omadaFor system).omada-controller;
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
