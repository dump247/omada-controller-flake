# omada-controller-flake

A NixOS flake that runs the [TP-Link Omada SDN Controller][omada] as a native
systemd service — the official vendor build, not a third-party Docker image.
Omada is TP-Link's controller for their Omada access points, switches, and
gateways: you use it to adopt and configure those devices, monitor the network,
and run guest/captive-portal networks from one place.

**x86_64-linux only.** TP-Link publishes the controller solely as an x86_64
Linux build (there is no official aarch64 release), so this flake packages that
binary and targets `x86_64-linux` exclusively.

---

# Using the flake

## Setup

```nix
{
  inputs.omada.url = "github:dump247/omada-controller-flake";

  outputs = { nixpkgs, omada, ... }: {
    nixosConfigurations.router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        omada.nixosModules.default
        {
          nixpkgs.config.allowUnfree = true;   # see "Unfree" below
          services.omada-controller.enable = true;
        }
      ];
    };
  };
}
```

The web UI is then on `https://<host>:8043` (first launch runs a setup wizard).

## What it runs, and what that means for you

- **Omada SDN Controller 6.2.14.11** — the official vendor build, fetched from
  `static.tp-link.com` and run natively (no container).
- **OpenJDK 17** — the version TP-Link documents (the release `readme.txt` says
  it "supports Java 17"; the installer requires Java ≥ 17).
- **MongoDB 8** (`mongodb-ce`) — the controller launches and manages its own
  `mongod`; there is no separate MongoDB service to configure.

**Unfree.** The vendor build (`omada-controller`) and MongoDB 8 (`mongodb-ce`)
are unfree. Either set `nixpkgs.config.allowUnfree = true`, or allow just these
two:

```nix
nixpkgs.config.allowUnfreePredicate =
  pkg: builtins.elem (lib.getName pkg) [ "omada-controller" "mongodb-ce" ];
```

**MongoDB 8 needs AVX.** Its prebuilt binaries require an AVX-capable CPU. On
older hardware, swap to the source-built Mongo 7:

```nix
services.omada-controller.package =
  pkgs.omada-controller.override { mongodbPackage = pkgs.mongodb-7_0; };
```

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Run the controller. |
| `stateDir` | `/var/lib/omada-controller` | Read-only. Where all mutable state lives; the one directory to back up. |
| `user` / `group` | `omada` | Service account that owns the state. |
| `package` | vendor build | Override to change the MongoDB engine, etc. |

## Ports & firewall

The flake does **not** touch your firewall; open what you need yourself
(`networking.firewall`), since the right exposure is deployment-specific. These
match TP-Link's [port list for Controller 5.0.15+][ports]; they fall into two
groups:

**Management UI** — for admins reaching the controller:

| Port | Proto | Purpose |
| --- | --- | --- |
| 8088 | TCP | Management HTTP |
| 8043 | TCP | Management HTTPS (web UI) |

**Devices & guest clients** — for APs/switches to be adopted/managed and for the
captive portal:

| Port | Proto | Purpose |
| --- | --- | --- |
| 8843 | TCP | Guest portal HTTPS |
| 29811 | TCP | Manager v1 |
| 29812 | TCP | Adopt v1 |
| 29813 | TCP | Upgrade v1 |
| 29814 | TCP | Manager v2 |
| 29815 | TCP | Transfer v2 |
| 29816 | TCP | RTTY (remote access) |
| 29817 | TCP | Device monitor |
| 27001 | UDP | App (Omada app) discovery |
| 29810 | UDP | Device discovery |
| 19810 | UDP | OLT discovery, only if you run TP-Link GPON OLTs[^olt] |

[^olt]: 19810 is the factory discovery port on Omada OLTs, used when the
    controller adopts one on the same L2 segment. An OLT adopted across layer 3
    via an inform URL uses 29810 instead unless the URL sets `dPort`. If you
    have no OLTs, skip this port.

These are the **defaults**; the management/portal ports can be changed in the UI
(Settings → Controller); if you do, adjust your firewall to match.

When scoping the firewall, note that **device adoption needs layer-2
reachability**: the management ports can live on any interface (e.g. restrict
them to `tailscale0` for remote admin), but the device ports must be reachable
by the APs/switches on your LAN; a virtual overlay like Tailscale won't carry
L2 discovery. For example, device ports on the LAN with the UI over Tailscale:

```nix
networking.firewall.interfaces = {
  lan0.allowedTCPPorts = [ 8843 29811 29812 29813 29814 29815 29816 29817 ];
  lan0.allowedUDPPorts = [ 27001 29810 ];
  tailscale0.allowedTCPPorts = [ 8088 8043 ];
};
```

