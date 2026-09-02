{ lib }:

# Every release under pkgs/sources/, parsed once: the JSON as written keyed by
# version, and the versions newest-first. Separate from pkgs/omada-versions.nix,
# which is applied as an overlay: everything it returns lands in `pkgs`.
let
  sourceDir = ./sources;

  sources = lib.mapAttrs' (
    file: _:
    let
      source = builtins.fromJSON (builtins.readFile (sourceDir + "/${file}"));
    in
    lib.nameValuePair source.version source
  ) (lib.filterAttrs (name: _: lib.hasSuffix ".json" name) (builtins.readDir sourceDir));
in
{
  inherit sources;

  # Newest first, so the head of a filtered list is that prefix's newest match.
  versions = lib.sort (a: b: builtins.compareVersions a b > 0) (lib.attrNames sources);
}
