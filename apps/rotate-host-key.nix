# nix run .#rotate-host-key -- <host>
#
# Rotates a host's SSH identity in the safe order: install the new key on
# the host first, then rewrite cluster.json and the captured .age, then
# rekey every agenix secret. The host can decrypt its secrets at every
# step; the lockout order (rekey before install) is unreachable here.
# Finish with a deploy of EVERY host so knownHosts follows.
{
  pkgs,
  cluster,
  lib,
  ageIdentity,
  mkApp,
  clusterHosts,
}:
let
  recipientArgs =
    lib.concatMapStringsSep " " (r: "-r ${r}")
      (import ../secrets.nix)."secrets/duluth-host-key.age".publicKeys;
  hosts = clusterHosts.hosts cluster;
  ipCase = clusterHosts.ipCase cluster (_h: ip: ''TARGET="root@${ip}"'');
in
mkApp {
  name = "rotate-host-key";
  runtimeInputs = [
    pkgs.openssh
    pkgs.age
    pkgs.age-plugin-yubikey
    pkgs.jq
    pkgs.coreutils
    ageIdentity
  ];
  text = ''
          HOST="''${1:-}"
          case "$HOST" in
    ${ipCase}
            *) echo "usage: rotate-host-key <${lib.concatStringsSep "|" hosts}>" >&2; exit 1 ;;
          esac
          if [ "$HOST" = brainerd ] && [ "''${2:-}" != "--break-glass-anyway" ]; then
            echo "brainerd is the break-glass path; rotate it only with another way in." >&2
            echo "(--break-glass-anyway overrides)" >&2
            exit 1
          fi

          WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
          ssh-keygen -t ed25519 -N "" -C "$HOST-host" -f "$WORK/key" -q
          NEWPUB=$(cut -d" " -f1-2 "$WORK/key.pub")

          echo "==> Installing the new key on $HOST (old key still trusted for this session)"
          ssh "$TARGET" "umask 077; cat > /etc/ssh/ssh_host_ed25519_key && systemctl restart sshd" < "$WORK/key"

          GOT=$(ssh-keyscan -t ed25519 "''${TARGET#root@}" 2>/dev/null | cut -d" " -f2-3)
          if [ "$GOT" != "$NEWPUB" ]; then
            echo "FATAL: $HOST does not present the new key; investigate before rekeying" >&2
            exit 1
          fi

          echo "==> Recording the new public key in cluster.json"
          jq --arg h "$HOST" --arg k "$NEWPUB" '.hostKeys[$h]=$k' "$REPO_ROOT/cluster.json" \
            > "$WORK/cluster.json" && mv "$WORK/cluster.json" "$REPO_ROOT/cluster.json"

          echo "==> Re-capturing the private key"
          age -e ${recipientArgs} -o "$REPO_ROOT/secrets/$HOST-host-key.age" "$WORK/key"

          echo "==> Rekeying every agenix secret: PIN, then TOUCH per file"
          IDENT="$WORK/ident"; age-identity > "$IDENT"
          NIX_CONF_DIR=/var/empty nix run github:ryantm/agenix -- -r -i "$IDENT"

          for alias in "$HOST" "$HOST.infra.homelab.invalid" "''${TARGET#root@}"; do
            ssh-keygen -R "$alias" >/dev/null 2>&1 || true
          done

          echo ""
          echo "Rotated. Now commit, then deploy EVERY host so knownHosts and the"
          echo "re-encrypted secrets land:"
          echo "  git add -A && git commit -m '$HOST: rotate host key'"
          echo "  for h in ${lib.concatStringsSep " " hosts}; do nix run .#deploy -- \$h; done"
  '';
}