### Reverse proxy (admin UI)

If you front the admin UI with a reverse proxy, give it a **dedicated subdomain
served at the root path** (`https://omada.example.com/`). A **subpath does not
work** (`https://example.com/omada/`): the UI has no base-path/context setting,
uses absolute asset paths, and injects a per-instance controller ID into its
URLs, so assets, redirects, and WebSockets all escape the prefix.

Proxy to the controller's **HTTPS port (8043)**, not the HTTP port: 8088
redirects to HTTPS unconditionally (a Jetty connector-level redirect that
ignores `X-Forwarded-Proto`), so proxying to it just loops. The controller's own
cert is self-signed, so have the proxy skip backend cert verification.

Route only the admin UI through the proxy; adopted APs/switches should reach
the controller directly at its LAN address.

## Backups

Everything the controller persists lives under `stateDir`
(`/var/lib/omada-controller`). **Back up that one directory. No exclude list is
needed;** regenerable data is kept out of it automatically. To put it on its own
btrfs subvolume or ZFS dataset for cheap snapshots, mount that at
`/var/lib/omada-controller` — the path itself is fixed.

There are three ways to capture it. Any one of them is enough; only the first
requires stopping the service.

### Copy the files (stop the service first)

⚠️ **A file-by-file copy — `rsync`, `restic`, `cp`, `tar` — must run with the
service stopped.** The embedded MongoDB writes its data files continuously, and
per the [MongoDB manual][mdb], *"since copying multiple files is not an atomic
operation, you must stop all writes to the `mongod` before copying the files."*
Copying a live `stateDir` can capture a torn database that won't restore.

So: `systemctl stop omada-controller` → copy `stateDir` → `systemctl start …`.
The controller is down for the length of the copy. A restic example:

```nix
{ config, pkgs, ... }:
{
  services.restic.backups.omada = {
    # Reference the option rather than hardcoding the path.
    paths = [ config.services.omada-controller.stateDir ];
    repository = "s3:s3.amazonaws.com/my-bucket/omada";
    passwordFile = "/run/secrets/omada-restic-password";
    timerConfig.OnCalendar = "daily";
    # Quiesce MongoDB for a clean file-level copy.
    backupPrepareCommand = "${pkgs.systemd}/bin/systemctl stop omada-controller";
    backupCleanupCommand = "${pkgs.systemd}/bin/systemctl start omada-controller";
  };
}
```

### Snapshot the filesystem (no stop needed)

An atomic btrfs/ZFS/LVM snapshot of `stateDir` is safe on a running controller:
the snapshot *is* the atomic operation the warning above asks for. MongoDB
supports this when [journaling is enabled and the journal is on the same volume
as the data][snap], both true here.

It has to be a real snapshot, not a file copy dressed up as one — and back up
the snapshot afterwards, not the live directory.

### Let Omada back itself up (no stop needed)

Enable Auto Backup in the UI (Settings → Maintenance). The controller writes its
own consistent `.cfg` exports under `stateDir`, so there's no external copy to
get wrong, and importing one is a first-class Omada restore. Each `.cfg` is
complete once written, so it survives even a live file copy of `stateDir`.

This pairs well with either option above: it gives you a restore path that
doesn't depend on the surrounding `stateDir` copy being sound.

### Restoring

The two kinds of backup restore differently:

- **A `stateDir` copy or snapshot** — stop the service, put `stateDir/` back as
  it was, start it again. The controller comes up as it was at backup time.
- **An Auto Backup `.cfg`** — don't restore `stateDir`. Start the controller
  with an empty one, and at the setup wizard choose to restore from a backup
  file and upload the `.cfg`. The only thing you need out of your backup is that
  one file, from `stateDir/data/autobackup/`.

## Trying it in a VM

```sh
just vm        # boot the example VM interactively; open https://localhost:8043
```

