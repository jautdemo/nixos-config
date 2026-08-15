# nix run .#node-join -- <node-ip>
# Adds a (re)provisioned node to the etcd cluster. The node's secrets and
# PKI bootstrap files arrive via agenix on deploy; this is the one step
# that has to touch the EXISTING members.
{
  pkgs,
  lib,
  cluster,
  mkApp,
}:
mkApp {
  name = "node-join";
  runtimeInputs = [
    pkgs.openssh
    pkgs.jq
  ];
  excludeShellChecks = [ "SC2029" ];
  text = ''
    NODE_IP="''${1:-}"
    if [ -z "$NODE_IP" ]; then
      echo "Usage: nix run .#node-join -- <node-ip>"
      exit 1
    fi
    TARGET="root@$NODE_IP"
    PKI="/var/lib/kubernetes/pki"
    NODE_NAME=""
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: ip: ''
        if [ "$NODE_IP" = "${ip}" ]; then NODE_NAME="${name}"; fi
      '') cluster.nodes
    )}
    if [ -z "$NODE_NAME" ]; then
      echo "FATAL: $NODE_IP not found in cluster.json nodes" >&2
      exit 1
    fi
    if ! ssh -o ConnectTimeout=5 "$TARGET" true 2>/dev/null; then
      echo "FATAL: cannot reach $TARGET" >&2
      exit 1
    fi

    echo "==> Checking etcd cluster membership for $NODE_NAME"
    ETCD_HOST=""
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_name: ip: ''
        if [ "${ip}" != "$NODE_IP" ] && [ -z "$ETCD_HOST" ]; then
          if ssh -o ConnectTimeout=3 "root@${ip}" true 2>/dev/null; then
            ETCD_HOST="${ip}"
          fi
        fi
      '') cluster.nodes
    )}

    if [ -n "$ETCD_HOST" ]; then
      ETCD_CMD="etcdctl --endpoints=https://$ETCD_HOST:2379 --cacert=$PKI/ca.pem --cert=$PKI/etcd.pem --key=$PKI/etcd-key.pem"
      EXISTING=$(ssh "root@$ETCD_HOST" "$ETCD_CMD member list -w json 2>/dev/null" | jq -r ".members[]? | select(.name == \"$NODE_NAME\") | .name" 2>/dev/null || true)
      if [ -n "$EXISTING" ]; then
        echo "    $NODE_NAME is already an etcd member, skipping"
      else
        echo "    Adding $NODE_NAME to etcd cluster via $ETCD_HOST"
        ssh "root@$ETCD_HOST" "$ETCD_CMD member add $NODE_NAME --peer-urls=https://$NODE_IP:2380"
        echo "    Wiping stale etcd data on $NODE_NAME (if any)"
        ssh "$TARGET" "rm -rf /var/lib/etcd/*" 2>/dev/null || true
        echo "    $NODE_NAME added to etcd cluster"
      fi
    else
      echo "    No existing etcd node reachable - this is a fresh cluster bootstrap"
    fi

    echo ""
    echo "Next: nix run .#deploy -- $NODE_NAME"
  '';
}
