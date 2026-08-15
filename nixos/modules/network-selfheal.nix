# Recovers a headless host whose LAN interface came up dead. The check is
# local only (interface present, carrier, IPv4), so a router or ISP outage
# cannot trip it. Escalation: reconfigure, restart networkd, and as a last
# resort one reboot per boot - a reboot re-enumerates USB, which is what a
# USB NIC needs when it drops off the bus.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.networkSelfheal;
in
{
  options.services.networkSelfheal = {
    enable = lib.mkEnableOption "local network watchdog with reboot backstop";
    interface = lib.mkOption {
      type = lib.types.str;
      description = "Interface that must be up with an IPv4 address.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.network-selfheal = {
      description = "Recover ${cfg.interface} if it is down or unconfigured";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "network-selfheal";
      };
      path = [
        pkgs.iproute2
        pkgs.systemd
        pkgs.coreutils
        pkgs.gnugrep
      ];
      script = ''
        IF=${cfg.interface}
        FAILS=/run/network-selfheal.fails

        if [ -d "/sys/class/net/$IF" ] \
           && [ "$(cat /sys/class/net/$IF/operstate)" = "up" ] \
           && ip -4 addr show dev "$IF" | grep -q inet; then
          rm -f "$FAILS"
          exit 0
        fi

        n=$(cat "$FAILS" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$FAILS"
        echo "$IF is not healthy (consecutive failures: $n)"

        # With the 2min timer: reconfigure for ~4min, restart networkd for
        # ~4min, reboot at ~10min down.
        if [ "$n" -lt 3 ]; then
          networkctl reconfigure "$IF" || true
          exit 0
        fi

        BOOT=$(cat /proc/sys/kernel/random/boot_id)
        SENTINEL=/var/lib/network-selfheal/reboot-boot-id
        if [ "$n" -ge 5 ] && [ "$(cat "$SENTINEL" 2>/dev/null)" != "$BOOT" ]; then
          echo "$BOOT" > "$SENTINEL"
          echo "rebooting to recover $IF"
          systemctl reboot
          exit 0
        fi

        # Already rebooted this boot (or not there yet): keep restarting
        # networkd so the host recovers the moment the cause clears.
        echo "restarting systemd-networkd"
        systemctl restart systemd-networkd.service
      '';
    };

    systemd.timers.network-selfheal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "2min";
      };
    };

    # a dead interface at boot fails wait-online; hook it instead of
    # waiting out the timer's first tick.
    systemd.services.systemd-networkd-wait-online.onFailure = [ "network-selfheal.service" ];
  };
}