A throwaway VM running the example config, with the UI forwarded to your
`localhost`. It adapts to the host: native `nix` if present, otherwise inside
podman (see [Developing](#developing-the-flake)).

---

# Developing the flake

Everything below is about how the flake is built. You don't need it to *use* the
flake.

## How the controller is wired up

Omada ships as a relocatable Java app launched via the vendor's `jsvc` (Apache
Commons Daemon). A systemd unit runs `jsvc` directly in the foreground. Nothing
reaches the system `PATH`: the package installs everything under
`$out/share/omada-controller` and ships **nothing** in `$out/bin`, so the
launchers never leak into user shells. The controller starts its own `mongod`
(found under `OMADA_HOME/bin` or on `PATH`); there is no separate mongod
service.

The subtle part is where `OMADA_HOME` lives, and it drives the backup design:

- **`OMADA_HOME` is *not* `stateDir`.** The controller derives `OMADA_HOME` from
  the **canonical filesystem location of its JARs**, then resolves `../properties`
  and `../data` against it. So the JARs must physically sit under `OMADA_HOME`,
  and `OMADA_HOME/properties` must be writable (the controller rewrites ports
  there). The JARs are ~307 MB, too big to want in every backup.
- **So `OMADA_HOME` = `/var/cache/omada-controller/home`** (not backed up),
  assembled fresh each start by `ExecStartPre`. Its `lib/` is **hardlinked** from
  the store: a hardlink has no separate canonical target (unlike a symlink,
  which canonicalizes back to the read-only store and makes the controller look
  for a writable `omada.properties` in `/nix/store` and fail). Hardlinks share
  the store's blocks (no extra disk) and the JARs keep the store's root ownership
  (never `chown`ed, since they share its inodes).
- **`stateDir` holds only real state.** `OMADA_HOME/data` and
  `OMADA_HOME/properties` are symlinks back into `stateDir`, so the controller
  writes the database and config straight into the backup target; `logs`/`work`
  symlink out to `/var/log` and `/var/cache` (systemd `LogsDirectory`/
  `CacheDirectory`). The integration test asserts nothing lands at the
  `OMADA_HOME` top level beyond the known entries, guarding against state
  escaping the backup.

```
/var/lib/omada-controller/            <- stateDir: the backup target (state only)
├── data/db/                          <- MongoDB database (the important state)
├── data/keystore/  data/autobackup/  data/html/  ...
└── properties/                       <- seeded once; controller rewrites ports here

/var/cache/omada-controller/home/     <- OMADA_HOME: regenerable, NOT backed up
├── lib/                              <- 307 MB of JARs, hardlinked from the store
├── bin/mongod, bin/mongosh           <- symlinks the controller expects
├── data       -> /var/lib/omada-controller/data          <- writes into the backup
├── properties -> /var/lib/omada-controller/properties
├── logs       -> /var/log/omada-controller
└── work       -> /var/cache/omada-controller/work
```

## Updating the Omada version

The version/url/hash are pinned in `pkgs/omada-source.json`. Bump them with:

```sh
just update-omada https://static.tp-link.com/.../Omada_SDN_Controller_vX.Y.Z_linux_x64.tar.gz
```

It derives the version from the filename, downloads the tarball to compute its
hash, and rewrites the JSON. Canonical URLs come from the [TP-Link download
page][omada] and the mbentley "new version" tracker issues. **Back up `stateDir`
(or take an Omada Auto Backup) before a major upgrade**: Omada migrates its
database in place on first boot.

## Tooling

All recipes go through [`scripts/nix.sh`](scripts/nix.sh), so the flake can be
developed from a host without Nix installed: it uses a native `nix` when present
and otherwise runs nix inside podman. Useful recipes:

```sh
just doctor        # show which backend (native nix / podman) is in use
just check         # nix flake check — evaluate the flake and build every check
just test          # build only the VM integration test
just build-omada   # build just the package (nix build .#omada-controller)
just update-omada  # bump the pinned Omada release
```

## Why not nixpkgs?

There is no Omada controller in nixpkgs. The one open PR
([NixOS/nixpkgs#345652][pr]) has been a draft since Oct 2024, still carries an
unresolved merge conflict, targets an older Omada (5.15) + Mongo 7, and exposes
the launcher on `PATH`. It may land eventually; until then this flake tracks the
current release. Other prior art is personal repos (goertzenator's abandoned 4.x
module, BBBSnowball's package-only `nixcfg`).

---

# License

The flake itself — the Nix expressions, NixOS module, and tests in this repo —
is [MIT licensed](LICENSE).

That covers only the packaging. **The Omada SDN Controller it downloads is
proprietary TP-Link software**, redistributed by nobody here: the package fetches
the vendor tarball straight from `static.tp-link.com` at build time, and your use
of it is governed by TP-Link's own license terms (`EULA.txt` in the tarball), not
by the MIT license above. That is why the package is marked
`lib.licenses.unfree` and needs `allowUnfree` (see [Unfree](#what-it-runs-and-what-that-means-for-you)).
MongoDB 8 (`mongodb-ce`, SSPL) is likewise unfree and separately licensed.

[omada]: https://support.omadanetworks.com/us/product/omada-software-controller/
[ports]: https://support.omadanetworks.com/us/document/13090/
[pr]: https://github.com/NixOS/nixpkgs/pull/345652
[mdb]: https://www.mongodb.com/docs/manual/core/backups/
[snap]: https://www.mongodb.com/docs/manual/tutorial/backup-with-filesystem-snapshots/
