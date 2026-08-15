# push-secret <name>...   (nix run .#push-secret -- sops-age)
#
# Decrypts secrets/<name>.age with the plugged-in YubiKey and installs it as a
# Secret in the cluster, then verifies the bytes landed. Exists for the one
# secret agenix cannot reach: Flux needs sops-age to decrypt k8s/, so it
# cannot itself be a SOPS secret, and agenix only lands files on hosts.
{
  pkgs,
  cluster,
  ageIdentity,
  mkApp,
}:

let
  kubeHosts = pkgs.lib.concatStringsSep " " (
    map (h: "root@${h}") (builtins.attrValues cluster.nodes)
  );
in
mkApp {
  name = "push-secret";
  runtimeInputs = [
    pkgs.age
    ageIdentity
    pkgs.openssh
    pkgs.coreutils
  ];
  # Target fields are meant to expand here, not on the remote side.
  excludeShellChecks = [ "SC2029" ];
  text = ''
    if [ $# -eq 0 ]; then
      echo "usage: push-secret <name>...   known: sops-age" >&2
      exit 1
    fi

    # Exported ONCE per remote command, never inlined per kubectl: `$K kubectl a
    # | $K kubectl b` parses as `kubectl a | export ...`, piping into export and
    # silently feeding the second kubectl nothing.
    KENV="export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig;"

    age_key="$(mktemp)"; tmp="$(mktemp)"
    trap 'rm -f "$age_key" "$tmp"' EXIT
    age-identity > "$age_key"

    for name in "$@"; do
      case "$name" in
        sops-age)
          # Key name must stay age.agekey: Flux matches the .agekey suffix.
          ns="flux-system"; secret="sops-age"; key="age.agekey" ;;
        *) echo "unknown secret '$name'. known: sops-age" >&2; exit 1 ;;
      esac

      # Decrypt to a file first: piping age into ssh lets a failed decrypt
      # truncate the target to zero bytes.
      echo "==> Decrypting $name: enter the PIN, then TOUCH the key" >&2
      age --decrypt -i "$age_key" "secrets/$name.age" > "$tmp"
      if [ ! -s "$tmp" ]; then
        echo "FAILED: $name decrypted to nothing. Nothing was modified." >&2
        exit 1
      fi
      want="$(sha256sum "$tmp" | cut -c1-12)"

      # Any node will do, but it must be up; refuse rather than half-apply.
      khost=""
      for n in ${kubeHosts}; do
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$n" true 2>/dev/null; then khost="$n"; break; fi
      done
      if [ -z "$khost" ]; then
        echo "FAILED: no reachable k8s node to run kubectl from" >&2
        exit 1
      fi

      # create --dry-run | apply, so this is idempotent rather than a
      # delete-and-recreate that leaves a window with no key at all.
      ssh "$khost" "$KENV kubectl -n '$ns' create secret generic '$secret' \
        --from-file='$key'=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -" < "$tmp" >/dev/null

      # go-template, not jsonpath: the key name contains a dot.
      got="$(ssh "$khost" "$KENV kubectl -n '$ns' get secret '$secret' \
        -o go-template='{{index .data \"$key\"}}' | base64 -d | sha256sum" | cut -c1-12)"
      if [ "$got" != "$want" ]; then
        echo "FAILED: $ns/$secret key $key is $got, expected $want" >&2
        exit 1
      fi
      echo "$name -> $khost $ns/$secret ($key) ok ($want)"
    done
  '';
}
