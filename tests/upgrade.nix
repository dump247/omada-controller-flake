{
  pkgs,
  lib,
  module,
  oldPackage,
  newPackage,
  ...
}:

# Boots the previous release, switches the running system to the newest, and
# asserts the controller returns on the state it migrated — then that the guards
# refuse to run backwards. The integration test always starts from an empty state
# dir, so this is the only coverage of inherited state. Heavy: two vendor
# tarballs, two first starts, two system closures in the guest.
pkgs.testers.runNixOSTest {
  name = "omada-controller-upgrade-${oldPackage.version}-to-${newPackage.version}";

  nodes.machine =
    { ... }:
    {
      imports = [ module ];

      # allowUnfree comes from the `pkgs` passed to runNixOSTest (see flake.nix).

      virtualisation = {
        memorySize = 4096;
        # Two Omada packages and two system closures, where the integration test
        # holds one of each.
        diskSize = 20480;
        cores = 2;
        # MongoDB 8's prebuilt binaries require AVX; QEMU's default CPU doesn't
        # expose it. `-cpu max` advertises AVX under both KVM and TCG.
        qemu.options = [ "-cpu max" ];
      };

      services.omada-controller = {
        enable = true;
        package = oldPackage;
      };

      # The upgrade target. A specialisation puts both systems in the guest store
      # at boot, so the switch needs no second boot and no network.
      specialisation.upgraded.configuration = {
        services.omada-controller.package = lib.mkForce newPackage;
      };
    };

  testScript = ''
    state = "/var/lib/omada-controller"
    mongo_marker = f"{state}/data/check-mongo/LAST_MAIN_VERSION.info"
    old, new = "${oldPackage.version}", "${newPackage.version}"

    def wait_for_ui():
        machine.wait_until_succeeds(
            "curl -fsk https://localhost:8043 -o /dev/null", timeout=600
        )

    with subtest(f"the previous release ({old}) comes up on an empty state dir"):
        machine.start()
        machine.wait_for_unit("omada-controller.service")
        wait_for_ui()
        machine.succeed(f"grep -qx {old} {state}/.omada-version")

    with subtest(f"upgrading to {new} keeps the same state dir"):
        machine.succeed(
            "/run/current-system/specialisation/upgraded/bin/switch-to-configuration test"
        )
        machine.wait_for_unit("omada-controller.service")
        machine.wait_until_succeeds(f"grep -qx {new} {state}/.omada-version")
        wait_for_ui()
        # The database is the one the old release created, not a fresh one.
        machine.succeed("pgrep -u omada mongod")

    with subtest("properties gains the keys the new release added"):
        # ExecStartPre seeds properties only when absent, so after an upgrade the
        # file is the old release's. The controller merges its shipped defaults
        # underneath; a key it needs and can't find is a startup exception.
        shipped = "${newPackage}/share/omada-controller/properties/omada.properties"
        machine.succeed(
            f"grep -oE '^[^#[:space:]=]+' {shipped} | sort -u > /tmp/shipped",
            f"grep -oE '^[^#[:space:]=]+' {state}/properties/omada.properties | sort -u > /tmp/live",
        )
        # An unparsed key list would make the comparison below pass on nothing.
        shipped_keys = int(machine.succeed("wc -l < /tmp/shipped"))
        assert shipped_keys > 20, f"only parsed {shipped_keys} keys out of {shipped}"
        missing = machine.succeed("comm -23 /tmp/shipped /tmp/live").strip()
        assert not missing, f"properties keys {new} ships are missing from the state file: {missing}"

    with subtest("a MongoDB release jump is refused"):
        # The recorded version is the guard's whole input, so rewriting it stages
        # the jump without building a second engine.
        machine.succeed("systemctl stop omada-controller.service")
        machine.succeed(f"cp {mongo_marker} /tmp/mongo-version")
        machine.succeed(f"echo 3.0.0 > {mongo_marker}")
        machine.fail("systemctl start omada-controller.service")
        machine.succeed(
            "journalctl -u omada-controller.service | grep -q 'refusing to start MongoDB'"
        )
        # ... and it was the only thing in the way.
        machine.succeed(f"cp /tmp/mongo-version {mongo_marker}")
        machine.succeed("systemctl start omada-controller.service")
        machine.wait_for_unit("omada-controller.service")

    with subtest(f"downgrading back to {old} is refused"):
        machine.succeed("systemctl stop omada-controller.service")
        # /run/booted-system is the system we started on: the old release.
        machine.execute("/run/booted-system/bin/switch-to-configuration test")
        machine.succeed("systemctl stop omada-controller.service")
        machine.fail("systemctl start omada-controller.service")
        machine.succeed(
            f"journalctl -u omada-controller.service | grep -q 'refusing to start Omada {old}'"
        )
        # The guard refuses before touching anything, so the state is still the
        # migrated one and the newer release can still be put back.
        machine.succeed(f"grep -qx {new} {state}/.omada-version")
        machine.succeed(f"test -d {state}/data/db")
  '';
}
