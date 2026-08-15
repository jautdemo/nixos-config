# nix run .#nas-deploy
# Deploys DSM boot scripts, root CA, and scheduled tasks to the NAS.
# Pulls root CA from edenprairie at runtime, nothing sensitive stored in the repo.
# Fully automated: creates DSM Task Scheduler entries via esynoscheduler DB.
{
  pkgs,
  lib,
  cluster,
  mkApp,
}:
mkApp {
  name = "nas-deploy";
  runtimeInputs = [ pkgs.openssh ];
  text = ''
          NAS_HOST="${cluster.infra.nas}"
          NAS_PORT="${toString cluster.infra.nasSshPort}"
          NAS_USER="${cluster.infra.nasUser}"
          NAS_DEST="/volume1/data/scripts"
          EDENPRAIRIE="root@${cluster.infra.edenprairie}"

          # DSM's sshd doesn't support post-quantum KEX; use arrays so shellcheck is happy
          NAS_SSH=(ssh -p "$NAS_PORT" -o KexAlgorithms=-mlkem768x25519-sha256 "''${NAS_USER}@''${NAS_HOST}")
          ROOT_SSH=(ssh -p "$NAS_PORT" -o KexAlgorithms=-mlkem768x25519-sha256 "root@''${NAS_HOST}")
          NAS_SCP=(scp -O -P "$NAS_PORT" -o KexAlgorithms=-mlkem768x25519-sha256)

          echo "=== Deploying to NAS ==="

          TMPCA="$(mktemp)"
          trap 'rm -f "$TMPCA"' EXIT
          ssh -o ConnectTimeout=5 "$EDENPRAIRIE" "cat /etc/step-ca/certs/root_ca.crt" > "$TMPCA"
          "''${NAS_SSH[@]}" "cat > ''${NAS_DEST}/homelab-root-ca.crt" < "$TMPCA"

          "''${NAS_SCP[@]}" \
              "$REPO_ROOT/scripts/dsm/nas-boot-restore.sh" \
              "''${NAS_USER}@''${NAS_HOST}:''${NAS_DEST}/"

          SCHED_DB="/usr/syno/etc/esynoscheduler/esynoscheduler.db"
          "''${ROOT_SSH[@]}" "sqlite3 '$SCHED_DB' \"INSERT OR REPLACE INTO task (task_name, event, owner, enable, operation, operation_type, status, extra) VALUES
            ('nas-boot-restore', 'bootup', 0, 1, 'bash ''${NAS_DEST}/nas-boot-restore.sh', 'script', '{\\\"running\\\":[]}', '{}');\""

          echo "==> Running boot-restore..."
          "''${ROOT_SSH[@]}" "bash ''${NAS_DEST}/nas-boot-restore.sh"

          # Deploy SSH authorized_keys (last step, replaces keys used by earlier commands)
          echo "==> Deploying SSH keys..."
          "''${ROOT_SSH[@]}" "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" <<'KEYS'
    ${lib.concatStringsSep "\n" (lib.attrValues cluster.sshKeys)}
    KEYS

          echo ""
          echo "=== Deployment complete ==="
  '';
}
