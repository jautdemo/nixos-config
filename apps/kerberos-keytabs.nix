# nix run .#kerberos-keytabs
# Exports the Kerberos keytabs and distributes them to the k8s nodes and the
# NAS, plus the NAS-side krb5 config and export-security assertions. The
# realm database and principals are host state (kdc-genesis/kdc-principals
# on edenprairie); this app stays attended because ktadd bumps the key
# version - a re-run rolls every keytab and must be followed by exactly
# this distribution.
# Prerequisites: deploy edenprairie first (KDC active, principals ensured).
{
  pkgs,
  lib,
  cluster,
  mkApp,
}:
mkApp {
  name = "kerberos-keytabs";
  runtimeInputs = [
    pkgs.openssh
    pkgs.openssl
  ];
  excludeShellChecks = [ "SC2029" ];
  text = ''
          KDC="root@${cluster.infra.edenprairie}"
          NAS_HOST="${cluster.infra.nas}"
          NAS_PORT="${toString cluster.infra.nasSshPort}"
          REALM="HOMELAB.INVALID"
          SCRIPTS_DIR="/volume1/data/scripts"


          echo "==> Exporting and distributing keytabs..."

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: ip: ''
              ssh "$KDC" "rm -f /tmp/${name}.keytab && KRB5_KDC_PROFILE=/etc/krb5kdc/kdc.conf kadmin.local -q 'ktadd -k /tmp/${name}.keytab nfs/${name}.infra.homelab.invalid'"
              ssh "$KDC" "cat /tmp/${name}.keytab" | ssh "root@${ip}" "cat > /etc/krb5.keytab && chmod 600 /etc/krb5.keytab"
              ssh "$KDC" "rm -f /tmp/${name}.keytab"
              echo "    ${name}: keytab installed at /etc/krb5.keytab"
            '') cluster.nodes
          )}

          # NAS, install to /etc/ (active) and /volume1/data/scripts/ (persistent backup)
          ssh "$KDC" "rm -f /tmp/nas.keytab && KRB5_KDC_PROFILE=/etc/krb5kdc/kdc.conf kadmin.local -q 'ktadd -k /tmp/nas.keytab nfs/nas.infra.homelab.invalid'"
          ssh "$KDC" "cat /tmp/nas.keytab" | ssh -p "$NAS_PORT" "root@$NAS_HOST" "
            cat > /etc/krb5.keytab && chmod 600 /etc/krb5.keytab
            cp /etc/krb5.keytab $SCRIPTS_DIR/krb5.keytab && chmod 600 $SCRIPTS_DIR/krb5.keytab
          "
          ssh "$KDC" "rm -f /tmp/nas.keytab"
          echo "    nas: keytab installed at /etc/krb5.keytab + $SCRIPTS_DIR/krb5.keytab"
          echo "==> Distributing media keytab to k8s nodes..."
          ssh "$KDC" "rm -f /tmp/media.keytab && KRB5_KDC_PROFILE=/etc/krb5kdc/kdc.conf kadmin.local -q 'ktadd -k /tmp/media.keytab media@$REALM'"
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: ip: ''
              ssh "$KDC" "cat /tmp/media.keytab" | ssh "root@${ip}" "cat > /etc/krb5.media.keytab && chmod 600 /etc/krb5.media.keytab"
              echo "    ${name}: media keytab installed at /etc/krb5.media.keytab"
            '') cluster.nodes
          )}
          ssh "$KDC" "rm -f /tmp/media.keytab"

          echo "==> Writing /etc/krb5.conf to NAS..."
          ssh -p "$NAS_PORT" "root@$NAS_HOST" "cat > /etc/krb5.conf" << 'KRBEOF'
    [libdefaults]
        default_realm = HOMELAB.INVALID
        dns_lookup_realm = false
        dns_lookup_kdc = false

    [realms]
        HOMELAB.INVALID = {
            kdc = edenprairie.infra.homelab.invalid
            admin_server = edenprairie.infra.homelab.invalid
        }

    [domain_realm]
        .infra.homelab.invalid = HOMELAB.INVALID
        infra.homelab.invalid = HOMELAB.INVALID
    KRBEOF
          ssh -p "$NAS_PORT" "root@$NAS_HOST" "cp /etc/krb5.conf $SCRIPTS_DIR/krb5.conf"

          echo "==> Starting rpc.svcgssd on NAS..."
          ssh -p "$NAS_PORT" "root@$NAS_HOST" "
            if pidof rpc.svcgssd >/dev/null 2>&1; then
              echo '    rpc.svcgssd already running, restarting...'
              killall rpc.svcgssd
              sleep 1
            fi
            rpc.svcgssd && echo '    rpc.svcgssd started' || echo '    WARN: rpc.svcgssd failed to start'
          "

          echo "==> Restarting rpc-gssd on k8s nodes..."
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: ip: ''
              ssh "root@${ip}" "systemctl restart rpc-gssd 2>/dev/null && echo '    ${name}: rpc-gssd restarted' || echo '    ${name}: rpc-gssd not yet available (deploy NixOS config first)'"
            '') cluster.nodes
          )}

          # The NAS export security is set in the DSM UI and cannot be declared, so
          # assert it instead of asking someone to go and look. A share that fell
          # back to sec=sys still mounts, and the Kerberos requirement is silently
          # gone.
          echo "==> Verifying NAS export security"
          EXPORTS=$(ssh -p "$NAS_PORT" "root@$NAS_HOST" "cat /etc/exports")
          BAD=0
          check_export() {
            line=$(printf '%s\n' "$EXPORTS" | grep -E "^$1[[:space:]]" || true)
            if [ -z "$line" ]; then
              echo "    MISSING export $1" >&2; BAD=1; return
            fi
            case "$line" in
              *"sec=$2"*) echo "    $1 is sec=$2" ;;
              *) echo "    $1 is NOT sec=$2: $line" >&2; BAD=1 ;;
            esac
          }
          check_export /volume1/immich krb5p
          check_export /volume1/data krb5
          # sys is INTENDED here: longhorn-manager mounts it in-pod with no
          # keytab, and everything on the share is ciphertext before it lands
          # (LUKS volumes, age artifacts). Asserted so a DSM change is caught.
          check_export /volume1/longhorn-backups sys
          [ "$BAD" -eq 0 ] || { echo "FATAL: fix the NFS export security in DSM, then re-run" >&2; exit 1; }

          # Rollout restart, not re-apply: the PVs are Flux-managed.
          echo "==> Restarting media pods so they remount with Kerberos"
          ssh "root@${cluster.nodes.duluth}" \
            "export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig; \
             kubectl -n media rollout restart deployment --all 2>/dev/null || true; \
             kubectl -n plex rollout restart deployment --all 2>/dev/null || true"

          echo "=== Kerberos bootstrap complete ==="
  '';
}
