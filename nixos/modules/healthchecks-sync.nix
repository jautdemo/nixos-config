# Declarative healthchecks.io checks: slugs and timings live in cluster.json
# (healthchecks), reconciled daily through the management API. Ping URLs stay
# slug-based (?create=1 covers first contact); this service owns period and
# grace, so a recreated project cannot silently fall back to the
# 1-day/1-hour defaults the ping endpoint creates with.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.healthchecksSync;
  cluster = builtins.fromJSON (builtins.readFile ../../cluster.json);
  defs = pkgs.writeText "healthchecks.json" (builtins.toJSON (cluster.healthchecks or { }));
in
{
  options.services.healthchecksSync.enable = lib.mkEnableOption "declarative healthchecks.io reconciliation";

  config = lib.mkIf cfg.enable {
    systemd.services.healthchecks-sync = {
      description = "Reconcile healthchecks.io checks with cluster.json";
      # Persistent timers fire missed runs right at boot; without this the
      # curl races the network and the failed unit pages via the allowlist.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig.Type = "oneshot";
      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
      ];
      script = ''
        set -euo pipefail
        KEY=$(cat ${config.age.secrets.healthchecks-api-key.path})
        API=https://healthchecks.io/api/v3/checks/
        # Free plan ceiling; refuse to create past it rather than half-apply.
        LIMIT=20

        existing=$(curl -fsS -H "X-Api-Key: $KEY" "$API")
        wantjson=$(jq 'keys' ${defs})
        mapfile -t want < <(jq -r 'keys[]' ${defs})

        total=$(jq '.checks | length' <<<"$existing")
        new=0
        for slug in "''${want[@]}"; do
          jq -e --arg s "$slug" '.checks[] | select(.slug == $s)' \
            <<<"$existing" >/dev/null || new=$((new+1))
        done
        if [ $((total + new)) -gt $LIMIT ]; then
          echo "FATAL: $total existing + $new new checks exceed the $LIMIT-check plan" >&2
          exit 1
        fi

        for slug in "''${want[@]}"; do
          spec=$(jq -c --arg s "$slug" '.[$s]' ${defs})
          cur=$(jq -c --arg s "$slug" \
            '[.checks[] | select(.slug == $s)][0] // empty' <<<"$existing")
          if [ -n "$cur" ]; then
            # Compare only the fields this service owns; names, tags and
            # channel assignments stay whatever the UI made them.
            have=$(jq -c '{timeout: (.timeout // null), grace: (.grace // null), schedule: (.schedule // null), tz: (.tz // null)}' <<<"$cur")
            need=$(jq -c '{timeout: (.timeout // null), grace: (.grace // null), schedule: (.schedule // null), tz: (.tz // null)}' <<<"$spec")
            if [ "$have" = "$need" ]; then
              echo "ok        $slug"
              continue
            fi
            body=$(jq -c --arg s "$slug" '. + {slug: $s, unique: ["slug"]}' <<<"$spec")
            curl -fsS -o /dev/null -H "X-Api-Key: $KEY" -d "$body" "$API"
            echo "updated   $slug"
          else
            # channels "*" only at creation: a check that alerts nobody is
            # the invisible kind of broken. Updates leave routing alone.
            body=$(jq -c --arg s "$slug" \
              '. + {name: $s, slug: $s, channels: "*", unique: ["slug"]}' <<<"$spec")
            curl -fsS -o /dev/null -H "X-Api-Key: $KEY" -d "$body" "$API"
            echo "created   $slug"
          fi
        done

        # Never deleted from here, only surfaced: the quota is finite and an
        # undeclared check is usually a forgotten one.
        jq -r --argjson want "$wantjson" '
          .checks[]
          | select(((.slug // "") as $s | ($want | index($s)) | not))
          | "undeclared \(.slug // "<no slug>") (\(.name))"' <<<"$existing"
      '';
    };

    systemd.timers.healthchecks-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 07:10:00";
        Persistent = true;
      };
    };
  };
}
