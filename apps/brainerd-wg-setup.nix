# Provision the cluster <-> brainerd WireGuard keypair. The cluster end lives
# in the wg-gateway pod, which reads its key from a SOPS Secret; the nodes
# themselves run no WireGuard. Brainerd learns the endpoint from each
# handshake, so the pod moving between nodes IS the failover - no keepalived
# floating IP like the API server needs. Run after brainerd is up; re-running
# reuses the existing key.
{
  pkgs,
  cluster,
  lib,
  ageIdentity,
  mkApp,
}:
let
  # Recipients from secrets.nix, so a key rotation there flows through.
  recipientArgs =
    lib.concatMapStringsSep " " (r: "-r ${r}")
      (import ../secrets.nix)."secrets/wireguard-brainerd.age".publicKeys;
in
mkApp {
  name = "brainerd-wg-setup";
  runtimeInputs = [
    pkgs.openssh
    pkgs.nixos-rebuild
    pkgs.wireguard-tools
    pkgs.age
    pkgs.jq
    ageIdentity
  ];
  text = ''
    CLUSTER_JSON="$REPO_ROOT/cluster.json"
    BRAINERD="root@${cluster.infra.brainerd}"

    echo "=== Loading cluster gateway WireGuard keypair ==="
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
    PRIVKEY_FILE="$TMPDIR/cluster-gw.key"

    # Source of truth: secrets/wireguard-cluster-gw.age. Never written to the
    # nodes - the pod reads the SOPS copy in the wg-gateway key Secret, so
    # rotating means updating both.
    if [ -f secrets/wireguard-cluster-gw.age ]; then
      IDENT="$TMPDIR/identity"
      age-identity > "$IDENT"
      echo "==> Decrypting the cluster gateway key: enter the PIN, then TOUCH the key" >&2
      age --decrypt -i "$IDENT" secrets/wireguard-cluster-gw.age > "$PRIVKEY_FILE"
      chmod 400 "$PRIVKEY_FILE"
    else
      echo "  No secrets/wireguard-cluster-gw.age - generating a new keypair."
      wg genkey > "$PRIVKEY_FILE"
      chmod 400 "$PRIVKEY_FILE"
      echo ""
      echo "  ENCRYPT IT NOW, it exists nowhere else:"
      echo "    nix run github:ryantm/agenix -- -e secrets/wireguard-cluster-gw.age"
      echo ""
    fi

    PUBKEY=$(wg pubkey < "$PRIVKEY_FILE")
    echo "  Gateway public key: $PUBKEY"

    # Same treatment for brainerd's own key: generate + encrypt if the .age
    # is missing, so no key is ever typed into a shell on the box.
    # agenix places it on the host at the next deploy.
    if [ ! -f secrets/wireguard-brainerd.age ]; then
      echo "=== No secrets/wireguard-brainerd.age - generating brainerd keypair ==="
      BKEY_FILE="$TMPDIR/brainerd.key"
      wg genkey > "$BKEY_FILE"
      chmod 400 "$BKEY_FILE"
      age ${recipientArgs} -o secrets/wireguard-brainerd.age < "$BKEY_FILE"
      BPUB=$(wg pubkey < "$BKEY_FILE")
      echo "  brainerd public key: $BPUB"
      jq --indent 4 --arg k "$BPUB" '.wireguard.brainerd.publicKey=$k' "$CLUSTER_JSON" \
        > "$TMPDIR/cluster.json" && mv "$TMPDIR/cluster.json" "$CLUSTER_JSON"
      git -C "$REPO_ROOT" add secrets/wireguard-brainerd.age
      echo "  Deploy brainerd to place it, then: nix run .#regenerate-manifests"
    fi

    echo "=== Updating cluster.json with gateway public key ==="
    jq --indent 4 --arg k "$PUBKEY" '.wireguard.gateway.publicKey=$k' "$CLUSTER_JSON" \
      > "$TMPDIR/cluster.json" && mv "$TMPDIR/cluster.json" "$CLUSTER_JSON"

    echo "=== Committing ==="
    git -C "$REPO_ROOT" add "$CLUSTER_JSON"
    # A re-run with unchanged keys stages nothing; committing would exit 1
    # and kill the script before the deploy and status steps.
    git -C "$REPO_ROOT" diff --cached --quiet || git -C "$REPO_ROOT" commit -m \
      "chore(wireguard): record cluster gateway WireGuard public key"

    echo "=== Deploying brainerd (activates new peer config) ==="
    nixos-rebuild switch \
      --flake "$REPO_ROOT#brainerd" \
      --build-host "$BRAINERD" \
      --target-host "$BRAINERD"

    echo ""
    echo "The k8s nodes run no WireGuard; the cluster end is the wg-gateway"
    echo "pod. The gateway private key it uses is the SOPS copy in"
    echo "k8s/wg-gateway/wg-key-secret.yaml - if the key was just generated,"
    echo "put it there too and let Flux roll the pod. Brainerd's peer config"
    echo "(gateway public key from cluster.json) is live from the deploy"
    echo "above; a new brainerd key reaches the pod's wg0.conf via"
    echo "  nix run .#regenerate-manifests"

    echo ""
    echo "=== brainerd wg0 status ==="
    ssh "$BRAINERD" 'wg show wg0'
  '';
}
