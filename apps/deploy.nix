# nix run .#deploy -- <host>, deploy NixOS config to any managed host
# Usage: nix run .#deploy -- duluth
#        nix run .#deploy -- edenprairie
#        nix run .#deploy -- --all   (whole fleet, dependency order)
{
  pkgs,
  cluster,
  mkApp,
}:
mkApp {
  name = "deploy";
  runtimeInputs = [
    pkgs.openssh
    pkgs.nixos-rebuild
    pkgs.rsync
  ];
  text = ''
    HOST="''${1:-}"

    # Fleet deploy: foundation first (everything resolves names through
    # edenprairie), then the k8s nodes one at a time so the cluster never
    # loses two members, brainerd last (it may stage 'boot' and wait for a
    # reboot). Flags pass through to every per-host run.
    if [ "$HOST" = "--all" ]; then
      shift
      for h in edenprairie duluth bemidji fargo brainerd; do
        echo ""
        echo "=== deploy $h ==="
        "$0" "$h" "$@"
      done
      exit 0
    fi

    # What lands on the hosts must exist in a commit: autoUpgrade rebuilds
    # from the synced copy, and an uncommitted tree exists on one laptop.
    # --dirty deploys anyway, for iterating on a broken host.
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
      DIRTY_OK=0
      for a in "$@"; do [ "$a" = "--dirty" ] && DIRTY_OK=1; done
      if [ "$DIRTY_OK" = "0" ]; then
        echo "FATAL: working tree is dirty - commit first, or pass --dirty" >&2
        exit 1
      fi
    fi

    # Draining is opt-in: it only matters when the switch restarts kubelet or
    # containerd. For a key, a timer or a sysctl it costs minutes of eviction
    # and achieves nothing. Pass --drain for kubelet, containerd, kernel, CNI.
    DRAIN=0
    SKIP_DRAIN=0
    for a in "$@"; do
      [ "$a" = "--drain" ] && DRAIN=1
      [ "$a" = "--no-drain" ] && SKIP_DRAIN=1
    done

    case "$HOST" in
      duluth)         TARGET="root@${cluster.nodes.duluth}" ;;
      bemidji)        TARGET="root@${cluster.nodes.bemidji}" ;;
      fargo)          TARGET="root@${cluster.nodes.fargo}" ;;
      brainerd)       TARGET="root@${cluster.infra.brainerd}" ;;
      edenprairie)
        TARGET="root@${cluster.infra.edenprairie}"
        echo "==> Pre-flight: checking root label ..."
        actual=$(ssh -o ConnectTimeout=10 "$TARGET" 'lsblk -no LABEL "$(findmnt -n -o SOURCE /)"' 2>/dev/null)
        [[ "$actual" == "NIXOS_NVME" ]] || { echo "FATAL: unexpected root label '$actual'" >&2; exit 1; }
        ;;
      edenprairie-sd)
        TARGET="root@${cluster.infra.edenprairie}"
        echo "==> Pre-flight: checking root label ..."
        actual=$(ssh -o ConnectTimeout=10 "$TARGET" 'lsblk -no LABEL "$(findmnt -n -o SOURCE /)"' 2>/dev/null)
        [[ "$actual" == "NIXOS_SD" ]] || { echo "FATAL: unexpected root label '$actual'" >&2; exit 1; }
        ;;
      "")
        echo "Usage: nix run .#deploy -- <host>|--all [--drain|--no-drain]"
        echo "Available: duluth, bemidji, fargo, brainerd, edenprairie, edenprairie-sd"
        exit 1
        ;;
      *)
        echo "Unknown host '$HOST'."
        echo "Available: duluth, bemidji, fargo, brainerd, edenprairie, edenprairie-sd, --all"
        exit 1
        ;;
    esac


    # Build on the target by default. edenprairie is a slow aarch64 Pi, so
    # build on the local OrbStack VM when reachable and copy the closure over.
    BUILD_HOST="$TARGET"
    EXTRA_OPTS=()
    case "$HOST" in
      edenprairie|edenprairie-sd)
        if ssh -o ConnectTimeout=5 orb true 2>/dev/null; then
          BUILD_HOST="default@orb"
          # orb needs the raspberry-pi kernel cache to avoid compiling it
          EXTRA_OPTS=(
            --option extra-substituters "https://nixos-raspberrypi.cachix.org"
            --option extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
          )
          echo "==> Building on OrbStack VM (default@orb), deploying to $TARGET"
        else
          echo "==> orb unreachable - building on the Pi itself (slow)"
        fi
        ;;
    esac

    # brainerd cannot always take a `switch`: activation uses this SSH session
    # over the tunnel, so restarting cloudflared kills it halfway; and a switch
    # runs new userspace on the old kernel, hiding an unbootable initrd.
    # Neither is true of most changes, and `boot` costs a public outage, so ask
    # dry-activate and fall back to `boot` on any doubt.
    MODE=switch
    if [ "$HOST" = brainerd ]; then
      MODE=boot
      echo "==> checking whether a switch is safe on brainerd ..."
      dry=$(nixos-rebuild dry-activate --flake "$REPO_ROOT#$HOST" \
              --target-host "$TARGET" --build-host "$BUILD_HOST" 2>&1) || {
        printf '%s\n' "$dry" >&2
        echo "FATAL: dry-activate failed; refusing to deploy" >&2
        exit 1
      }
      new=$(printf '%s\n' "$dry" | sed -n 's/^Done\. The new configuration is //p' | tail -1)
      # $new is a path in brainerd's own store: BUILD_HOST is the target here.
      # shellcheck disable=SC2029
      if printf '%s\n' "$dry" | grep -qE "(restart|stop).*cloudflared"; then
        echo "    switch would restart cloudflared - using boot"
      elif [ -z "$new" ]; then
        echo "    could not read the new configuration path - using boot"
      elif ! ssh "$TARGET" "[ \"\$(readlink -f /run/booted-system/kernel)\" = \"\$(readlink -f $new/kernel)\" ] && \
                            [ \"\$(readlink -f /run/booted-system/initrd)\" = \"\$(readlink -f $new/initrd)\" ]"; then
        echo "    kernel or initrd differs from booted - using boot"
      else
        MODE=switch
        echo "    cloudflared untouched, kernel unchanged - using switch"
      fi
    fi

    # A nixpkgs bump restarts containerd, killing
    # longhorn's instance-manager; the replacement returns on a new pod IP
    # while the kernel holds unreapable iSCSI sessions to the old one, so no
    # engine starts here until a reboot. Silent WHOLE-NODE storage outage:
    # node stays Ready, longhorn-manager stays Running, volumes never attach.
    KCTL_HOST=""
    case "$HOST" in
      duluth|bemidji|fargo)
        # Run kubectl from a PEER: this node's own kubelet/containerd are
        # about to be restarted under it.
        for peer in duluth bemidji fargo; do
          [ "$peer" != "$HOST" ] || continue
          if ssh -o ConnectTimeout=10 -o BatchMode=yes "$peer" true 2>/dev/null; then KCTL_HOST="$peer"; break; fi
        done
        # `nixos-rebuild dry-activate` names the units a switch would restart, so
        # the deploy can answer this instead of the operator guessing.
        # --drain forces it, --no-drain skips it.
        if [ "$SKIP_DRAIN" = "1" ]; then
          echo "==> --no-drain: skipping cordon/drain"
          KCTL_HOST=""
        elif [ "$DRAIN" != "1" ]; then
          echo "==> checking whether this switch restarts kubelet/containerd ..."
          if nixos-rebuild dry-activate --flake ".#$HOST" \
               --target-host "$TARGET" --build-host "$BUILD_HOST" "''${EXTRA_OPTS[@]}" 2>&1 \
               | grep -qE "(restart|stop).*(kubelet|containerd|etcd)"; then
            echo "    it does - draining first"
          else
            echo "    it does not - skipping the drain"
            KCTL_HOST=""
          fi
        fi
        # A missing peer only matters once we have decided to drain: refuse
        # rather than switch blind.
        if [ "$DRAIN" = "1" ] && [ -z "$KCTL_HOST" ]; then
          echo "FATAL: --drain given but no reachable peer to run kubectl from" >&2
          exit 1
        fi
        if [ -n "$KCTL_HOST" ]; then
        echo "==> Draining $HOST (via $KCTL_HOST) before switch ..."
        # $HOST/$KCTL_HOST are meant to expand locally, before the ssh runs.
        # shellcheck disable=SC2029
        ssh "$KCTL_HOST" "export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig; \
          kubectl annotate node $HOST maintenance.homelab.invalid/drain-started=\$(date +%s) --overwrite >/dev/null; \
          kubectl cordon $HOST && \
          kubectl drain $HOST --ignore-daemonsets --delete-emptydir-data --force --timeout=300s" \
          || {
               # Uncordon before dying: the cordon happens first, so bailing
               # here leaves the node unschedulable. Doing that to all three
               # in a row takes the cluster down.
               echo "==> drain failed; uncordoning $HOST before exit" >&2
               ssh "$KCTL_HOST" "export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig; kubectl uncordon $HOST" >&2 || true
               echo "FATAL: drain of $HOST failed; refusing to deploy" >&2
               exit 1
             }
        fi
        ;;
    esac

    echo "==> Deploying .#$HOST to $TARGET (nixos-rebuild $MODE) ..."
    nixos-rebuild "$MODE" \
      --flake "$REPO_ROOT#$HOST" \
      --build-host "$BUILD_HOST" \
      --target-host "$TARGET" \
      "''${EXTRA_OPTS[@]}"

    if [ "$MODE" = boot ]; then
      echo ""
      echo "==> NOT YET ACTIVE. $HOST was staged with 'boot' - reboot to apply:"
      echo "      ssh $HOST 'systemctl reboot'"
    fi

    # Sessions present while Longhorn reports nothing attached means they are
    # orphans and the node needs a reboot to clear them.
    if [ -n "$KCTL_HOST" ]; then
      echo "==> Uncordoning $HOST ..."
      # shellcheck disable=SC2029
      ssh "$KCTL_HOST" "export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig; kubectl uncordon $HOST" || true
      # `grep -c` exits 1 on zero matches; `|| true` keeps errexit quiet and
      # `tail -1` drops any stray extra line so the count stays a single number.
      sessions=$(ssh "$HOST" 'iscsiadm -m session 2>/dev/null | grep -c tcp || true' 2>/dev/null | tail -1)
      # shellcheck disable=SC2029
      attached=$(ssh "$KCTL_HOST" "export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig; \
        kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.currentNodeID}{\"\n\"}{end}' 2>/dev/null | grep -c '^$HOST\$' || true" 2>/dev/null | tail -1)
      echo "==> $HOST: $sessions iSCSI session(s), $attached Longhorn volume(s) attached"
      if [ "$sessions" -gt 0 ] && [ "$attached" -eq 0 ]; then
        echo "WARNING: $HOST has iSCSI sessions but no attached volumes - likely STRANDED." >&2
        echo "         Longhorn cannot start engines there. Fix: drain and reboot the node." >&2
      fi
    fi

    # Every auto-patching host rebuilds from a local copy of this flake: the
    # repo is private and no node holds credentials for it, so the deploy
    # syncs the source. Config freshness = last deploy, by design.
    # Without /etc/nixos-config the autoUpgrade unit fails every scheduled
    # run with "No such file or directory" and nobody notices.
    case "$HOST" in
      brainerd|edenprairie|edenprairie-sd|duluth|bemidji|fargo)
        echo "==> Syncing flake source to $TARGET:/etc/nixos-config (for autoUpgrade) ..."
        # The gitignore filter matters: without it, gitignored credentials
        # and the .terraform provider tree ship to every host.
        rsync -a --delete --exclude .git --exclude result \
          --filter=':- .gitignore' --filter='P /.deployed-rev' \
          "$REPO_ROOT/" "$TARGET:/etc/nixos-config/"
        git -C "$REPO_ROOT" rev-parse HEAD | ssh "$TARGET" "cat > /etc/nixos-config/.deployed-rev"
        ;;
    esac
  '';
}
