{
  pkgs,
  module,
  package,
  ...
}:

# End-to-end VM test: boot a NixOS guest with the controller enabled, wait for
# the service and its embedded MongoDB to come up, and assert the management UI
# answers on :8043. Also verifies the single-state-dir layout.
#
# Heavy: pulls the vendor tarball and the MongoDB closure, and Omada's first
# boot (Mongo init + schema setup) takes a few minutes — hence the large VM and
# long timeouts.
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
    print(machine.execute("systemctl status omada-controller --no-pager -l || true")[1])
    print(machine.execute("ls -la /var/log/omada-controller/ || true")[1])
    print(machine.execute(
        'for f in /var/log/omada-controller/*.log; do echo "### $f"; tail -n 120 "$f"; done 2>&1 || true'
    )[1])

    # The unit is active only once the controller answers, so this has no retry.
    machine.succeed("curl -fs -I http://localhost:8088/actuator/linux/check -o /dev/null")
    machine.wait_until_succeeds("curl -fsk https://localhost:8043 -o /dev/null", timeout=60)

    # Every TCP port the README's firewall section lists.
    for port in (8043, 8044, 8088, 8843, 29811, 29812, 29813, 29814, 29815, 29816, 29817):
        machine.wait_for_open_port(port, timeout=60)

    # mongod should be running as a child of the controller, owned by omada.
    machine.succeed("pgrep -u omada mongod")

    # --- storage layout / backup contract ---
    # stateDir (the backup target) holds only real state — the jars are NOT in it.
    machine.succeed("test -e /var/lib/omada-controller/data/db/WiredTiger")
    machine.succeed("test ! -L /var/lib/omada-controller/data/db")
    machine.succeed("test -e /var/lib/omada-controller/properties/omada.properties")
    machine.succeed("test ! -e /var/lib/omada-controller/lib")

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

    # Runs after two starts, so the controller has run ps and arch by now.
    machine.fail("grep 'Cannot run program' /var/log/omada-controller/server.log")

    # OMADA_HOME is in the read-only store, so state aimed anywhere but its symlinks
    # fails with one of these.
    machine.fail(
        "grep -E 'Read-only file system|Permission denied' /var/log/omada-controller/server.log"
    )
  '';
}
