# Rotate the bridge password: wipe vault.enc (nothing less changes it),
# re-login, propagate to the six holders as SOPS files. The wipe also resets
# listen ports and the TLS cert pointer; the script re-fixes both.
{
  pkgs,
  cluster,
  mkApp,
}:
mkApp {
  name = "protonmail-bridge-setup";
  runtimeInputs = [
    pkgs.openssh
    pkgs.sops
    pkgs.coreutils
    pkgs.gnused
  ];
  excludeShellChecks = [ "SC2029" ];
  text = ''

    HOST="root@${cluster.infra.edenprairie}"
    BRIDGE_ENV="HOME=/var/lib/protonmail-bridge GNUPGHOME=/var/lib/protonmail-bridge/.gnupg PASSWORD_STORE_DIR=/var/lib/protonmail-bridge/.password-store PATH=\$PATH:/run/current-system/sw/bin"
    BRIDGE="sudo -u protonmail-bridge env $BRIDGE_ENV protonmail-bridge"

    # Fail early rather than after the interactive login: without the SOPS
    # private key the authelia edit cannot happen, and a partial propagation
    # is worse than none.
    if ! sops -d k8s/authelia/secret.yaml >/dev/null 2>&1; then
      echo "Cannot decrypt k8s/authelia/secret.yaml." >&2
      echo "Put the SOPS age key at ~/Library/Application Support/sops/age/keys.txt" >&2
      echo "(macOS location - sops does NOT read ~/.config/sops on darwin)," >&2
      echo "or set SOPS_AGE_KEY_FILE. Aborting before touching the bridge." >&2
      exit 1
    fi

    ssh -o ConnectTimeout=5 "$HOST" "systemctl stop protonmail-bridge; pkill -u protonmail-bridge 2>/dev/null; sleep 1; rm -f /var/lib/protonmail-bridge/.cache/protonmail/bridge-v3/bridge-v3.lock" || true

    echo ""
    echo "==> Interactive login. To ROTATE, run:  logout  then  login"
    echo "    Then:  exit"
    echo ""
    ssh -t "$HOST" "$BRIDGE --cli"

    echo ""
    # Retry the scrape: straight after a delete+login the account is still
    # syncing and `info` returns nothing, which would otherwise abort the
    # run before a single file is written.
    BRIDGE_PW=""
    for wait in 10 20 30; do
      BRIDGE_PW=$(ssh "$HOST" "{ sleep $wait; echo info; sleep 5; echo exit; } | $BRIDGE --cli 2>&1 | grep 'Password: ' | head -1 | sed 's/.*Password: //' | tr -d '[:space:]'" || true)
      [ -n "$BRIDGE_PW" ] && break
      echo "    no password yet (waited ''${wait}s) - account may still be syncing, retrying..."
    done

    # Fall back to asking rather than aborting. A failed scrape must not
    # leave the bridge rotated and every consumer holding the old password.
    if [ -z "$BRIDGE_PW" ]; then
      echo ""
      echo "Could not scrape the password automatically." >&2
      echo "Read it with:  ssh -t $HOST \"$BRIDGE --cli\"  then  info" >&2
      printf 'Paste the bridge password here (hidden): ' >&2
      read -rs BRIDGE_PW
      printf '\n' >&2
    fi
    if [ -z "$BRIDGE_PW" ]; then
      echo "Still empty. Nothing changed." >&2
      exit 1
    fi
    echo "    captured (sha $(printf '%s' "$BRIDGE_PW" | sha256sum | cut -c1-12))"

    # lldap on edenprairie (a host file, not in git)
    ssh "$HOST" "sed -i 's|^LLDAP_SMTP_OPTIONS__PASSWORD=.*|LLDAP_SMTP_OPTIONS__PASSWORD=$BRIDGE_PW|' /var/lib/lldap/private/lldap.env"
    echo "    updated lldap.env on edenprairie"

    # the four single-value SOPS files
    write_single() {
      path="$1"; ns="$2"; name="$3"
      {
        printf 'apiVersion: v1\n'
        printf 'kind: Secret\n'
        printf 'metadata:\n'
        printf '    name: %s\n' "$name"
        printf '    namespace: %s\n' "$ns"
        printf 'type: Opaque\n'
        printf 'stringData:\n'
        printf '    smtp-password: %s\n' "$BRIDGE_PW"
      } > "$path"
      sops -e -i "$path"
      grep -q 'smtp-password: ENC\[' "$path" || { echo "FAILED to encrypt $path" >&2; exit 1; }
      echo "    rewrote $path"
    }
    write_single k8s/diun/secret.yaml                         diun            smtp-secrets
    write_single k8s/longhorn/backup-notify-secret.yaml       longhorn-system backup-notify-smtp
    write_single k8s/monitoring/alertmanager-smtp-secret.yaml monitoring      alertmanager-smtp
    write_single k8s/plex/healthcheck-smtp-secret.yaml        plex            plex-healthcheck-smtp

    # authelia: one key inside a nine-key Secret
    # `data` (not stringData), so the value is base64 of the password.
    BRIDGE_PW_B64=$(printf '%s' "$BRIDGE_PW" | base64 | tr -d '\n')
    sops set k8s/authelia/secret.yaml '["data"]["smtp-password"]' "\"$BRIDGE_PW_B64\""
    echo "    updated smtp-password in k8s/authelia/secret.yaml"

    unset BRIDGE_PW BRIDGE_PW_B64

    echo ""
    ssh "$HOST" "systemctl start protonmail-bridge; systemctl restart lldap"
    sleep 3
    ssh "$HOST" "ss -tlnp | grep -E '1026|1144' || echo 'WARN: bridge ports not listening yet (account may still be syncing)'"

    echo ""
    echo "==> NOT APPLIED YET. The cluster still has the old password until"
    echo "    these land in git and Flux reconciles:"
    echo ""
    echo "      git add -A && git commit -m 'smtp: rotate protonmail bridge password' && git push"
    echo ""
    echo "    Then restart the consumers (a Secret change does not restart pods):"
    echo "      kubectl -n authelia rollout restart deployment authelia"
    echo "      kubectl -n diun rollout restart deployment diun"
  '';
}
