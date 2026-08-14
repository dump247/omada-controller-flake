{ lib, callPackage }:

# Every release under pkgs/sources/, exposed nixpkgs-style as one attribute per
# version prefix: 6.2.14.11 alone yields omada-controller_6, _6_2, _6_2_14 and
# _6_2_14_11, each resolving to the newest version matching its prefix.
#
# Adding a release is dropping a JSON file in pkgs/sources/ (`just
# update-omada <url>`); the attributes follow from the versions found there.

let
  sourceDir = ./sources;

  sources = lib.mapAttrs' (
    file: _:
    let
      source = builtins.fromJSON (builtins.readFile (sourceDir + "/${file}"));
    in
    lib.nameValuePair source.version source
  ) (lib.filterAttrs (name: _: lib.hasSuffix ".json" name) (builtins.readDir sourceDir));

  # Newest first, so the head of a filtered list is that prefix's newest match.
  versions = lib.sort (a: b: builtins.compareVersions a b > 0) (lib.attrNames sources);

  versionPrefixes = lib.unique (
    lib.concatMap (
      version:
      let
        parts = lib.splitString "." version;
      in
      map (n: lib.concatStringsSep "." (lib.take n parts)) (lib.range 1 (lib.length parts))
    ) versions
  );

  # Match on a dot boundary, so prefix 6.2 never swallows a future 6.20.x.
  newestMatching =
    prefix: lib.head (lib.filter (v: v == prefix || lib.hasPrefix "${prefix}." v) versions);

  byVersion = lib.genAttrs versions (
    version: callPackage ./omada-controller.nix { source = sources.${version}; }
  );

  attrName = prefix: "omada-controller_" + lib.replaceStrings [ "." ] [ "_" ] prefix;
in
lib.listToAttrs (
  map (prefix: lib.nameValuePair (attrName prefix) byVersion.${newestMatching prefix}) versionPrefixes
)
// {
  omada-controller = byVersion.${lib.head versions};
}
