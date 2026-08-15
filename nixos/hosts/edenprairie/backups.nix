# Everything that leaves this box: NAS state backup, the Proton Drive offsite
# snapshots, the immich library copy, and the capacity metrics behind them.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../../../cluster.json);
  # From cluster.json so the backup jobs cannot drift apart: both YubiKey PIV
  # identities plus an offline key held only in the password manager.
  ageRecipientArgs = lib.concatMapStringsSep " " (r: "-r ${r}") cluster.backupRecipients;
in
{
  # Bootstrap credentials only: rclone rewrites its config in place with
  # cached session tokens, so agenix holds a SEED for a writable copy, never
  # the config rclone actually runs with. Two decrypted copies of the same
  # file because the immich job runs unprivileged and needs its own readable
  # path. To rotate credentials: replace the .age, deploy, then delete the
  # writable copies so the next run reseeds.
  age.secrets.rclone-proton.file = ../../../secrets/rclone-proton.age;
  age.secrets.rclone-proton-immich = {
    file = ../../../secrets/rclone-proton.age;
    owner = "immich";
    group = "immich";
  };

  fileSystems."/mnt/backups" = {
    device = "nas.infra.homelab.invalid:/volume1/longhorn-backups";
    fsType = "nfs";
    options = [
      "nfsvers=4.1"
      "sec=sys"
      "noatime"
      "hard"
      "intr"
      "nofail"
      "x-systemd.automount"
    ];
  };

  systemd.services.state-backup = {
    description = "Back up critical edenprairie state to NAS (age-encrypted)";
    after = [ "mnt-backups.mount" ];
    requires = [ "mnt-backups.mount" ];
    # Timer-driven oneshot, do not restart/wait on it during nixos-rebuild
    # activation (would block the switch on a long-running backup).
    restartIfChanged = false;
    # age-plugin-yubikey is needed to ENCRYPT to an age1yubikey1 recipient, not
    # just to decrypt. No YubiKey need be present, but the executable must.
    path = with pkgs; [
      gnutar
      gzip
      age
      age-plugin-yubikey
      coreutils
      findutils
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "state-backup" ''
        set -eu
        DEST="/mnt/backups/edenprairie-backup"
        DATE=$(date +%Y-%m-%d_%H%M%S)
        TMPFILE="/tmp/state-backup-$DATE.tar.gz"
        # Clean up the local scratch tar even if age/tar fails partway.
        trap 'rm -f "$TMPFILE"' EXIT

        mkdir -p "$DEST"

        # lldap runs as a DynamicUser: /var/lib/lldap is a symlink and only
        # the real path holds users.db. Bridge's vault.enc is useless without
        # .gnupg and .password-store, which hold the key that decrypts it.
        tar -C / -czf "$TMPFILE" \
          etc/step-ca/secrets \
          etc/step-ca/certs \
          etc/step-ca/config \
          etc/step-ca/password \
          etc/step-ca/k8s-provisioner-password \
          etc/step-ca/k8s \
          var/lib/krb5kdc \
          var/lib/private/lldap \
          var/lib/protonmail-bridge/.config \
          var/lib/protonmail-bridge/.gnupg \
          var/lib/protonmail-bridge/.password-store \
          var/lib/protonmail-bridge/certs \
          root/.config/rclone

        age ${ageRecipientArgs} -o "$DEST/edenprairie-state-$DATE.tar.gz.age" "$TMPFILE"

        find "$DEST" -name 'edenprairie-state-*.tar.gz.age' -mtime +30 -delete

        echo "Backup complete: $DEST/edenprairie-state-$DATE.tar.gz.age"
      '';
    };
  };

  systemd.timers.state-backup = {
    description = "Daily edenprairie state backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 08:45:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # Two layers of versioning: dated hardlink snapshot dirs on the NAS for
  # local point-in-time restores, and a restic repo on Proton for offsite.
  # Both keep 7 dailies plus weeklies to day 30.
  systemd.services.offsite-sync = {
    description = "Local backup snapshots + restic offsite to Proton Drive";
    after = [
      "mnt-backups.mount"
      "state-backup.service"
    ];
    requires = [ "mnt-backups.mount" ];
    # Timer-driven oneshot: a mid-run upload must never be able to hang
    # switch-to-configuration.
    restartIfChanged = false;
    path = with pkgs; [
      rclone
      restic
      rsync
      coreutils
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      Environment = "HOME=/root";
      CacheDirectory = "restic";
      ExecStart = pkgs.writeShellScript "offsite-sync" ''
        set -euo pipefail
        # protondrive-usage shares this rclone session, and Proton refresh
        # tokens are single-use: a concurrent refresh de-auths the other
        # process mid-run.
        exec 9>/run/proton-session.lock
        flock 9
        SRC=/mnt/backups
        VERS=/mnt/backups/versions
        TODAY=$(date +%Y-%m-%d)

        # Seed-if-missing, never overwrite: the live copy accumulates session
        # tokens, and reseeding would force a fresh Proton login every run.
        if [ ! -f /root/.config/rclone/rclone.conf ]; then
          install -D -m 0600 ${config.age.secrets.rclone-proton.path} \
            /root/.config/rclone/rclone.conf
        fi

        # listremotes reads the config only. `lsd` needs the network, so
        # using it here would report an outage as "not configured".
        if ! rclone listremotes 2>/dev/null | grep -qx 'protondrive:'; then
          echo "ERROR: remote 'protondrive' missing even after the agenix seed" >&2
          exit 1
        fi
        if ! err=$(rclone lsd protondrive: 2>&1 >/dev/null); then
          echo "ERROR: remote 'protondrive' is configured but unreachable - rclone said:" >&2
          echo "       ''${err}" >&2
          exit 1
        fi
        mkdir -p "$VERS"

        # hardlink base = most recent prior snapshot (not today)
        PREV=$(ls -1 "$VERS" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
               | grep -v "^$TODAY$" | sort | tail -1 || true)
        LINK=""; [ -n "$PREV" ] && LINK="--link-dest=$VERS/$PREV"
        echo "Snapshot $TODAY (hardlink base: ''${PREV:-none})"
        rsync -a --delete \
          --exclude='/versions/' --exclude='/#recycle/' --exclude='@eaDir' \
          $LINK "$SRC/" "$VERS/$TODAY/"

        # retention: keep last 7 daily + newest per ISO week for days 8-30
        NOW=$(date +%s); SEEN_WEEKS=""
        for d in $(ls -1 "$VERS" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r); do
          ts=$(date -d "$d" +%s 2>/dev/null) || continue
          age=$(( (NOW - ts) / 86400 ))
          if [ "$age" -le 6 ]; then
            :                                   # daily tier - keep
          elif [ "$age" -le 30 ]; then
            wk=$(date -d "$d" +%G-%V)
            case " $SEEN_WEEKS " in
              *" $wk "*) echo "prune $d (week $wk already kept)"; rm -rf "''${VERS:?}/$d" ;;
              *) SEEN_WEEKS="$SEEN_WEEKS $wk" ;; # weekly tier - newest in week, keep
            esac
          else
            echo "prune $d (>30 days)"; rm -rf "''${VERS:?}/$d"
          fi
        done

        # restic, not tar+copy: the tree barely changes day to day, so the
        # nightly upload is a delta. Packs land as ~16MB objects, which Proton
        # can stomach where the raw ~500k-file tree cannot. Also the only
        # client-side encryption the Longhorn blocks get.
        export RESTIC_PASSWORD_FILE=${config.age.secrets.restic-offsite.path}
        export RESTIC_CACHE_DIR=/var/cache/restic
        RREPO="rclone:protondrive:backups/restic"
        # An upload proton interrupts leaves an invisible draft that blocks
        # the name; rclone's retry of the same pack then 422s on it. The flag
        # makes the retry replace the draft.
        ROPT=(-o "rclone.args=serve restic --stdio --protondrive-replace-existing-draft")
        restic -r "$RREPO" "''${ROPT[@]}" cat config >/dev/null 2>&1 \
          || restic -r "$RREPO" "''${ROPT[@]}" init
        echo "Uploading with restic..."
        restic -r "$RREPO" "''${ROPT[@]}" backup "$SRC" \
          --exclude "$VERS" \
          --exclude '#recycle' --exclude '@eaDir'

        # Same retention shape as the local tree: a week of dailies, then
        # weeklies out to a month.
        restic -r "$RREPO" "''${ROPT[@]}" forget --keep-daily 7 --keep-weekly 4 --prune
        restic -r "$RREPO" "''${ROPT[@]}" check
        # "did not fail" is not "reached Proton": a run killed at
        # TimeoutStartSec leaves no failed unit behind. Alert on staleness.
        PROM_DIR=/var/lib/node-exporter-textfile
        TMP=$(mktemp "$PROM_DIR/.offsite-sync.XXXXXX")
        printf 'offsite_sync_last_success_timestamp_seconds %s\n' "$(date +%s)" > "$TMP"
        chmod 0644 "$TMP" && mv -f "$TMP" "$PROM_DIR/offsite-sync.prom"

        echo "Offsite versioned sync complete"
      '';
      TimeoutStartSec = "8h";
    };
  };

  # Does not list the remote: ~500k objects against a rate-limited backend.
  # `rclone about` gives the total in one call; the per-directory breakdown is
  # measured locally. The CSV outlives Prometheus's 7-day retention.
  systemd.services.protondrive-usage = {
    description = "Record Proton Drive usage and backup tree sizes";
    after = [ "mnt-backups.mount" ];
    requires = [ "mnt-backups.mount" ];
    restartIfChanged = false;
    path = with pkgs; [
      rclone
      coreutils
      findutils
      gawk
      jq
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      Environment = "HOME=/root";
      TimeoutStartSec = "30min";
      ExecStart = pkgs.writeShellScript "protondrive-usage" ''
        set -uo pipefail
        # Never share the proton session with a running offsite-sync (see
        # there). Skipping is fine: ProtonDriveUsageStale allows 36h.
        exec 9>/run/proton-session.lock
        if ! flock -n 9; then
          echo "proton session in use (offsite-sync running); skipping"
          exit 0
        fi
        PROM_DIR=/var/lib/node-exporter-textfile
        HIST=/var/lib/protondrive-usage/history.csv
        TMP=$(mktemp "$PROM_DIR/protondrive.prom.XXXXXX")
        trap 'rm -f "$TMP"' EXIT
        TS=$(date +%s); DATE=$(date +%Y-%m-%d)
        ok=1

        emit() { printf '%s\n' "$1" >> "$TMP"; }
        emit "# HELP protondrive_quota_bytes Total Proton Drive quota."
        emit "# TYPE protondrive_quota_bytes gauge"
        emit "# HELP protondrive_used_bytes Bytes used on Proton Drive."
        emit "# TYPE protondrive_used_bytes gauge"
        emit "# HELP protondrive_free_bytes Bytes free on Proton Drive."
        emit "# TYPE protondrive_free_bytes gauge"

        # one api call. --json gives bytes, avoiding the human-readable units.
        if about=$(rclone about protondrive: --json --tpslimit 2 2>/dev/null); then
          # // empty: a missing field must yield "", which the -n check below
          # treats as failure.
          jnum() { printf '%s' "$about" | jq -r ".$1 // empty"; }
          total=$(jnum total); used=$(jnum used); free=$(jnum free)
          if [ -n "''${total:-}" ]; then
            emit "protondrive_quota_bytes ''${total}"
            emit "protondrive_used_bytes ''${used:-0}"
            emit "protondrive_free_bytes ''${free:-0}"
          else
            ok=0
          fi
        else
          echo "WARN: rclone about failed" >&2; ok=0
        fi

        # versions/ excluded: it holds the retained snapshots and would
        # double-count everything.
        emit "# HELP backup_tree_bytes Size of a top-level backup source directory."
        emit "# TYPE backup_tree_bytes gauge"
        src_total=0
        for d in /mnt/backups/*/; do
          name=$(basename "$d")
          case "$name" in versions|'#recycle') continue ;; esac
          sz=$(du -sb "$d" 2>/dev/null | awk '{print $1}')
          [ -n "''${sz:-}" ] || continue
          emit "backup_tree_bytes{dir=\"''${name}\"} ''${sz}"
          src_total=$(( src_total + sz ))
        done
        emit "# HELP backup_source_total_bytes Total source tree, i.e. cost of one snapshot."
        emit "# TYPE backup_source_total_bytes gauge"
        emit "backup_source_total_bytes ''${src_total}"

        snaps=$(find /mnt/backups/versions -maxdepth 1 -type d -name '20*-*-*' 2>/dev/null | wc -l)
        emit "# HELP backup_snapshots_retained Number of dated snapshots kept."
        emit "# TYPE backup_snapshots_retained gauge"
        emit "backup_snapshots_retained ''${snaps}"
        emit "# HELP protondrive_usage_last_success_timestamp_seconds Last successful run."
        emit "# TYPE protondrive_usage_last_success_timestamp_seconds gauge"
        [ "$ok" = 1 ] && emit "protondrive_usage_last_success_timestamp_seconds ''${TS}"

        # Atomic publish: node-exporter must never read a half-written file.
        chmod 0644 "$TMP" && mv -f "$TMP" "$PROM_DIR/protondrive.prom"
        trap - EXIT

        [ -f "$HIST" ] || echo "date,proton_used_bytes,proton_free_bytes,source_total_bytes,snapshots" > "$HIST"
        echo "''${DATE},''${used:-},''${free:-},''${src_total},''${snaps}" >> "$HIST"
        echo "recorded: used=''${used:-?} free=''${free:-?} source=''${src_total} snapshots=''${snaps}"
      '';
    };
  };

  systemd.timers.protondrive-usage = {
    description = "Daily Proton Drive usage snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 09:45:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  systemd.timers.offsite-sync = {
    description = "Daily offsite backup sync to Proton Drive";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 09:00:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # Irreplaceable photos, so the whole library stays synced rather than
  # snapshotted. `rclone copy`, never sync or --delete: if the NAS source is
  # emptied the Proton copy must not follow.
  # A local uid, because this host cannot be an LDAP client - it IS the LDAP
  # server - so NFSv4 idmapping has nothing to resolve against.
  users.groups.immich = {
    gid = 11003;
  };
  users.users.immich = {
    isSystemUser = true;
    uid = 11003;
    group = "immich";
    description = "Local identity for NFSv4 idmapping of the immich@HOMELAB.INVALID krb5 principal (offsite-sync only, not used by any real login)";
  };

  fileSystems."/mnt/immich" = {
    device = "nas.infra.homelab.invalid:/volume1/immich";
    fsType = "nfs";
    # ro: this host only reads the library to push it offsite, so it must not
    # be a path by which it could delete the live one.
    options = [
      "nfsvers=4.1"
      "sec=krb5p"
      "ro"
      "noatime"
      "hard"
      "intr"
      "nofail"
      "x-systemd.automount"
    ];
  };

  services.nfsKrb5Ccache.enable = true;
  services.nfsKrb5Ccache.credentials = [
    {
      uid = 11003;
      principal = "immich@HOMELAB.INVALID";
      keytab = "/etc/krb5.immich.keytab";
    }
  ];

  systemd.tmpfiles.rules = [
    # node-exporter textfile collector + the usage tracker's history file
    "d /var/lib/node-exporter-textfile 0755 root root -"
    "d /var/lib/protondrive-usage 0755 root root -"
    # Holds only the last connectivity state, so the watchdog can log
    # transitions instead of a line every minute.
    "d /var/lib/wan-watchdog 0755 root root -"
  ];

  systemd.services.immich-offsite-sync = {
    description = "Copy (never delete) the Immich photo library to Proton Drive";
    after = [ "mnt-immich.mount" ];
    requires = [ "mnt-immich.mount" ];
    restartIfChanged = false;
    path = with pkgs; [
      rclone
      coreutils
      curl
      gawk
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "immich";
      Environment = "HOME=/var/lib/immich-offsite-sync";
      StateDirectory = "immich-offsite-sync";
      ExecStart = pkgs.writeShellScript "immich-offsite-sync" ''
        set -euo pipefail
        # rclone rewrites its config atomically, so the DIRECTORY must be
        # writable or refreshed tokens are never persisted. Seed-if-missing,
        # never overwrite: the state copy accumulates session tokens.
        CONF="$STATE_DIRECTORY/rclone.conf"
        if [ ! -f "$CONF" ]; then
          install -m 0600 ${config.age.secrets.rclone-proton-immich.path} "$CONF"
        fi

        # "not configured" and "cannot reach it" are different failures and
        # must not share a message. listremotes reads the config only.
        if ! rclone --config "$CONF" listremotes 2>/dev/null | grep -qx 'protondrive:'; then
          echo "ERROR: remote 'protondrive' missing even after the agenix seed" >&2
          exit 1
        fi
        # Print what rclone actually said rather than inventing a cause.
        if ! err=$(rclone --config "$CONF" lsd protondrive: 2>&1 >/dev/null); then
          echo "ERROR: remote 'protondrive' is configured but unreachable - rclone said:" >&2
          echo "       ''${err}" >&2
          exit 1
        fi
        # A full-tree `rclone copy` lists the remote recursively every run, which
        # Proton's per-folder API makes take 20-45 minutes. Track synced files
        # by mtime and hand rclone only the changed ones. The marker is RUN
        # START, so a file created mid-run is caught by the next one.
        MARKER="$STATE_DIRECTORY/last-successful-sync"
        FILELIST="$STATE_DIRECTORY/pending-files.txt"
        ALLFILES="$STATE_DIRECTORY/all-files.txt"
        LAST_TOTAL_FILE="$STATE_DIRECTORY/last-total-count"
        RUN_START=$(date +%s)
        # `|| true`: find exits nonzero on any directory it cannot descend into
        # while still writing everything else. One pass so the check below
        # cannot be fooled by a second, inconsistent traversal.
        find /mnt/immich -type f -not -path '*/#recycle/*' -printf '%T@ %P\n' 2>/dev/null > "$ALLFILES" || true
        TOTAL=$(wc -l < "$ALLFILES")
        if [ -e "$MARKER" ]; then
          MARKER_EPOCH=$(stat -c %Y "$MARKER")
          awk -v m="$MARKER_EPOCH" '$1+0 > m {sub(/^[^ ]+ /,""); print}' "$ALLFILES" > "$FILELIST"
        else
          echo "No prior marker - first run, treating entire library as pending"
          awk '{sub(/^[^ ]+ /,""); print}' "$ALLFILES" > "$FILELIST"
        fi
        COUNT=$(wc -l < "$FILELIST")
        echo "Copying $COUNT new/changed file(s) to Proton Drive (copy-only, no deletes)... (library total: $TOTAL)"

        # Catches "0 new files" while the library grew, a wrong marker would
        # otherwise ping healthchecks.io as a false success.
        if [ -e "$LAST_TOTAL_FILE" ] && [ "$COUNT" -eq 0 ] && [ "$TOTAL" -gt "$(cat "$LAST_TOTAL_FILE")" ]; then
          echo "ERROR: library grew from $(cat "$LAST_TOTAL_FILE") to $TOTAL files but 0 were detected as new/changed - marker or clock logic may be broken. Refusing to report success." >&2
          exit 1
        fi

        RCLONE_EXIT=0
        if [ "$COUNT" -gt 0 ]; then
          rclone --config "$CONF" copy /mnt/immich protondrive:immich-library \
            --files-from "$FILELIST" \
            --transfers 2 --checkers 4 --stats-one-line --stats 30s --log-level INFO || RCLONE_EXIT=$?
        fi

        # Advance the marker only on a fully clean run: rclone exits nonzero if
        # any single file fails, which Proton does routinely. Copy-only makes
        # that safe - whatever failed is included again next run.
        if [ "$RCLONE_EXIT" -eq 0 ]; then
          touch -d "@$RUN_START" "$MARKER"
          echo "$TOTAL" > "$LAST_TOTAL_FILE"
        else
          echo "WARNING: rclone exited $RCLONE_EXIT (some files likely failed transiently) - marker not advanced, same files retried next run"
        fi
        echo "Immich offsite copy complete"

        # Ping only on success, so healthchecks.io notices the silence. The else
        # branch matters: a ping skipped for an unreadable key must say so.
        if [ -r /etc/healthchecks-ping-key ]; then
          curl -fsS -m10 -o /dev/null "https://hc-ping.com/$(cat /etc/healthchecks-ping-key)/immich-backup?create=1" \
            || echo "WARNING: healthchecks ping FAILED (check will go down)" >&2
        else
          echo "WARNING: /etc/healthchecks-ping-key unreadable by $(id -un) - ping SKIPPED" >&2
        fi
      '';
      TimeoutStartSec = "8h";
    };
  };

  systemd.timers.immich-offsite-sync = {
    description = "Periodic Immich library offsite copy to Proton Drive";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # inotify does not propagate cross-client NFS changes and immich writes
      # from a pod, so polling is the substitute.
      OnCalendar = "*:0/5";
      Persistent = true;
      RandomizedDelaySec = "2m";
    };
  };

  age.secrets.restic-offsite = {
    file = ../../../secrets/restic-offsite.age;
  };

  # group immich, not root: immich-offsite-sync reads this as User=immich.
  age.secrets.healthchecks-ping-key = {
    file = ../../../secrets/healthchecks-ping-key.age;
    path = "/etc/healthchecks-ping-key";
    owner = "root";
    group = "immich";
    mode = "0440";
  };
}
