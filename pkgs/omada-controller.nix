{
  lib,
  stdenvNoCC,
  fetchzip,
  jdk17_headless,
  mongodb-ce,
  mongosh,
  jsvc,
  # MongoDB engine the controller launches. Defaults to Mongo 8 (matches
  # TP-Link's own v6 direction). Override with `mongodb-7_0` for CPUs without
  # AVX (Mongo 8's prebuilt binaries require it):
  #   packages.omada-controller.override { mongodbPackage = pkgs.mongodb-7_0; }
  mongodbPackage ? mongodb-ce,
  # One release: { version, url, hash } from pkgs/sources/. No default —
  # pkgs/omada-versions.nix instantiates this once per file it finds there.
  source,
}:

# TP-Link's official Omada SDN Controller, unpacked from the vendor tarball.
#
# Installs under $out/share/omada-controller with NOTHING in $out/bin: the
# NixOS module drives the controller from a systemd unit via absolute paths, so
# no launcher reaches the system PATH.
#
# The vendor's bin/ isn't packaged at all — the unit spells out the invocation
# control.sh would have made (see javaOpts below) and runs nixpkgs' jsvc, and
# the module symlinks its own mongod/mongosh into the OMADA_HOME it assembles.
# That assembly works because the app is relocatable: it derives OMADA_HOME from
# the canonical directory of its jars, so pointing it at a writable tree outside
# the store is enough. The controller launches that mongod itself — there is no
# separate mongod service.
#
# The version/url/hash come from pkgs/sources/; add a release with
# `just update-omada <tarball-url>`.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "omada-controller";
  version = source.version;

  src = fetchzip {
    inherit (source) url hash;
    # The archive contains `Omada_Network_Application_.../` *and* `readme.txt`
    # at the top level, so there is no single root to strip.
    stripRoot = false;
  };

  dontConfigure = true;
  dontBuild = true;

  # Purely a repackaging of prebuilt Java bytecode + native mongod deps.
  installPhase = ''
    runHook preInstall

    inner="Omada_Network_Application_v${finalAttrs.version}_linux_x64"
    dst="$out/share/omada-controller"
    mkdir -p "$dst"
    cp -r "$inner"/lib "$inner"/properties "$inner"/data "$dst"/

    runHook postInstall
  '';

  # Expose the runtime deps so the module doesn't have to re-thread them.
  passthru = {
    jdk = jdk17_headless;
    mongodb = mongodbPackage;
    inherit mongosh jsvc;
    mainClass = "com.tplink.smb.omada.starter.OmadaLinuxMain";
    # JAVA_OPTS as set by the vendor's control.sh (minus paths the module fills).
    javaOpts = [
      "-server"
      "-XX:MaxHeapFreeRatio=60"
      "-XX:MinHeapFreeRatio=30"
      "-XX:+HeapDumpOnOutOfMemoryError"
      "-Djava.awt.headless=true"
      "-Djdk.lang.Process.launchMechanism=vfork"
    ];
  };

  meta = {
    description = "TP-Link Omada SDN Controller (official vendor build)";
    homepage = "https://www.tp-link.com/support/download/omada-software-controller/";
    sourceProvenance = with lib.sourceTypes; [
      binaryBytecode
      binaryNativeCode
    ];
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    # No mainProgram: nothing is intentionally exposed in $out/bin.
  };
})
