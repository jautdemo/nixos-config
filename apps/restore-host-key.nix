# nix run .#restore-host-key -- <host> [target-ip]
#
# Puts a reinstalled host's captured identity back before its first rebuild,
# so it decrypts its agenix secrets and known_hosts entries stay valid. The
# optional target-ip covers enrollment, when the host is not yet at its
# cluster.json address.
{
  pkgs,
  cluster,
  lib,
  ageIdentity,
  mkApp,
  clusterHosts,
}:
let
  hosts = clusterHosts.hosts cluster;
  ipCase = clusterHosts.ipCase cluster (
    h: ip: ''DEFAULT_IP="${ip}"; WANT="${cluster.hostKeys.${h}}"''
  );
in
mkApp {
  name = "restore-host-key";
  runtimeInputs = [
    pkgs.openssh
    pkgs.age
    pkgs.age-plugin-yubikey
    pkgs.coreutils
    ageIdentity
  ];
  text = ''
          HOST="''${1:-}"
          case "$HOST" in
    ${ipCase}
            *) echo "usage: restore-host-key <${lib.concatStringsSep "|" hosts}> [target-ip]" >&2; exit 1 ;;
          esac
          IP="''${2:-$DEFAULT_IP}"

          WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
          IDENT="$WORK/ident"; age-identity > "$IDENT"
          echo "==> Decrypting the captured key: PIN, then TOUCH"
          age -d -i "$IDENT" "$REPO_ROOT/secrets/$HOST-host-key.age" > "$WORK/key"

          # a fresh install presents an unknown temporary key; accept it once
          ssh -o StrictHostKeyChecking=accept-new "root@$IP" \
            "umask 077; cat > /etc/ssh/ssh_host_ed25519_key && systemctl restart sshd" < "$WORK/key"

          GOT=$(ssh-keyscan -t ed25519 "$IP" 2>/dev/null | cut -d" " -f2-3)
          if [ "$GOT" != "$WANT" ]; then
            echo "FATAL: $HOST presents a key that does not match cluster.json" >&2
            exit 1
          fi
          # drop the temporary key the install session accepted
          ssh-keygen -R "$IP" >/dev/null 2>&1 || true
          echo "$HOST restored: it presents its captured identity again."
  '';
}
