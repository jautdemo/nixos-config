{
  config,
  pkgs,
  lib,
  nixpkgs-cloudflared,
  ...
}:
let
  cluster = builtins.fromJSON (builtins.readFile ../../../cluster.json);
  wg = cluster.wireguard;
  vips = cluster.loadBalancer.vips;
in
{
  imports = [
    ../../common.nix
    ../../journal-to-loki.nix
  ];

  networking.hostName = "brainerd";

  # Break-glass: the OCI serial console carries typed characters only, so no
  # FIDO. Covers getty, serial console and sulogin (which bypasses PAM and
  # checks this hash directly). SSH stays key-only via PermitRootLogin.
  users.users.root.hashedPasswordFile = lib.mkForce config.age.secrets.brainerd-root-hash.path;
  age.secrets.brainerd-root-hash.file = ../../../secrets/brainerd-root-hash.age;

  # Without these the machine cannot boot: root is on a virtio disk, and an
  # initrd without virtio_blk never finds it. It stops before networking, so
  # OCI just shows a broken instance. A `switch` never exercises the initrd,
  # so breakage here stays invisible until the next reboot.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "virtio_mmio"
    "sd_mod"
    "sr_mod"
    "ahci"
  ];

  # OCI image uses systemd-repart with these partition labels
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/primary";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
  };

  # OCI primary interface; global DHCP so ens3 is configured regardless of network backend.
  networking.useDHCP = true;

  # IP forwarding, required for WireGuard routing and Mumble DNAT
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # Public WireGuard endpoint. brainerd-wg-setup generates the keypair,
  # agenix places it; never created by hand on the box.
  networking.wireguard.interfaces.wg0 = {
    ips = [ "${wg.brainerd.ip}/24" ];
    listenPort = 51820;
    privateKeyFile = "/etc/wireguard/private.key";

    # The wg-gateway pod dials OUT, so no endpoint is set here: brainerd learns
    # it from the handshake and follows the pod across nodes. No port-forward
    # on the home router.
    peers = [
      {
        publicKey = wg.gateway.publicKey;
        # Only what brainerd itself dials through the tunnel: the gateway
        # pod (every relayed service terminates in its socat and re-dials
        # from the cluster side) and Loki for log shipping. This is hygiene;
        # the enforcing allowlist is the FORWARD filter in the wg-gateway
        # pod. Public web goes through the in-cluster Cloudflare Tunnel,
        # never through this tunnel.
        allowedIPs = [
          "${wg.gateway.ip}/32"
          "${vips.loki}/32" # journald -> Loki log shipping
        ];
      }
      # Remote clients: one { publicKey; allowedIPs = [ "10.8.0.x/32" ]; }
      # block each.
    ];
  };

  # Port forwarding into the cluster over the wg tunnel.
  #   10.8.0.2      the wg-gateway pod, whose socat sidecar dials the VIP
  #                 itself. Forwarding raw packets at a VIP is unreliable
  #                 under Cilium.
  # 443 carries DoH only; there is no route from here to Traefik on 443.
  networking.nat = {
    enable = true;
    externalInterface = "ens3";
    forwardPorts = [
      {
        proto = "tcp";
        sourcePort = 64738;
        destination = "10.8.0.2:64738";
      }
      {
        proto = "udp";
        sourcePort = 64738;
        destination = "10.8.0.2:64738";
      }
      {
        proto = "tcp";
        sourcePort = 853;
        destination = "10.8.0.2:853";
      }
      {
        proto = "udp";
        sourcePort = 853;
        destination = "10.8.0.2:853";
      }
      {
        proto = "tcp";
        sourcePort = 443;
        destination = "10.8.0.2:443";
      }
    ];
  };

  # MASQUERADE outbound on wg0 so replies go to 10.8.0.1 rather than the
  # original client IP, which the home cluster cannot route back to.
  # One rule that cannot fail partway: a DROP in the nat table is refused by
  # iptables-nft, and the failed reload wipes the whole NAT table on its way out.
  networking.firewall.extraCommands = ''
    iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || true
  '';

  # TCP 22 is already open; add VPN + relayed services
  networking.firewall.allowedUDPPorts = [
    51820
    64738
    853
  ];
  networking.firewall.allowedTCPPorts = [
    64738
    853
    443
  ];

  # journald -> Loki at home through the tunnel: an audit trail that does not
  # live on the edge node itself.
  networking.hosts."${vips.loki}" = [ "loki.infra.homelab.invalid" ];

  # The secrets this host consumes, at the same paths the services already
  # read. The host key is captured in secrets/brainerd-host-key.age and
  # restored by brainerd-bootstrap, so recipient-ship survives a reprovision.
  age.secrets = {
    wireguard-brainerd = {
      file = ../../../secrets/wireguard-brainerd.age;
      path = "/etc/wireguard/private.key";
      mode = "0400";
    };
    cloudflared-brainerd = {
      file = ../../../secrets/cloudflared-brainerd.age;
      path = "/etc/cloudflared/tunnel.json";
      mode = "0400";
    };
    healthchecks-ping-key = {
      file = ../../../secrets/healthchecks-ping-key.age;
      path = "/etc/healthchecks/ping-key";
      mode = "0400";
    };
  };

  # SSH uses this tunnel; port 22 is closed in the OCI security list.
  # Package pinned so an auto-upgrade cannot ship a broken cloudflared to
  # the box you rely on to get in. Break-glass: the OCI serial console (root
  # password + console= params below).
  services.cloudflared = {
    enable = true;
    package = (import nixpkgs-cloudflared { system = pkgs.stdenv.hostPlatform.system; }).cloudflared;
    tunnels."deadbeef-dead-beef-dead-beefdeadbe01" = {
      credentialsFile = "/etc/cloudflared/tunnel.json";
      default = "http_status:404";
      ingress."ssh-brainerd.homelab.invalid" = "ssh://localhost:22";
    };
  };

  # Weekly rebuild against fresh nixpkgs, from a local copy synced by each
  # deploy, so the edge node needs no GitHub credential. Config freshness is
  # the last deploy; security freshness is weekly.
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos-config";
    flags = [
      "--update-input"
      "nixpkgs"
      "--no-write-lock-file"
      "-L"
    ];
    dates = "Sun 05:00";
    randomizedDelaySec = "30min";
    # True because a kernel update that never boots is not a security update.
    # Three things make an unattended reboot survivable and all must stay true:
    # virtio drivers in the initrd, console=ttyS0 so a failed boot is visible,
    # and generation 1 as a fallback entry. Touch any of them, reboot by hand.
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "07:00";
    };
  };

  # OOM hardening for a 1GB box, in four parts.
  # 1) Swap, so a memory spike degrades instead of breaking.
  swapDevices = [
    {
      device = "/swapfile";
      size = 4096; # MiB - generous relative to 1GB RAM; disk is cheap, OOM isn't
    }
  ];

  # 2) Cap nix build parallelism so builds themselves need less peak memory.
  #    Slower builds are explicitly fine here, this box has no time pressure.
  nix.settings = {
    max-jobs = 1;
    cores = 1;
  };

  # 3) Cap the upgrade's own memory so a runaway build fails in its own slice
  #    and retries next Sunday, leaving >300M for everything else.
  systemd.services.nixos-upgrade.serviceConfig = {
    MemoryHigh = "500M";
    MemoryMax = "650M";
  };

  # 4) If OOM strikes anyway, bias the kernel toward killing the build rather
  #    than the connectivity services this box exists for.
  systemd.services.wireguard-wg0.serviceConfig.OOMScoreAdjust = -900;
  systemd.services."cloudflared-tunnel-deadbeef-dead-beef-dead-beefdeadbe01".serviceConfig.OOMScoreAdjust =
    -900;
  # Nothing to add for 443: it is a plain kernel DNAT, so no userspace process
  # sits on the DoH path for OOM to starve.

  # Dead-man's-switch from outside the home failure domain, the case the
  # in-cluster home-heartbeat cannot cover.
  systemd.services.edge-heartbeat = {
    description = "Ping healthchecks.io that the OCI edge is alive";
    # Don't fail activation on a timer-driven oneshot.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "edge-heartbeat" ''
        set -eu
        KEY=$(cat /etc/healthchecks/ping-key)
        ${pkgs.curl}/bin/curl -fsS -m 20 -o /dev/null \
          "https://hc-ping.com/$KEY/brainerd-edge?create=1"
      '';
    };
  };
  systemd.timers.edge-heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60";
      OnUnitActiveSec = "60";
    };
  };

  # The heartbeats prove hosts are alive; this proves the public services work.
  # Each probe enters by its real public name, and NAT hairpin on this VPS
  # makes that a genuine outside-in test.
  systemd.services.service-probe = {
    description = "Probe public services end-to-end and ping healthchecks.io";
    restartIfChanged = false;
    path = [
      pkgs.knot-dns
      pkgs.openssl
      pkgs.curl
      pkgs.coreutils
      pkgs.gnugrep
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "service-probe" ''
        set -u
        KEY=$(cat /etc/healthchecks/ping-key)
        hc() { curl -fsS -m 10 -o /dev/null "https://hc-ping.com/$KEY/$1?create=1" || true; }

        # Mumble: a TLS handshake to the public relay port. murmur presents a
        # cert only if it is actually up and serving (stronger than TCP-open).
        if echo | openssl s_client -connect mumble.homelab.invalid:64738 2>/dev/null \
             | grep -q "BEGIN CERTIFICATE"; then
          hc mumble; echo "mumble up"
        else echo "mumble DOWN"; fi

        # DoT: a real DNS-over-TLS query through the public endpoint. A non-empty
        # answer proves DNS + DNAT + tunnel + AdGuard resolution all work.
        if [ -n "$(kdig +tls +short +timeout=5 @dnstls.homelab.invalid -p 853 example.com 2>/dev/null)" ]; then
          hc dot; echo "dot up"
        else echo "dot DOWN"; fi

        # 302 is the healthy answer (Authelia redirect); 200 means served
        # directly. This path no longer touches brainerd, but this box is the
        # one place still running when the cluster is not.
        code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' https://grafana.homelab.invalid 2>/dev/null || echo 000)
        case "$code" in
          200|301|302) hc web; echo "web up ($code)" ;;
          *) echo "web DOWN ($code)" ;;
        esac

        # DoH is all public 443 carries. This handshake proves the whole chain:
        # DNAT -> wg -> socat -> AdGuard's VIP.
        if echo | openssl s_client -connect dnstls.homelab.invalid:443 \
             -servername dnstls.homelab.invalid 2>/dev/null \
             | grep -q "BEGIN CERTIFICATE"; then
          hc doh; echo "doh up"
        else echo "doh DOWN"; fi

        # Origin lock, NEGATIVE test: a web SNI must not reach Traefik. Connect
        # to the PUBLIC address, not loopback - nothing listens on 127.0.0.1:443,
        # so a loopback test passes on connection-refused and can never fail.
        # Inverted on purpose: ping only when this does not look like Traefik.
        if echo | openssl s_client -connect dnstls.homelab.invalid:443 \
             -servername grafana.homelab.invalid 2>/dev/null \
             | grep -q "CN *= *grafana.homelab.invalid"; then
          echo "origin-lock BYPASSED - a web SNI got a web cert from this box"
        else
          hc origin-lock; echo "origin-lock enforcing"
        fi
      '';
    };
  };
  systemd.timers.service-probe = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "90";
      OnUnitActiveSec = "60";
    };
  };

  # Without this the OCI serial console is blind - the break-glass path when
  # the tunnel is down, which the root password above exists for.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];

  # canTouchEfiVariables FALSE on purpose: OCI's firmware does not persist EFI
  # NVRAM, and the only boot option it offers is the removable fallback path.
  # With variables enabled `bootctl install` never completes, so every reboot
  # comes up on the OCI image's GRUB. With them off it installs to the
  # fallback path too.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # /boot is a 249MB ESP holding every generation's kernel+initrd. Unbounded,
  # it fills and the next bootloader install fails.
  boot.loader.systemd-boot.configurationLimit = 10;

  system.stateVersion = "25.05";
}
