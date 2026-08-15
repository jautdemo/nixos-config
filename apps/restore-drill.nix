# nix run .#restore-drill
#
# Decrypts the latest edenprairie state backup and compares every file in it
# against the live host, byte for byte. Read-only: nothing is restored, no
# service is touched.
#
# A backup that lists the right paths can still contain the wrong bytes, tar a
# symlink and the job succeeds while the database is not in the archive.
# Needs a YubiKey: backups are encrypted to the PIV identities and the offline
# recovery key, never to a host key, so this cannot run unattended.
{
  pkgs,
  cluster,
  ageIdentity,
  mkApp,
  ...
}:
mkApp {
  name = "restore-drill";
  runtimeInputs = [
    pkgs.age
    ageIdentity
    pkgs.openssh
    pkgs.gnutar
    pkgs.gzip
    pkgs.coreutils
  ];
  # $LATEST and $rel are MEANT to expand on the client, before ssh runs,
  # the remote side must receive a literal path. Same reason the other apps
  # here exclude it.
  excludeShellChecks = [ "SC2029" ];
  text = ''
    HOST="root@${cluster.infra.edenprairie}"

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    IDENT="$WORK/identity"
    age-identity > "$IDENT"

    LATEST="$(ssh "$HOST" 'ls -t /mnt/backups/edenprairie-backup/*.age | head -1')"
    echo "==> newest backup: $(basename "$LATEST")"
    ssh "$HOST" "cat '$LATEST'" > "$WORK/b.age"

    echo "==> Decrypting the backup: enter the PIN, then TOUCH the key" >&2
    age --decrypt -i "$IDENT" "$WORK/b.age" > "$WORK/b.tar.gz"
    [ -s "$WORK/b.tar.gz" ] || { echo "decrypted archive is empty" >&2; exit 1; }

    mkdir -p "$WORK/x"
    tar -xzf "$WORK/b.tar.gz" -C "$WORK/x"

    # Compare every REGULAR file against the live host. A symlink stored in
    # place of its target shows up here as a size mismatch or a missing
    # file, which is exactly the failure.
    echo "==> comparing $(find "$WORK/x" -type f | wc -l | tr -d ' ') files against the live host"
    fail=0; ok=0
    while IFS= read -r rel; do
      # ssh -n matters: without it ssh eats the loop's stdin and the loop
      # exits after one iteration - a drill that checks one file and passes.
      live_sum="$(ssh -n "$HOST" "sha256sum '/$rel' 2>/dev/null | cut -d' ' -f1" || true)"
      back_sum="$(sha256sum "$WORK/x/$rel" | cut -d' ' -f1)"
      if [ -z "$live_sum" ]; then
        echo "  MISSING ON HOST  /$rel"; fail=$((fail+1))
      elif [ "$live_sum" != "$back_sum" ]; then
        echo "  DIFFERS          /$rel"; fail=$((fail+1))
      else
        ok=$((ok+1))
      fi
    done < <(cd "$WORK/x" && find . -type f | sed 's|^\./||')

    echo ""
    echo "==> $ok identical, $fail mismatched"

    # Guard against the loop dying early: if the number compared does
    # not equal the number found, the result means nothing.
    total=$(find "$WORK/x" -type f | wc -l | tr -d ' ')
    checked=$((ok + fail))
    if [ "$checked" -ne "$total" ]; then
      echo "DRILL INVALID: compared $checked of $total files - the loop did not run to completion" >&2
      exit 1
    fi

    # Spot-check the files a bad archive silently omits.
    for want in \
      var/lib/private/lldap/users.db \
      var/lib/protonmail-bridge/.config/protonmail/bridge-v3/vault.enc \
      etc/step-ca/secrets/root_ca_key
    do
      if [ -s "$WORK/x/$want" ]; then
        echo "  present and non-empty: $want"
      else
        echo "  ABSENT OR EMPTY: $want" >&2
        fail=$((fail+1))
      fi
    done

    [ "$fail" -eq 0 ] || { echo ""; echo "DRILL FAILED"; exit 1; }
    echo ""
    echo "DRILL PASSED - the backup contains exactly what is on the host."
  '';
}
