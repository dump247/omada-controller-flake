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
}:

# TP-Link's official Omada SDN Controller, unpacked from the vendor tarball.
#
# Deliberately installs everything under $out/share/omada-controller and
# exposes NOTHING in $out/bin: the launcher (bin/control.sh) and jsvc must not
# leak onto the system PATH. The NixOS module drives it directly via absolute
# paths in a systemd unit.
#
# The controller is a relocatable Java app: control.sh derives OMADA_HOME as
# the parent of its own bin/ dir, so the module can point OMADA_HOME at a
# writable state directory. It launches its own `mongod` (found at
# OMADA_HOME/bin/mongod or on PATH) — there is no separate mongod service.
#
# The version/url/hash are pinned in omada-source.json; bump them with
# `just update-omada <tarball-url>`.
let
  source = builtins.fromJSON (builtins.readFile ./omada-source.json);
in
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
    cp -r "$inner"/bin "$inner"/lib "$inner"/properties "$inner"/data "$dst"/

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
