# Common configuration for edenprairie (Raspberry Pi 5), shared between the
# NVMe and SD card boot configurations. The SD card is a fallback, not meant
# for continuous operation.
{
  config,
  pkgs,
  lib,
  nixpkgs-cloudflared,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../../../cluster.json);

in
{
  imports = [
    ../../common.nix
    ../../journal-to-loki.nix
    ./backups.nix
    ./mail.nix
    ./pki.nix
  ];

  boot.loader.raspberry-pi.bootloader = "kernel";

  boot.consoleLogLevel = 7;
  boot.kernelParams = [
    "loglevel=7"
    "boot.shell_on_fail"
  ];

  networking.useDHCP = false;
  networking.interfaces.end0.ipv4.addresses = [
    {
      address = cluster.infra.edenprairie;
      prefixLength = cluster.prefix;
    }
  ];
  networking.defaultGateway = cluster.gateway;
  networking.nameservers = [
    "127.0.0.1"
    "1.1.1.1"
  ];
  networking.firewall.allowedTCPPorts = [
    53 # DNS (dnsmasq)
    88 # Kerberos KDC
    636 # LDAPS redirect -> 6360
    749 # Kerberos kadmin
    6360 # LDAPS (lldap)
    8443 # step-ca ACME
    9100 # Prometheus node-exporter
    11025 # protonmail-bridge SMTP (LAN proxy)
    11143 # protonmail-bridge IMAP (LAN proxy)
    17170 # lldap web UI
  ];
  networking.firewall.allowedUDPPorts = [
    53 # DNS (dnsmasq)
    88 # Kerberos KDC
  ];

  # Redirect standard LDAPS port 636 -> lldap on 6360
  # (Synology DSM hardcodes port 636 for LDAPS)
  networking.firewall.extraCommands = ''
    iptables -t nat -A PREROUTING -p tcp --dport 636 -j REDIRECT --to-port 6360
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t nat -D PREROUTING -p tcp --dport 636 -j REDIRECT --to-port 6360 || true
  '';

  # This box is DNS, Kerberos, LDAP and the internal CA with no redundancy,
  # and host metrics cannot see any of them die. An allowlist because the
  # collector emits 5 series per unit per state across ~120 units.
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [
      "systemd"
      "textfile"
    ];
    extraFlags = [
      # A unit absent from this allowlist emits no series at all, so the
      # failed-unit alert can never match it. Backup units belong here.
      "--collector.systemd.unit-include=^(dnsmasq|kdc|kadmind|lldap|step-ca|offsite-sync|immich-offsite-sync|state-backup|protondrive-usage|protonmail-bridge|protonmail-bridge-imap-proxy|protonmail-bridge-smtp-proxy|bridge-tls-check|cloudflared-tunnel-.*|healthchecks-sync)\\.service$"
      # Compiled in, but collects nothing until a directory is set.
      "--collector.textfile.directory=/var/lib/node-exporter-textfile"
    ];
  };

  services.deployedRevMetrics.enable = true;

  services.healthchecksSync.enable = true;
  age.secrets.healthchecks-api-key.file = ../../../secrets/healthchecks-api-key.age;

  # Argon one V3 fan, uses Pi 5 I2C-controlled fan via RP2040
  hardware.raspberry-pi.config.all.base-dt-params.i2c_arm = {
    enable = true;
    value = "on";
  };
  hardware.raspberry-pi.config.all.base-dt-params.cooling_fan = {
    enable = true;
    value = "on";
  };

  # PCIe / NVMe, enable external PCIe lane on Pi 5 (Argon NEO 5 M.2 case)
  hardware.raspberry-pi.config.all.base-dt-params.nvme = {
    enable = true;
  };
  hardware.raspberry-pi.config.all.base-dt-params.pciex1 = {
    enable = true;
  };
  hardware.raspberry-pi.config.all.base-dt-params.pciex1_gen = {
    enable = true;
    value = "3";
  };
  hardware.raspberry-pi.config.all.options.usb_max_current_enable = {
    enable = true;
    value = 1;
  };

  boot.kernelModules = [ "i2c-dev" ];

  environment.systemPackages = with pkgs; [
    step-cli
    step-ca
    jq
    i2c-tools
    raspberrypi-eeprom
    protonmail-bridge
    gnupg
    pass
    age
    rclone
    # lldap_set_password: the bootstrap app calls it over ssh and
    # assumes it is on PATH.
    lldap
  ];

  services.krb5Client.enable = true;

  services.kerberos_server = {
    enable = true;
    settings.realms."HOMELAB.INVALID" = {
      acl = [
        {
          principal = "*/admin@HOMELAB.INVALID";
          access = "all";
        }
      ];
    };
  };

  # A fresh host must not break on a missing realm database: create it and
  # its master password on first start, same genesis pattern as lldap. The
  # password file is state-backup'd; a tar restore brings the database and
  # this becomes a no-op.
  systemd.services.kdc-genesis = {
    description = "Create the Kerberos realm database if missing";
    before = [
      "kdc.service"
      "kadmind.service"
    ];
    requiredBy = [ "kdc.service" ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.krb5
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      export KRB5_KDC_PROFILE=/etc/krb5kdc/kdc.conf
      if [ ! -f /var/lib/krb5kdc/principal ]; then
        umask 077
        PW=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
        kdb5_util create -s -r HOMELAB.INVALID -P "$PW"
        printf '%s' "$PW" > /var/lib/krb5kdc/master_password
        echo "created realm database and master password"
      fi
    '';
  };

  # Principals are derived state: nfs/<fqdn> per NFS participant plus the
  # media user principal, all from cluster.json. Idempotent and started on
  # every switch, so a node added to cluster.json gets its principal on the
  # next deploy. Keytab EXPORT stays in the kerberos-keytabs app on purpose:
  # ktadd bumps the key version, so it must never run unattended.
  systemd.services.kdc-principals = {
    description = "Ensure Kerberos principals match cluster.json";
    after = [ "kdc-genesis.service" ];
    requires = [ "kdc-genesis.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.krb5
      pkgs.gnugrep
    ];
    script = ''
      export KRB5_KDC_PROFILE=/etc/krb5kdc/kdc.conf
      for P in media@HOMELAB.INVALID ${
        lib.concatMapStringsSep " " (n: "nfs/${n}.infra.homelab.invalid") (
          [ "nas" ] ++ builtins.attrNames cluster.nodes
        )
      }; do
        if ! kadmin.local -q "getprinc $P" 2>/dev/null | grep -q "^Principal:"; then
          kadmin.local -q "addprinc -randkey $P"
          echo "created principal $P"
        fi
      done
    '';
  };

  services.dnsmasq = {
    enable = true;
    settings = {
      listen-address = [
        cluster.infra.edenprairie
        "127.0.0.1"
      ];
      bind-interfaces = true;
      server = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      no-resolv = true;
      domain-needed = true;
      bogus-priv = true;
      local = [
        "/infra.homelab.invalid/"
        "/ldap.homelab.invalid/"
      ];
      domain = "infra.homelab.invalid";
      address = [
        "/edenprairie.infra.homelab.invalid/${cluster.infra.edenprairie}"
        "/ldap.infra.homelab.invalid/${cluster.infra.edenprairie}"
        "/ldap.homelab.invalid/${cluster.infra.edenprairie}"
        "/duluth.infra.homelab.invalid/${cluster.nodes.duluth}"
        "/bemidji.infra.homelab.invalid/${cluster.nodes.bemidji}"
        "/fargo.infra.homelab.invalid/${cluster.nodes.fargo}"
        "/nas.infra.homelab.invalid/${cluster.infra.nas}"
        "/switch.infra.homelab.invalid/${cluster.gateway}"
        "/api.infra.homelab.invalid/${cluster.apiVIP}"
        "/loki.infra.homelab.invalid/${cluster.loadBalancer.vips.loki}"
        "/syslog.infra.homelab.invalid/${cluster.loadBalancer.vips.syslog}"
      ]
      # Internal-only names, kept out of public DNS; they resolve to the
      # Traefik VIP. The same list feeds the AdGuard rewrites and the
      # k8s/external shims via the regenerate-manifests app.
      ++ (map (n: "/${n}.homelab.invalid/${cluster.loadBalancer.vips.traefik}") (
        builtins.attrNames cluster.internalServices.devices ++ cluster.internalServices.cluster
      ));
      # Reverse DNS (PTR), required for Kerberos NFS
      host-record = [
        "edenprairie.infra.homelab.invalid,${cluster.infra.edenprairie}"
        "nas.infra.homelab.invalid,${cluster.infra.nas}"
        "duluth.infra.homelab.invalid,${cluster.nodes.duluth}"
        "bemidji.infra.homelab.invalid,${cluster.nodes.bemidji}"
        "fargo.infra.homelab.invalid,${cluster.nodes.fargo}"
      ];
      # Every pod's external lookup funnels through here on top of the LAN.
      # The default 150 in-flight queries is a LAN-wide brownout waiting to
      # happen: unanswered queries hold slots until they time out.
      dns-forward-max = 1000;
      # dnsmasq's documented practical ceiling, allocated once at startup.
      cache-size = 10000;
    };
  };

  services.lldap = {
    enable = true;
    silenceForceUserPassResetWarning = true;
    settings = {
      ldap_base_dn = "dc=homelab,dc=invalid";
      ldap_host = "0.0.0.0";
      ldap_port = 3890; # plain LDAP (localhost only via firewall)
      http_host = "0.0.0.0";
      http_port = 17170;
      http_url = "https://ldap.homelab.invalid";
      ldap_user_email = "admin@homelab.invalid";
      ldap_user_dn = "admin";
      ldap_user_pass_file = "/var/lib/lldap/private/user_pass";
      ldaps_options = {
        enabled = true;
        port = 6360;
        cert_file = "/etc/lldap/tls/cert.pem";
        key_file = "/etc/lldap/tls/cert.key";
      };
      smtp_options = {
        enable_password_reset = true;
        # The LAN bridge endpoint, not the plaintext 127.0.0.1:1025 hop, the
        # bridge cert's SAN matches this hostname.
        server = "edenprairie.infra.homelab.invalid";
        port = 11025;
        smtp_encryption = "STARTTLS";
        user = "admin@homelab.invalid";
        from = "ldap@homelab.invalid";
      };
    };
    environmentFile = "/var/lib/lldap/private/lldap.env";
  };

  # Allow lldap DynamicUser to read the TLS cert
  systemd.services.lldap.serviceConfig.BindReadOnlyPaths = [ "/etc/lldap/tls" ];

  # lldap cannot start without these files and nothing else creates them, so
  # a fresh host breaks before lldap-bootstrap can even run. Root-created is
  # fine: systemd fixes StateDirectory ownership for the DynamicUser. The
  # SMTP password cannot be generated - password-reset mail stays down until
  # the bridge password is appended to lldap.env (RESTORE.md).
  systemd.services.lldap-genesis = {
    description = "Generate lldap genesis secrets if missing";
    before = [ "lldap.service" ];
    requiredBy = [ "lldap.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      umask 077
      mkdir -p /var/lib/private/lldap/private
      if [ ! -f /var/lib/private/lldap/private/user_pass ]; then
        head -c 24 /dev/urandom | base64 > /var/lib/private/lldap/private/user_pass
        echo "generated lldap admin password"
      fi
      if [ ! -f /var/lib/private/lldap/private/lldap.env ]; then
        printf 'LLDAP_JWT_SECRET=%s\n' "$(head -c 24 /dev/urandom | base64)" \
          > /var/lib/private/lldap/private/lldap.env
        echo "generated lldap.env with a fresh JWT secret (SMTP password absent)"
      fi
    '';
  };

  # Three layered checks so the first to fail names the broken layer:
  # gateway_up, wan_up (by IP, no DNS), dns_up. Gateway up with WAN down is a
  # broken router; gateway down means it rebooted or died.
  # Here rather than in k8s so a timeline survives losing Loki and Prometheus.

  systemd.services.wan-watchdog = {
    description = "Record gateway/WAN/DNS reachability for outage diagnosis";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "wan-watchdog" ''
        set -u
        PROM_DIR=/var/lib/node-exporter-textfile
        STATE=/var/lib/wan-watchdog/last-state
        TS=$(date +%s)

        # -W 2: a broken router accepts the packet and never replies, so this
        # has to time out rather than fail fast.
        reach() {
          if ${pkgs.iputils}/bin/ping -c 1 -W 2 -n "$1" >/dev/null 2>&1; then echo 1; else echo 0; fi
        }

        gw=$(reach ${cluster.gateway})
        wan=$(reach 1.1.1.1)
        # Queries dnsmasq directly: NSS consults nscd, whose cache reports
        # success while DNS is broken. Matching a dotted quad is load-bearing:
        # dig exits 0 on an empty reply and prints failures on STDOUT.
        if timeout 5 ${pkgs.dnsutils}/bin/dig +short A +tries=1 +time=2 @127.0.0.1 one.one.one.one 2>/dev/null \
             | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then dns=1; else dns=0; fi

        TMP=$(mktemp "$PROM_DIR/.wan.XXXXXX") || exit 0
        trap 'rm -f "$TMP"' EXIT
        {
          echo "# HELP wan_watchdog_gateway_up Default gateway answers ICMP."
          echo "# TYPE wan_watchdog_gateway_up gauge"
          echo "wan_watchdog_gateway_up ''${gw}"
          echo "# HELP wan_watchdog_wan_up Off-net IP reachable by address, no DNS involved."
          echo "# TYPE wan_watchdog_wan_up gauge"
          echo "wan_watchdog_wan_up ''${wan}"
          echo "# HELP wan_watchdog_dns_up Name resolution works via the system resolver."
          echo "# TYPE wan_watchdog_dns_up gauge"
          echo "wan_watchdog_dns_up ''${dns}"
          echo "# HELP wan_watchdog_last_run_timestamp_seconds Last completed check."
          echo "# TYPE wan_watchdog_last_run_timestamp_seconds gauge"
          echo "wan_watchdog_last_run_timestamp_seconds ''${TS}"
        } > "$TMP"
        # Atomic publish: node-exporter must never read a half-written file.
        chmod 0644 "$TMP" && mv -f "$TMP" "$PROM_DIR/wan-watchdog.prom"
        trap - EXIT

        # Log only transitions, a line a minute would bury the signal.
        now="gw=''${gw} wan=''${wan} dns=''${dns}"
        prev=$(cat "$STATE" 2>/dev/null || echo "")
        if [ "$now" != "$prev" ]; then
          if [ "$gw" = 1 ] && [ "$wan" = 0 ]; then
            echo "WAN LOST while gateway still answers - router forwarding is broken ($now)" >&2
          elif [ "$gw" = 0 ]; then
            echo "GATEWAY UNREACHABLE - router is down or rebooting ($now)" >&2
          elif [ "$wan" = 1 ] && [ "$dns" = 0 ]; then
            echo "DNS BROKEN but WAN is fine - resolver problem, not connectivity ($now)" >&2
          else
            echo "connectivity state changed: $now" >&2
          fi
          printf '%s' "$now" > "$STATE"
        fi
      '';
    };
  };

  systemd.timers.wan-watchdog = {
    description = "Minute-by-minute WAN reachability record";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1m";
      # No RandomizedDelaySec: an even cadence is what makes the resulting
      # timeline readable, and the load is negligible either way.
    };
  };

  # allowReboot false: no redundancy here, and a failed unattended reboot
  # cascades into NFS mounts and node name resolution. The switch still runs.
  # Tuesday, after fargo's Monday run, so a bad nixpkgs surfaces on a
  # redundant node first.
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos-config";
    flags = [
      "--update-input"
      "nixpkgs"
      "--no-write-lock-file"
      "-L"
    ];
    dates = "Tue 04:00";
    randomizedDelaySec = "30min";
    allowReboot = false;
  };

  # 8GB here against 30GB on the k8s nodes: a rebuild must never be able to
  # starve dnsmasq, kdc, lldap or step-ca.
  systemd.services.nixos-upgrade.serviceConfig = {
    MemoryHigh = "2G";
    MemoryMax = "3G";
    CPUQuota = "200%"; # 2 of 4 cores
  };

  # If OOM does strike anyway, bias the kernel to kill the upgrade's own
  # build processes rather than these.
  systemd.services.dnsmasq.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.kdc.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.lldap.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.step-ca.serviceConfig.OOMScoreAdjust = -900;

  # Not a kubelet host, so the objection that rules swap out on the k8s nodes
  # does not apply. 8GB is tight for a large rebuild.
  swapDevices = [
    {
      device = "/swapfile";
      size = 4096; # MiB
    }
  ];

  # allowReboot is false, so a kernel update can sit applied-but-not-booted
  # with no signal.
  systemd.services.reboot-required-check = {
    description = "Check whether a reboot is needed and e-mail if so";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Root-only file (lldap's own SMTP credential); read it directly
      # rather than duplicating the secret into a second location.
      EnvironmentFile = "/var/lib/lldap/private/lldap.env";
    };
    path = [ pkgs.curl ];
    script = ''
      set -eu
      BOOTED_KERNEL=$(readlink -f /run/booted-system/kernel)
      CURRENT_KERNEL=$(readlink -f /run/current-system/kernel)
      BOOTED_MODULES=$(readlink -f /run/booted-system/kernel-modules)
      CURRENT_MODULES=$(readlink -f /run/current-system/kernel-modules)

      if [ "$BOOTED_KERNEL" = "$CURRENT_KERNEL" ] && [ "$BOOTED_MODULES" = "$CURRENT_MODULES" ]; then
        echo "Running the current generation's kernel - no reboot needed."
        exit 0
      fi

      echo "Booted kernel/modules differ from the current generation - reboot needed."
      SUBJECT="[edenprairie] reboot needed to apply new kernel"
      BODY="edenprairie is running an older kernel/modules than the current\nNixOS generation (auto-upgrade applied it live via switch, per\nallowReboot=false - only the reboot itself was withheld).\n\nBooted:  $BOOTED_KERNEL\nCurrent: $CURRENT_KERNEL\n\nReboot at a convenient time: ssh edenprairie sudo reboot\n"

      MSG=$(mktemp)
      printf "From: notifications@homelab.invalid\r\nTo: admin@homelab.invalid\r\nSubject: %s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%b\r\n" \
        "$SUBJECT" "$BODY" > "$MSG"
      curl --silent --show-error --ssl-reqd --cacert /etc/step-ca/certs/root_ca.crt \
        --url "smtp://edenprairie.infra.homelab.invalid:11025" \
        --mail-from "notifications@homelab.invalid" --mail-rcpt "admin@homelab.invalid" \
        --user "notifications@homelab.invalid:''${LLDAP_SMTP_OPTIONS__PASSWORD}" \
        --upload-file "$MSG"
      rm -f "$MSG"
      echo "E-mail sent."
    '';
  };

  systemd.timers.reboot-required-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # Restricted jump account for the Cloudflare Tunnel: port-forwarding only,
  # to sshd on the managed hosts and nothing else. Keys from cluster.json so
  # it cannot drift from the fleet.
  users.groups.jump = { };
  users.users.jump = {
    isSystemUser = true;
    group = "jump";
    shell = "${pkgs.shadow}/bin/nologin";
    description = "Restricted SSH jump account for the Cloudflare Tunnel";
    openssh.authorizedKeys.keys =
      let
        # A missing destination fails as "administratively prohibited" on
        # connect, not at login.
        permitted = [
          "${cluster.infra.edenprairie}:22"
          "${cluster.infra.nas}:${toString cluster.infra.nasSshPort}"
          "${cluster.nodes.duluth}:22"
          "${cluster.nodes.bemidji}:22"
          "${cluster.nodes.fargo}:22"
        ];
        # `restrict` first (deny everything, including anything sshd adds in
        # future), then restore forwarding alone and bound it with permitopen.
        opts = lib.concatStringsSep "," (
          [
            "restrict"
            "port-forwarding"
          ]
          ++ map (d: ''permitopen="${d}"'') permitted
        );
      in
      map (k: "${opts},${k}") (lib.attrValues cluster.sshKeys);
  };

  # root-only: cloudflared reads it before dropping privileges.
  age.secrets.cloudflared-edenprairie = {
    file = ../../../secrets/cloudflared-edenprairie.age;
    path = "/etc/cloudflared/tunnel.json";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.cloudflared = {
    enable = true;
    package = (import nixpkgs-cloudflared { system = pkgs.stdenv.hostPlatform.system; }).cloudflared;
    # Tunnel UUIDs never change after creation; hardcoding is safe.
    tunnels."deadbeef-dead-beef-dead-beefdeadbe02" = {
      credentialsFile = "/etc/cloudflared/tunnel.json";
      default = "http_status:404";
      ingress."ssh-home.homelab.invalid" = "ssh://localhost:22";
    };
  };

  system.stateVersion = "25.05";
}
