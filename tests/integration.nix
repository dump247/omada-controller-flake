{
  pkgs,
  module,
  package,
  ...
}:

# End-to-end VM test: boot a NixOS guest with the controller enabled, wait for
# the service and its embedded MongoDB to come up, and assert the management UI
# answers on :8043. Also verifies the single-state-dir layout is assembled.
#
# Heavy: pulls the ~291 MB vendor tarball and the MongoDB closure, and Omada's
# first boot (Mongo init + schema setup) takes a few minutes — hence the large
# VM and long timeouts.
pkgs.testers.runNixOSTest {
  # `checks` covers the newest version, but the package is an argument, so name
  # the test after it — pointing this at an older version gives a distinct test.
  name = "omada-controller-${package.version}";

  nodes.machine =
    { ... }:
    {
      imports = [ module ];

      # allowUnfree comes from the `pkgs` passed to runNixOSTest (see flake.nix);
      # setting it here too would conflict with that pre-built pkgs instance.

      virtualisation = {
        memorySize = 4096;
        diskSize = 12288;
        cores = 2;
        # MongoDB 8's prebuilt binaries require AVX; QEMU's default CPU doesn't
        # expose it. `-cpu max` advertises AVX under both KVM and TCG.
        qemu.options = [ "-cpu max" ];
      };

      services.omada-controller = {
        enable = true;
        inherit package;
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("omada-controller.service")

    # Surface Omada's own logs early for diagnosis (server.log is the
    # controller's log4j output; startup.log is jsvc's; mongod.log if it started).
    machine.sleep(60)
    print(machine.execute("systemctl status omada-controller --no-pager -l || true")[1])
    print(machine.execute("ls -la /var/log/omada-controller/ || true")[1])
    print(machine.execute(
        'for f in /var/log/omada-controller/*.log; do echo "### $f"; tail -n 120 "$f"; done 2>&1 || true'
    )[1])

    # Omada initialises MongoDB and the web server on first boot; give it time.
    machine.wait_until_succeeds(
        "curl -fsk https://localhost:8043 -o /dev/null", timeout=600
    )
    # mongod should be running as a child of the controller, owned by omada.
    machine.succeed("pgrep -u omada mongod")

    # --- storage layout / backup contract ---
    # stateDir (the backup target) holds only real state — the ~307 MB of jars
    # are NOT in it.
    machine.succeed("test -d /var/lib/omada-controller/data/db")
    machine.succeed("test ! -L /var/lib/omada-controller/data/db")
    machine.succeed("test -e /var/lib/omada-controller/properties/omada.properties")
    machine.succeed("test ! -e /var/lib/omada-controller/lib")

    # OMADA_HOME lives outside the backup target: it holds the hardlinked jars and
    # symlinks data/ + properties/ back into stateDir.
    machine.succeed("ls /var/cache/omada-controller/home/lib/*.jar >/dev/null")
    machine.succeed("test -L /var/cache/omada-controller/home/bin/mongod")
    machine.succeed(
        'test "$(readlink /var/cache/omada-controller/home/data)" = /var/lib/omada-controller/data'
    )
    machine.succeed(
        'test "$(readlink /var/cache/omada-controller/home/properties)" = /var/lib/omada-controller/properties'
    )

    # Backup-completeness guard: after a full startup the controller must write
    # nothing at the OMADA_HOME top level beyond these known entries — anything
    # else would be state living outside (and missing from) the backup.
    machine.succeed(
        "test -z \"$(ls /var/cache/omada-controller/home | grep -vxE 'bin|data|lib|logs|properties|work')\""
    )

    # Last, because it restarts the service: device icons the controller
    # downloads into data/static have to survive a restart. Its sync only
    # fetches templates newer than the version in MongoDB, which a restart
    # leaves untouched, so a wiped icon would never come back. A file of our own
    # stands in for a downloaded one.
    icon = "/var/lib/omada-controller/data/static/theme/img/topology/deviceicon/TEST-V1.png"
    machine.succeed(f"touch {icon}")
    machine.succeed("systemctl restart omada-controller")
    machine.wait_for_unit("omada-controller.service")
    machine.succeed(f"test -e {icon}")
    # The vendor's own icons are still refreshed from the package alongside it.
    machine.succeed(
        "test -e /var/lib/omada-controller/data/static/theme/img/virtualDeviceIcon/EAP-Bridge.png"
    )
  '';
}
