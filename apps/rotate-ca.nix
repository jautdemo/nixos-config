# nix run .#rotate-ca -- status|prepare|trust-both|cutover|retire
#
# Executable CA rotation. Phases are separated by operator-run deploys,
# because trust must reach every consumer BEFORE the signing CA changes:
#
#   prepare    generate the next root+intermediate on edenprairie, to the
#              side under /etc/step-ca/rotation - nothing serves them yet
#   trust-both append the next root to k8s/certs/step-ca-root.pem and
#              regenerate derived files; then commit, deploy --all and
#              nas-deploy so every trust store holds BOTH roots
#   cutover    swap step-ca to the next chain and force-reissue every leaf
#              (edenprairie stepCerts, k8s PKI, cert-manager secrets)
#   retire     shrink the repo trust file back to the new root only; then
#              commit, deploy --all and nas-deploy again
#
# status reads live and repo state and says which phase comes next.
{
  pkgs,
  cluster,
  mkApp,
}:
mkApp {
  name = "rotate-ca";
  runtimeInputs = [
    pkgs.openssh
    pkgs.openssl
    pkgs.gawk
  ];
  text = ''
        EP="root@${cluster.infra.edenprairie}"
        PEM="k8s/certs/step-ca-root.pem"
        PHASE="''${1:-status}"

        TMPD=$(mktemp -d)
        trap 'rm -rf "$TMPD"' EXIT

        fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }

        split_bundle() { # DIR FILE -> DIR/<n>.pem per certificate
          awk -v d="$1" '
            /-----BEGIN CERTIFICATE-----/ { n++; f = d "/" n ".pem" }
            f { print > f }
            /-----END CERTIFICATE-----/   { close(f); f = "" }
          ' "$2"
        }

        repo_fps() {
          rm -rf "$TMPD/repo"; mkdir -p "$TMPD/repo"
          split_bundle "$TMPD/repo" "$PEM"
          for f in "$TMPD"/repo/*.pem; do fp < "$f"; done
        }

        confirm() {
          echo "$1"
          read -r -p "Type yes to continue: " a
          [ "$a" = "yes" ] || { echo "aborted"; exit 1; }
        }

        live_fp() { ssh "$EP" cat /etc/step-ca/certs/root_ca.crt | fp; }
        next_fp() {
          ssh "$EP" 'cat /etc/step-ca/rotation/root_ca.crt 2>/dev/null' | fp 2>/dev/null || true
        }

        case "$PHASE" in
          status)
            LIVE=$(live_fp); NEXT=$(next_fp)
            echo "live root:      $LIVE"
            echo "prepared next:  ''${NEXT:-none}"
            echo "repo $PEM:"
            repo_fps | sed 's/^/  /'
            if [ -z "$NEXT" ]; then
              echo "-> no rotation in progress; start with: rotate-ca prepare"
            elif ! repo_fps | grep -qx "$NEXT"; then
              echo "-> next root exists but is not in the repo trust file: rotate-ca trust-both"
            elif [ "$LIVE" != "$NEXT" ]; then
              echo "-> both roots trusted; after deploy --all and nas-deploy: rotate-ca cutover"
            else
              echo "-> cutover done; when every leaf is reissued: rotate-ca retire"
            fi
            ;;

          prepare)
            ssh "$EP" bash -s <<'EOS'
    set -euo pipefail
    export STEPPATH=/etc/step-ca
    if [ -f /etc/step-ca/rotation/root_ca.crt ]; then
      echo "rotation certs already prepared, skipping"
      exit 0
    fi
    umask 077
    mkdir -p /etc/step-ca/rotation
    tar -C /etc -czf "/root/step-ca-backup-$(date +%F).tar.gz" step-ca
    echo "backed up /etc/step-ca to /root/step-ca-backup-$(date +%F).tar.gz"
    step certificate create "Homelab Root CA" \
      /etc/step-ca/rotation/root_ca.crt /etc/step-ca/rotation/root_ca_key \
      --profile root-ca --password-file /etc/step-ca/password
    step certificate create "Homelab Intermediate CA" \
      /etc/step-ca/rotation/intermediate_ca.crt /etc/step-ca/rotation/intermediate_ca_key \
      --profile intermediate-ca \
      --ca /etc/step-ca/rotation/root_ca.crt --ca-key /etc/step-ca/rotation/root_ca_key \
      --password-file /etc/step-ca/password --ca-password-file /etc/step-ca/password
    echo "next chain prepared under /etc/step-ca/rotation"
    EOS
            echo "Next: nix run .#rotate-ca -- trust-both"
            ;;

          trust-both)
            NEXT=$(next_fp)
            [ -n "$NEXT" ] || { echo "no prepared rotation certs - run prepare first" >&2; exit 1; }
            if repo_fps | grep -qx "$NEXT"; then
              echo "next root already present in $PEM"
            else
              ssh "$EP" cat /etc/step-ca/rotation/root_ca.crt >> "$PEM"
              echo "appended next root to $PEM"
            fi
            nix run .#regenerate-manifests
            echo ""
            echo "Now distribute the double trust:"
            echo "  git add -A && git commit"
            echo "  nix run .#deploy -- --all"
            echo "  nix run .#nas-deploy"
            echo "  (flux picks up the regenerated ConfigMaps from the pushed repo)"
            echo "Then: nix run .#rotate-ca -- cutover"
            ;;

          cutover)
            NEXT=$(next_fp); LIVE=$(live_fp)
            [ -n "$NEXT" ] || { echo "no prepared rotation certs - run prepare first" >&2; exit 1; }
            [ "$LIVE" != "$NEXT" ] || { echo "step-ca already serves the next chain"; exit 0; }
            repo_fps | grep -qx "$NEXT" || { echo "next root not in $PEM - run trust-both first" >&2; exit 1; }
            # The synced copy on edenprairie proves at least one deploy carried
            # the bundle; --all and nas-deploy cannot be verified from here.
            ssh "$EP" cat /etc/nixos-config/$PEM > "$TMPD/synced.pem"
            rm -rf "$TMPD/repo"; mkdir -p "$TMPD/repo"; split_bundle "$TMPD/repo" "$TMPD/synced.pem"
            FOUND=0
            for f in "$TMPD"/repo/*.pem; do [ "$(fp < "$f")" = "$NEXT" ] && FOUND=1; done
            [ "$FOUND" = 1 ] || { echo "deployed copy on edenprairie lacks the next root - deploy first" >&2; exit 1; }
            confirm "This swaps the live CA and reissues every leaf certificate. Every host and the NAS must already trust both roots (deploy --all + nas-deploy)."

            ssh "$EP" bash -s <<'EOS'
    set -euo pipefail
    export STEPPATH=/etc/step-ca
    systemctl stop step-ca
    install -m 0644 /etc/step-ca/rotation/root_ca.crt        /etc/step-ca/certs/root_ca.crt
    install -m 0600 /etc/step-ca/rotation/root_ca_key        /etc/step-ca/secrets/root_ca_key
    install -m 0644 /etc/step-ca/rotation/intermediate_ca.crt /etc/step-ca/certs/intermediate_ca.crt
    install -m 0600 /etc/step-ca/rotation/intermediate_ca_key /etc/step-ca/secrets/intermediate_ca_key
    systemctl start step-ca
    step certificate verify /etc/step-ca/certs/intermediate_ca.crt --roots /etc/step-ca/certs/root_ca.crt
    echo "step-ca serves the new chain"
    # force-reissue the local stepCerts leaves (their units reissue on a
    # missing file and gate their consumers)
    rm -f /etc/lldap/tls/cert.pem /etc/lldap/tls/cert.key
    rm -f /var/lib/protonmail-bridge/certs/bridge-cert.pem /var/lib/protonmail-bridge/certs/bridge-key.pem
    systemctl restart lldap-cert protonmail-bridge-cert
    systemctl restart lldap protonmail-bridge
    echo "edenprairie leaves reissued"
    EOS

            for pair in duluth=${cluster.nodes.duluth} bemidji=${cluster.nodes.bemidji} fargo=${cluster.nodes.fargo}; do
              n="''${pair%%=*}"; ip="''${pair#*=}"
              echo "==> reissuing k8s PKI on $n"
              ssh "root@$ip" '
                set -euo pipefail
                cd /var/lib/kubernetes/pki
                # keep the service-account pair: identity, not CA-signed
                find . -maxdepth 1 -name "*.pem" ! -name "service-account*" -delete
                systemd-tmpfiles --create
                systemctl restart k8s-pki-request
              '
            done

            echo "==> deleting cert-manager TLS secrets so they reissue from the new chain"
            ssh root@${cluster.nodes.duluth} '
              set -euo pipefail
              export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig
              kubectl get certificate -A \
                -o jsonpath="{range .items[*]}{.metadata.namespace} {.spec.secretName}{\"\n\"}{end}" \
              | while read -r ns secret; do
                  kubectl -n "$ns" delete secret "$secret" --ignore-not-found
                done
            '
            echo ""
            echo "Leaves reissue in the background. When lldap, ingresses and the"
            echo "k8s control plane are healthy: nix run .#rotate-ca -- retire"
            ;;

          retire)
            LIVE=$(live_fp)
            COUNT=$(repo_fps | grep -c . || true)
            repo_fps | grep -qx "$LIVE" || { echo "$PEM does not contain the live root - wrong state for retire" >&2; exit 1; }
            [ "$COUNT" -gt 1 ] || { echo "$PEM already holds a single root, nothing to retire"; exit 0; }
            confirm "This drops the OLD root from $PEM. Every leaf must already be reissued (check: cluster-healthcheck green, lldap and ingresses serving)."
            # Never redirect straight into the trust file: that truncates it
            # before ssh can fail.
            ssh "$EP" cat /etc/step-ca/certs/root_ca.crt > "$TMPD/root.pem"
            [ -s "$TMPD/root.pem" ]
            mv "$TMPD/root.pem" "$PEM"
            nix run .#regenerate-manifests
            ssh "$EP" 'rm -rf /etc/step-ca/rotation'
            echo ""
            echo "Now distribute the shrunken trust:"
            echo "  git add -A && git commit"
            echo "  nix run .#deploy -- --all"
            echo "  nix run .#nas-deploy"
            echo "The step-ca backup tarball from prepare stays in /root on edenprairie."
            ;;

          *)
            echo "Usage: nix run .#rotate-ca -- status|prepare|trust-both|cutover|retire" >&2
            exit 1
            ;;
        esac
  '';
}
