# 0. Prerequisites

- YubiKey or offline age key from the password manager
- Offsite backups
- Repo access
- A machine with git and nix

# 1. Recover the offsite data

The restic repo `rclone:protondrive:backups/restic` mirrors the NAS share
`longhorn-backups`:

- `edenprairie-backup/` - edenprairie state tars (age-encrypted): step-ca,
  Kerberos, lldap, protonmail-bridge, rclone session
- `secrets-backup/` - etcd snapshots (age-encrypted)
- `db-backup/` - mariadb, redis and immich-postgres dumps (age-encrypted)
- the Longhorn backupstore - volume data
- `versions/` is not in the repo; those are NAS-local hardlink snapshots

Decrypting with a YubiKey needs `age-plugin-yubikey` next to `age`
(`nix shell nixpkgs#age nixpkgs#age-plugin-yubikey`). The offline key works with
plain age.

```bash
# the rclone remote, from its bootstrap credentials in the repo
age -d -i <(nix run .#age-identity) secrets/rclone-proton.age > ~/.config/rclone/rclone.conf

# the restic password (also in the password manager)
age -d -i <(nix run .#age-identity) secrets/restic-offsite.age

restic -r rclone:protondrive:backups/restic snapshots
restic -r rclone:protondrive:backups/restic restore latest --target ./recovered
```

The immich photo library is a plain copy at `protondrive:immich-library`,
outside the restic repo.

# 2. edenprairie

Everything else depends on this host: it serves DNS, Kerberos and the internal
CA. Restore it first.

1. Install NixOS on the Pi (appendix below).
2. Restore its host key so it can decrypt its agenix secrets:
   `nix run .#restore-host-key -- edenprairie`
3. Deploy: `nix run .#deploy -- edenprairie`
4. Restore state: decrypt the newest `edenprairie-state-*.tar.gz.age`, then
   unpack it on the host with `tar -xzf - -C /`. It carries `/etc/step-ca`,
   `/var/lib/krb5kdc`, `/var/lib/private/lldap`, `/var/lib/protonmail-bridge`
   and `/root/.config/rclone`.
5. Restart the services:
   `systemctl restart step-ca kdc kadmind lldap protonmail-bridge dnsmasq`
6. Verify: `nix run .#restore-drill` compares the backup against the live host
   byte for byte.

# 3. NAS

1. Set up DSM and recreate the shares `data`, `immich` and `longhorn-backups`.
2. Join LDAP in DSM (ldap/README), then run `nix run .#nas-deploy`. That
   installs the root CA trust, the boot-restore script, node_exporter and the
   scheduler tasks.
3. Copy the photos back with
   `rclone copy protondrive:immich-library /volume1/immich`, and put the
   recovered `longhorn-backups` tree back on its share so Longhorn can restore
   volumes from it.

# 4. k8s nodes

1. Install NixOS (appendix below). For each node, run
   `nix run .#restore-host-key -- <node>`, then `nix run .#deploy -- <node>`.
2. Register each node in etcd with `nix run .#node-join -- <node-ip>`.
   k8s-pki-request issues all certificates from step-ca.
3. Choose one of two paths for cluster state. Either restore the newest etcd
   snapshot from `secrets-backup/` (`etcdctl snapshot restore` on one member,
   then rejoin the rest), or start empty and let Flux rebuild everything the
   repo declares, including every SOPS secret (the tunnel token, the Longhorn
   crypto key, the DB credentials). An empty start needs the SOPS key in the
   cluster first: `nix run .#push-secret` (flux/README covers the bootstrap
   layout).
4. Longhorn restores volumes from the NAS backupstore. Replay anything newer
   from the `db-backup/` dumps on top.

# 5. brainerd

`nix run .#brainerd-bootstrap` builds the image, applies the terraform, pushes
the credentials and closes ssh again. An IP change needs nothing at home;
wg-gateway re-resolves the hostname.

# 6. Verify

- cluster-healthcheck green
- alertmanager quiet, healthchecks.io all green
- `nix run .#restore-drill` clean against the first new state backup
- a test restore from the freshly reseeded restic repo

# Appendix: installing a host

## k8s node (x86)

With a running Linux on the target:

```bash
nixos-anywhere --flake .#<hostname> root@<target-ip>
```

From a NixOS minimal USB instead:

```bash
nix-shell -p git && git clone <repo> /tmp/nixos-config
nix run github:nix-community/disko -- --mode disko /tmp/nixos-config/nixos/hosts/k8s/<hostname>/disk-config.nix
nixos-generate-config --root /mnt --no-filesystems
nixos-install --flake /tmp/nixos-config#<hostname>
```

Afterwards: commit `hardware-configuration.nix`, join etcd with
`nix run .#node-join -- <node-ip>`, roll the node its NFS keytab with
`nix run .#kerberos-keytabs` (the principal appears via kdc-principals on the
next edenprairie deploy), and deploy. k8s-pki-request issues the node's
certificates on boot.

## Raspberry Pi 5 (edenprairie)

The Pi uses the `nixos-raspberrypi` flake input instead of `nixos-hardware`: the
standard NixOS kernel lacks RPi5 ethernet and firmware support. Build the
installer image first:

```bash
nix build github:nvmd/nixos-raspberrypi#installerImages.rpi5
```

1. Write the installer to a USB stick:
   ```bash
   zstdcat nixos-installer-rpi5.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
   ```
2. Boot the Pi from USB with no SD card inserted. The live system has SSH
   enabled; root password and IP are on the HDMI output. No HDMI: scan with
   `nmap -p 22 --open <lan-cidr>` and SSH in as root.
3. Partition the SD card from the installer:
   ```bash
   parted /dev/mmcblk0 -- mklabel msdos
   parted /dev/mmcblk0 -- mkpart primary fat32 1MiB 512MiB
   parted /dev/mmcblk0 -- set 1 boot on
   parted /dev/mmcblk0 -- mkpart primary ext4 512MiB 100%
   mkfs.vfat -n FIRMWARE /dev/mmcblk0p1
   mkfs.ext4 -L NIXOS_SD /dev/mmcblk0p2
   ```
4. Clone the USB installer onto the SD card, then grow the partition:
   ```bash
   sync && dd if=/dev/sda of=/dev/mmcblk0 bs=4M status=progress conv=fsync
   parted /dev/mmcblk0 resizepart 2 100%
   e2fsck -f /dev/mmcblk0p2
   resize2fs /dev/mmcblk0p2
   ```
   Clone, not `nixos-install`: the install path pulls the generic kernel without
   RPi5 ethernet drivers; dd preserves the installer's working one.
5. Shut down, remove the USB stick, boot from SD, SSH in as root.
6. Clone this repo and rebuild:
   ```bash
   nixos-rebuild switch --flake /path/to/repo#edenprairie
   ```
   If Nix reports a narHash mismatch on `nixos-raspberrypi`, pin its nixpkgs to
   yours in flake.nix:
   ```nix
   nixos-raspberrypi = {
     url = "github:nvmd/nixos-raspberrypi/main";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

An SD card failure is just these steps again; every bit of config lives in this
repo.
