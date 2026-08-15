# Configuration shared by all Kubernetes nodes (duluth, bemidji, fargo)
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../../../cluster.json);

  ageRecipientArgs = lib.concatMapStringsSep " " (r: "-r ${r}") cluster.backupRecipients;
in
{
  imports = [
    ../../common.nix
    ../../journal-to-loki.nix
    ../../ldap-client.nix
  ];

  # Nix store sharing, siblings as substituters so the kernel (and
  # everything else) is only built once across the cluster.
  # Uses ssh:// (read-only nix-store --serve) rather than ssh-ng:// (full daemon).
  nix.settings = {
    substituters = lib.mkAfter (
      map (name: "ssh://nix-store@${name}.infra.homelab.invalid") (builtins.attrNames cluster.nodes)
    );
    # Advertise features so the Mac nix daemon can use these nodes as remote builders
    system-features = [
      "nixos-test"
      "kvm"
      "big-parallel"
      "benchmark"
    ];
    trusted-public-keys = lib.mkAfter [
      "k8s-cluster:deadbeef07deadbeef07deadbeef07deadbeef07dea="
    ];
    secret-key-files = [ "/etc/nix/signing-key" ];
  };

  users.users.nix-store = {
    isSystemUser = true;
    group = "nogroup";
    home = "/var/lib/nix-store-user";
    createHome = true;
    shell =
      pkgs.writeShellScriptBin "nix-store-serve" ''
        exec ${pkgs.nix}/bin/nix-store --serve
      ''
      + "/bin/nix-store-serve";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAADEADBEEF13DEADBEEF13DEADBEEF13DEADBEEF13DEADBEEF13DEADBEEF13= nix-store-sharing"
    ];
  };

  services.krb5Client.enable = true;

  services.networkSelfheal = {
    enable = true;
    interface = "lan0";
  };

  services.deployedRevMetrics.enable = true;

  services.certMetrics = {
    enable = true;
    certs = lib.genAttrs [
      "apiserver-etcd-client"
      "apiserver-kubelet-client"
      "apiserver-proxy-client"
      "ca"
      "cluster-admin"
      "etcd"
      "kube-apiserver"
      "kube-controller-manager-client"
      "kube-scheduler-client"
      "kubelet"
      "kubelet-client"
    ] (name: "/var/lib/kubernetes/pki/${name}.pem");
  };

  systemd.services.rpc-gssd = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "nfs-client.target" ];
  };

  # NFSv4 idmapd domain, must match the NAS
  services.nfs.idmapd.settings = {
    General.Domain = "infra.homelab.invalid";
    General.Local-Realms = "HOMELAB.INVALID";
  };

  # Maintain Kerberos ccaches for container UIDs so rpc.gssd can
  # authenticate krb5p NFS mounts on behalf of non-root users.
  services.nfsKrb5Ccache = {
    enable = true;
    credentials = [
      {
        uid = 0;
        gid = 0;
        principal = "nfs/${config.networking.hostName}.infra.homelab.invalid@HOMELAB.INVALID";
        keytab = "/etc/krb5.keytab";
        ccache = "/tmp/krb5ccmachine_HOMELAB.INVALID";
      }
      {
        uid = 11000;
        principal = "media@HOMELAB.INVALID";
        keytab = "/etc/krb5.media.keytab";
      }
      {
        uid = 11003;
        principal = "immich@HOMELAB.INVALID";
        keytab = "/etc/krb5.immich.keytab";
      }
    ];
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.links."10-lan" = {
    matchConfig.Driver = "r8152";
    linkConfig.Name = "lan0";
  };

  systemd.network.networks."10-lan" = {
    matchConfig.Driver = "r8152";
    address = [ "${cluster.nodes.${config.networking.hostName}}/${toString cluster.prefix}" ];
    gateway = [ cluster.gateway ];
    dns = [ cluster.dns ];
    domains = [ "infra.homelab.invalid" ];
    networkConfig = {
      DHCP = "no";
      LinkLocalAddressing = "no";
    };
    linkConfig.MTUBytes = "9000";
  };

  networking.nameservers = [ cluster.dns ];
  networking.search = [ "infra.homelab.invalid" ];

  boot.initrd.availableKernelModules = [ "r8152" ];

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_CH.UTF-8";
    LC_IDENTIFICATION = "de_CH.UTF-8";
    LC_MEASUREMENT = "de_CH.UTF-8";
    LC_MONETARY = "de_CH.UTF-8";
    LC_NAME = "de_CH.UTF-8";
    LC_NUMERIC = "de_CH.UTF-8";
    LC_PAPER = "de_CH.UTF-8";
    LC_TELEPHONE = "de_CH.UTF-8";
    LC_TIME = "de_CH.UTF-8";
  };

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  environment.systemPackages = with pkgs; [
    tcpdump
    traceroute
    mtr
    iperf3
    nmap
    dig
    ethtool
    pciutils
    usbutils
    inetutils
    conntrack-tools
    # intel_gpu_top shows per-engine utilisation, the only way to see from the
    # OUTSIDE whether a transcode is really on the GPU.
    intel-gpu-tools
  ];

  services.thermald.enable = true;
  powerManagement.cpuFreqGovernor = "powersave";

  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = [ "usbcore.autosuspend=-1" ];

  # Prevent xHCI host controllers from suspending, causes link drops on USB NICs
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{product}=="xHCI Host Controller", ATTR{power/control}="on"
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="mq-deadline"
  '';

  # nslcd reads it at this fixed path; agenix places it on every node.
  age.secrets.ldap-bind-password = {
    file = ../../../secrets/ldap-bind-password.age;
    path = "/etc/ldap-bind-password";
    owner = "root";
    group = "nslcd";
    mode = "0640";
  };
  age.secrets.k8s-provisioner-password = {
    file = ../../../secrets/k8s-provisioner-password.age;
    path = "/var/lib/kubernetes/pki/provisioner-password";
    owner = "kubernetes";
    group = "kubernetes";
    mode = "0600";
  };
  age.secrets.k8s-service-account-key = {
    file = ../../../secrets/k8s-service-account-key.age;
    path = "/var/lib/kubernetes/pki/service-account-key.pem";
    owner = "kubernetes";
    group = "kubernetes";
    mode = "0600";
  };
  systemd.tmpfiles.rules = [
    "r /root/.ssh/authorized_keys"
    # C+ (recreate), not C: a CA rotation must be able to replace these on
    # deploy, and plain C never overwrites an existing file.
    "C+ /var/lib/kubernetes/pki/ca.pem 0644 kubernetes kubernetes - ${../../../k8s/certs/step-ca-root.pem}"
    "C+ /var/lib/kubernetes/pki/service-account.pem 0644 kubernetes kubernetes - ${../../../k8s/certs/k8s-service-account.pem}"
  ];

  # Store-signing key: without it a reinstalled node serves unsigned paths
  # that its peers silently reject.
  age.secrets.nix-signing-key = {
    file = ../../../secrets/nix-signing-key.age;
    path = "/etc/nix/signing-key";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # The nix-store-sharing key is root-owned because the nix daemon runs as
  # root and ssh picks up ~/.ssh/id_ed25519 as a default identity.
  age.secrets.nix-store-sharing-key = {
    file = ../../../secrets/nix-store-sharing-key.age;
    path = "/root/.ssh/id_ed25519";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # The AES key every Secret in etcd is encrypted with.
  # Owner is `kubernetes`, not root: the apiserver runs as User=kubernetes and
  # a root-only 0400 file makes it refuse to start. A secret is owned by the
  # service that READS it.
  age.secrets.k8s-encryption-config = {
    file = ../../../secrets/k8s-encryption-config.age;
    path = "/var/lib/kubernetes/secrets/encryption-config.yaml";
    owner = "kubernetes";
    group = "kubernetes";
    mode = "0400";
  };

  boot.kernelModules = [
    "iptable_nat"
    "iptable_filter"
    "iptable_mangle"
    "wireguard"
  ];

  nix.gc = {
    automatic = true;
    dates = "Sun 03:00";
    options = "--delete-older-than 21d";
  };

  systemd.services.containerd-image-gc = {
    description = "Prune unused containerd images";
    path = with pkgs; [ cri-tools ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.cri-tools}/bin/crictl rmi --prune";
    };
  };

  systemd.timers.containerd-image-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 03:30";
      Persistent = true;
    };
  };

  system.stateVersion = "25.11";

  networking.firewall.trustedInterfaces = [ "lan0" ];

  # Pod->host traffic arrives on lxc* while the return route is via
  # cilium_host, asymmetric, so strict reverse-path filtering silently drops
  # it. "loose" keeps anti-spoofing. Standard for Cilium hosts.
  networking.firewall.checkReversePath = "loose";

  # A 3-node etcd cluster survives node loss but not a bad upgrade or an errant
  # delete replicated to every member. Each snapshot is whole cluster state,
  # so any one restores it. 08:30, so it lands before the offsite sync.
  systemd.services.etcd-snapshot = {
    description = "Snapshot etcd to the NAS (age-encrypted)";
    after = [ "etcd.service" ];
    requires = [ "etcd.service" ];
    # Timer-driven oneshot, don't restart/wait on it during activation.
    restartIfChanged = false;
    path = with pkgs; [
      etcd
      age
      age-plugin-yubikey
      nfs-utils
      util-linux
      coreutils
      findutils
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "15min";
      ExecStart = pkgs.writeShellScript "etcd-snapshot" ''
        set -euo pipefail
        HOST="${config.networking.hostName}"
        DATE=$(date +%Y-%m-%d_%H%M%S)
        SNAP="/tmp/etcd-$HOST-$DATE.db"
        MNT=""
        cleanup() {
          rm -f "$SNAP"
          if [ -n "$MNT" ]; then
            umount "$MNT" 2>/dev/null || true
            rmdir "$MNT" 2>/dev/null || true
          fi
        }
        trap cleanup EXIT

        export ETCDCTL_API=3
        etcdctl \
          --endpoints=https://127.0.0.1:2379 \
          --cacert=/var/lib/kubernetes/pki/ca.pem \
          --cert=/var/lib/kubernetes/pki/etcd.pem \
          --key=/var/lib/kubernetes/pki/etcd-key.pem \
          snapshot save "$SNAP"

        # verify the snapshot is well-formed before shipping (best-effort:
        # status moved etcdctl->etcdutl across versions)
        ( etcdutl snapshot status "$SNAP" -w table \
          || etcdctl snapshot status "$SNAP" -w table \
          || echo "WARN: snapshot status check unavailable" )

        MNT=$(mktemp -d)
        # timeo=100 (10s) instead of the 60s default: a hard mount retries
        # forever anyway, the short cycle just makes recovery after a NAS
        # reboot prompt.
        mount -t nfs4 -o sec=sys,timeo=100,retrans=2 \
          nas.infra.homelab.invalid:/volume1/longhorn-backups "$MNT"
        mkdir -p "$MNT/etcd-backup"
        age ${ageRecipientArgs} -o "$MNT/etcd-backup/etcd-$HOST-$DATE.db.age" "$SNAP"
        # Short local retention: the offsite versioned snapshots keep 30 days
        # of point-in-time etcd, so hoarding 14 days here too just bloats every
        # snapshot (etcd x 3 nodes x N days). 3 days is ample as a live copy.
        find "$MNT/etcd-backup" -name "etcd-$HOST-*.db.age" -mtime +3 -delete
        sync
        umount "$MNT" && rmdir "$MNT"
        MNT=""
        echo "etcd snapshot shipped: etcd-$HOST-$DATE.db.age"
      '';
    };
  };

  systemd.timers.etcd-snapshot = {
    description = "Daily etcd snapshot to the NAS";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 08:30:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
