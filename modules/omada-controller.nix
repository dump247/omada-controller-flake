{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.omada-controller;

  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    escapeShellArg
    concatStringsSep
    ;

  pkg = cfg.package;
  share = "${pkg}/share/omada-controller";

  # stateDir holds only the backup-worthy state (data/ + properties/).
  state = cfg.stateDir;

  # Non-backed-up locations for everything regenerable.
  cacheDir = "/var/cache/omada-controller";
  logDir = "/var/log/omada-controller";
  # OMADA_HOME: the assembled runtime tree. Holds the ~307 MB of jars (hardlinked
  # from the store), so it lives here and NOT in the backup target.
  homeDir = "${cacheDir}/home";

  javaOpts = concatStringsSep " " (
    pkg.javaOpts ++ [ "-XX:HeapDumpPath=${logDir}/java_heapdump.hprof" ]
  );

  # Assembles OMADA_HOME before start, seeded from the read-only package. Runs as
  # root (ExecStartPre '+').
  #
  # Backup contract: stateDir is a single, whole-directory backup target — no
  # exclude list. It holds only real state: the MongoDB database and config under
  # data/ and properties/. Everything regenerable lives outside it — the jars in
  # ${homeDir} (hardlinked from the store: no extra disk, not backed up), logs in
  # ${logDir}, and the servlet work dir in ${cacheDir}.
  #
  # OMADA_HOME is NOT stateDir: the controller derives its home from the
  # *canonical* directory of its jars, so the jars must physically live under
  # OMADA_HOME. To keep those ~307 MB out of the backup, OMADA_HOME is ${homeDir},
  # and its data/ and properties/ are symlinks back into stateDir (the controller
  # writes through them) while logs/ and work/ point at ${logDir} / ${cacheDir}.
  preStart = pkgs.writeShellScript "omada-controller-pre-start" ''
    set -euo pipefail

    share=${escapeShellArg share}
    state=${escapeShellArg state}
    home=${escapeShellArg homeDir}
    cache=${escapeShellArg cacheDir}
    logs=${escapeShellArg logDir}

    # --- stateDir (backed up): the database + config live directly here ---
    mkdir -p \
      "$state/data/db" "$state/data/keystore" "$state/data/pdf" \
      "$state/data/chromium" "$state/data/autobackup" \
      "$cache/work" "$logs"

    # properties: seed once, then leave alone (the controller rewrites ports here).
    if [ ! -e "$state/properties/omada.properties" ]; then
      mkdir -p "$state/properties"
      cp "$share"/properties/* "$state/properties/"
    fi

    # static assets: tiny (~1.6 MB), refreshed each start to track the version.
    for d in html static cluster; do
      if [ -e "$share/data/$d" ]; then
        rm -rf "$state/data/$d"
        cp -r "$share/data/$d" "$state/data/$d"
      fi
    done

    chmod -R u+w "$state/properties" "$state/data"
    chown -R ${cfg.user}:${cfg.group} "$state" "$logs" "$cache/work"

    # --- OMADA_HOME (NOT backed up): jars + symlinks back to the state dirs ---
    # lib is HARDLINKED from the store so the jars' canonical dir stays inside
    # OMADA_HOME (a symlink would canonicalise back to the read-only store, and
    # the controller would then look for a writable omada.properties there and
    # fail). The jars keep the store's root ownership and are never chowned —
    # they share its inodes.
    rm -rf "$home"
    mkdir -p "$home/lib" "$home/bin"
    cp -al "$share"/lib/. "$home/lib/" 2>/dev/null || cp -a "$share"/lib/. "$home/lib/"
    ln -s ${pkg.mongodb}/bin/mongod  "$home/bin/mongod"
    ln -s ${pkg.mongosh}/bin/mongosh "$home/bin/mongosh"
    ln -sfnT "$state/properties" "$home/properties"
    ln -sfnT "$state/data"       "$home/data"
    ln -sfnT "$logs"             "$home/logs"
    ln -sfnT "$cache/work"       "$home/work"
  '';
in
{
  options.services.omada-controller = {
    enable = mkEnableOption "the TP-Link Omada SDN Controller (native, from the official vendor build)";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/omada-controller.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/omada-controller.nix { }";
      description = ''
        The Omada controller package. Uses MongoDB 8 (`mongodb-ce`) and
        `jdk17_headless` by default — both unfree, so your host needs
        `nixpkgs.config.allowUnfree = true` (or an allow-list predicate).
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/omada-controller";
      description = ''
        The single directory holding all backup-worthy state: the MongoDB
        database and config under `data/` and `properties/`. This is the only
        path you need to back up (regenerable jars/logs/work live under
        /var/cache and /var/log). Put it on its own btrfs subvolume or ZFS
        dataset if you want cheap snapshots.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "omada";
      description = "User the controller runs as. Owns the state directory (mongod needs stable ownership of its dbpath).";
    };

    group = mkOption {
      type = types.str;
      default = "omada";
      description = "Group the controller runs as.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
        {
          assertion = pkg.meta.platforms == [ "x86_64-linux" ] -> pkgs.stdenv.hostPlatform.system == "x86_64-linux";
          message = "services.omada-controller: the vendor build is x86_64-linux only.";
        }
      ];

      users.groups.${cfg.group} = { };
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
        description = "Omada SDN Controller";
      };

      systemd.services.omada-controller = {
        description = "TP-Link Omada SDN Controller";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        # The controller launches its own mongod (found on PATH / under
        # OMADA_HOME/bin) via a shell, uses mongosh for version checks, and curl
        # is a documented dependency.
        path = [
          pkg.jdk
          pkg.mongodb
          pkg.mongosh
          pkgs.bash
          pkgs.curl
          pkgs.coreutils
        ];

        environment = {
          # Keep any stray $HOME writes out of the backup target.
          HOME = cacheDir;
          # Headless-chromium profile dir for the PDF/report export feature.
          XDG_CONFIG_HOME = "${cfg.stateDir}/data/chromium";
        };

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;

          # Regenerable churn lives here, outside the state dir, so it's not in
          # the backup: /var/log/omada-controller and /var/cache/omada-controller.
          LogsDirectory = "omada-controller";
          CacheDirectory = "omada-controller";
          # Writable /run/omada-controller for jsvc's pidfile.
          RuntimeDirectory = "omada-controller";

          # '+' → run the assembly step as root so it can chown the tree.
          ExecStartPre = "+${preStart}";

          # Run jsvc in the foreground (-nodetach) so systemd owns the process
          # directly. Classpath uses Java's own `lib/*` wildcard (expanded by
          # the JVM, NOT the shell — systemd passes it literally, as required).
          ExecStart = concatStringsSep " " [
            "${pkg.jsvc}/bin/jsvc"
            "-nodetach"
            "-pidfile /run/omada-controller/omada.pid"
            "-home ${pkg.jdk.home}"
            "-cwd ${homeDir}/lib"
            "-cp ${homeDir}/lib/*:${homeDir}/properties"
            "-outfile ${logDir}/startup.log"
            "-errfile ${logDir}/startup.log"
            "-procname omada"
            "-showversion"
            javaOpts
            "${pkg.mainClass} start"
          ];

          Restart = "on-failure";
          RestartSec = 10;
          # First boot initialises MongoDB and migrates schemas — can be slow.
          TimeoutStartSec = 900;
          TimeoutStopSec = 120;
          LimitNOFILE = 65535;
          # Reap the mongod child on stop.
          KillMode = "control-group";
        };
      };
  };
}
