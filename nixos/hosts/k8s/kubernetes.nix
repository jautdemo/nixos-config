# Multi-master Kubernetes with step-ca PKI. Imported per host with
# keepalivedPriority and an optional autoUpgradeDay.
{
  keepalivedPriority ? 100,
  etcdClusterState ? "existing",
  autoUpgradeDay ? null,
}:
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../../../cluster.json);

  # Same nixpkgs as everything else on purpose: a separate pin splits the
  # services.kubernetes MODULE from the binary it configures.
  hostname = config.networking.hostName;
  nodeIP = cluster.nodes.${hostname};
  apiVIP = cluster.apiVIP;
  apiserverURL = "https://${apiVIP}:6443";
  nodes = cluster.nodes;

  etcdServers = lib.mapAttrsToList (_: ip: "https://${ip}:2379") nodes;
  etcdInitialCluster = lib.mapAttrsToList (name: ip: "${name}=https://${ip}:2380") nodes;

  pki = "/var/lib/kubernetes/pki";

  # Helper: build a kubeconfig file in the Nix store, referencing on-disk certs
  mkKubeconfig =
    name: certFile: keyFile:
    pkgs.writeText "${name}-kubeconfig" (
      builtins.toJSON {
        apiVersion = "v1";
        kind = "Config";
        clusters = [
          {
            name = "local";
            cluster = {
              certificate-authority = "${pki}/ca.pem";
              server = apiserverURL;
            };
          }
        ];
        users = [
          {
            inherit name;
            user = {
              client-certificate = certFile;
              client-key = keyFile;
            };
          }
        ];
        contexts = [
          {
            context = {
              cluster = "local";
              user = name;
            };
            name = "local";
          }
        ];
        current-context = "local";
      }
    );

  clusterAdminKubeconfig =
    mkKubeconfig "cluster-admin" "${pki}/cluster-admin.pem"
      "${pki}/cluster-admin-key.pem";
in
{
  imports = [
    ../../modules/k8s-pki.nix
    (import ../../modules/k8s-upgrades.nix { inherit autoUpgradeDay; })
  ];

  # FQDN first: reverse DNS must yield the FQDN or Kerberos NFS fails.
  networking.hosts =
    (lib.mapAttrs' (name: ip: {
      name = ip;
      value = [
        "${name}.infra.homelab.invalid"
        name
      ];
    }) nodes)
    // (lib.mapAttrs'
      (name: ip: {
        name = ip;
        value = [
          "${name}.infra.homelab.invalid"
          name
        ];
      })
      (lib.filterAttrs (_: v: builtins.isString v && builtins.match "[0-9.]+" v != null) cluster.infra)
    );

  boot.kernelModules = [
    "br_netfilter"
    "overlay"
    "ip_vs"
    "ip_vs_rr"
    "ip_vs_wrr"
    "ip_vs_sh"
    "iscsi_tcp" # Longhorn iSCSI
    # Longhorn encrypted volumes. Without it, a reboot leaves every encrypted
    # volume unable to attach (KernelModulesLoaded=False [dm_crypt]).
    "dm_crypt"
  ];

  networking.firewall.allowedTCPPorts = [
    6443 # API server
    2379 # etcd client
    2380 # etcd peer
    10250 # kubelet
    10257 # controller-manager
    10259 # scheduler
    3260 # iSCSI (Longhorn)
    9500 # Longhorn manager
    9100 # node-exporter (Prometheus)
    2381 # etcd metrics (Prometheus)
    4244
    # Cilium agent hubble-peer service (hostNetwork; hubble-relay dials this
    # via the hubble-peer ClusterIP, whose DNAT target is this host port,
    # pod-sourced traffic isn't covered by trustedInterfaces the way a
    # directly LAN-sourced connection is)
  ];

  services.etcd = {
    enable = true;
    name = config.networking.hostName;

    listenClientUrls = [
      "https://${nodeIP}:2379"
      "https://127.0.0.1:2379"
    ];
    listenPeerUrls = [ "https://${nodeIP}:2380" ];
    advertiseClientUrls = [ "https://${nodeIP}:2379" ];
    initialAdvertisePeerUrls = [ "https://${nodeIP}:2380" ];
    initialCluster = etcdInitialCluster;
    initialClusterToken = "k8s-etcd";
    initialClusterState = etcdClusterState;

    clientCertAuth = true;
    peerClientCertAuth = true;
    certFile = "${pki}/etcd.pem";
    keyFile = "${pki}/etcd-key.pem";
    trustedCaFile = "${pki}/ca.pem";
    peerCertFile = "${pki}/etcd.pem";
    peerKeyFile = "${pki}/etcd-key.pem";
    peerTrustedCaFile = "${pki}/ca.pem";

    extraConf = {
      LISTEN_METRICS_URLS = "http://0.0.0.0:2381";
    };
  };

  services.kubernetes = {
    easyCerts = false;
    masterAddress = apiVIP;
    apiserverAddress = apiserverURL;
    caFile = "${pki}/ca.pem";

    # Cilium's clusterPoolIPv4PodCIDRList must carry the same value; a mismatch
    # crashes kube-controller-manager outright.
    clusterCidr = cluster.podCidr;

    apiserver = {
      enable = true;
      securePort = 6443;
      advertiseAddress = nodeIP;
      allowPrivileged = true; # needed for Longhorn, CNI plugins
      # Explicit rather than inherited from the module default, which would
      # move the whole Service network under us on a nixpkgs bump.
      serviceClusterIpRange = cluster.serviceCidr;

      tlsCertFile = "${pki}/kube-apiserver.pem";
      tlsKeyFile = "${pki}/kube-apiserver-key.pem";
      clientCaFile = "${pki}/ca.pem";

      serviceAccountKeyFile = "${pki}/service-account.pem";
      serviceAccountSigningKeyFile = "${pki}/service-account-key.pem";

      kubeletClientCaFile = "${pki}/ca.pem";
      kubeletClientCertFile = "${pki}/apiserver-kubelet-client.pem";
      kubeletClientKeyFile = "${pki}/apiserver-kubelet-client-key.pem";

      proxyClientCertFile = "${pki}/apiserver-proxy-client.pem";
      proxyClientKeyFile = "${pki}/apiserver-proxy-client-key.pem";

      extraOpts = lib.concatStringsSep " " [
        "--requestheader-client-ca-file=${pki}/ca.pem"
        "--requestheader-allowed-names=front-proxy-client"
        "--requestheader-extra-headers-prefix=X-Remote-Extra-"
        "--requestheader-group-headers=X-Remote-Group"
        "--requestheader-username-headers=X-Remote-User"
        # 30, not the 300 default: a dead node's pods reschedule in half a
        # minute instead of five, at the price of evicting during any >30s
        # network blip. With two spare nodes the reschedule is cheap.
        "--default-unreachable-toleration-seconds=30"
        "--default-not-ready-toleration-seconds=30"
        "--audit-policy-file=/etc/kubernetes/audit-policy.yaml"
        "--audit-log-path=/var/log/kubernetes/audit.log"
        "--audit-log-maxage=30"
        "--audit-log-maxbackup=10"
        "--audit-log-maxsize=100"
        # Encryption at rest. Without this the apiserver writes Secret values
        # to etcd as plain base64, so an etcd snapshot is a full dump of every
        # secret
        "--encryption-provider-config=${config.age.secrets.k8s-encryption-config.path}"
      ];

      etcd = {
        servers = etcdServers;
        certFile = "${pki}/apiserver-etcd-client.pem";
        keyFile = "${pki}/apiserver-etcd-client-key.pem";
        caFile = "${pki}/ca.pem";
      };
    };

    controllerManager = {
      enable = true;
      bindAddress = "0.0.0.0";
      allocateNodeCIDRs = false;
      serviceAccountKeyFile = "${pki}/service-account-key.pem";
      rootCaFile = "${pki}/ca.pem";
      extraOpts =
        let
          kubeconfig =
            mkKubeconfig "kube-controller-manager" "${pki}/kube-controller-manager-client.pem"
              "${pki}/kube-controller-manager-client-key.pem";
        in
        lib.concatStringsSep " " [
          "--secure-port=10257"
          "--authentication-kubeconfig=${kubeconfig}"
          "--authorization-kubeconfig=${kubeconfig}"
        ];
      kubeconfig = {
        server = apiserverURL;
        certFile = "${pki}/kube-controller-manager-client.pem";
        keyFile = "${pki}/kube-controller-manager-client-key.pem";
      };
    };

    scheduler = {
      enable = true;
      address = "0.0.0.0";
      extraOpts =
        let
          kubeconfig =
            mkKubeconfig "kube-scheduler" "${pki}/kube-scheduler-client.pem"
              "${pki}/kube-scheduler-client-key.pem";
        in
        lib.concatStringsSep " " [
          "--secure-port=10259"
          "--authentication-kubeconfig=${kubeconfig}"
          "--authorization-kubeconfig=${kubeconfig}"
        ];
      kubeconfig = {
        server = apiserverURL;
        certFile = "${pki}/kube-scheduler-client.pem";
        keyFile = "${pki}/kube-scheduler-client-key.pem";
      };
    };

    kubelet = {
      enable = true;
      unschedulable = false;
      clientCaFile = "${pki}/ca.pem";
      tlsCertFile = "${pki}/kubelet.pem";
      tlsKeyFile = "${pki}/kubelet-key.pem";
      kubeconfig = {
        server = apiserverURL;
        certFile = "${pki}/kubelet-client.pem";
        keyFile = "${pki}/kubelet-client-key.pem";
      };
      nodeIp = nodeIP;
      # The kube-dns Service clusterIP; the regenerate-manifests app splices the same value
      # into the Service manifest.
      clusterDns = [ cluster.kubeDns ];
      # --seccomp-default makes RuntimeDefault the cluster-wide default for any
      # container that does not set its own profile. Pods can still override.
      extraOpts = "--allowed-unsafe-sysctls=net.ipv4.ip_forward,net.ipv4.conf.all.src_valid_mark --seccomp-default=true";
    };

    # Cilium's kubeProxyReplacement owns all Service routing.
    proxy.enable = false;

    # Cilium owns the datapath. cni.config is forced empty so the module stops
    # writing a read-only conf into /etc/cni/net.d. cni.packages = [] does not
    # stop the module's `rm /opt/cni/bin/*` - see the preStart override below.
    flannel.enable = false;
    kubelet.cni.config = lib.mkForce [ ];
    kubelet.cni.packages = lib.mkForce [ ];
    kubelet.cni.configDir = "/var/lib/cni/conf";

    # Required: the module defaults this true whenever kubernetes is active and
    # would re-seed its own CoreDNS image on every kubelet start. clusterDns
    # above must match the kube-dns Service.
    addons.dns.enable = false;
  };

  systemd.services.kube-apiserver.after = [ "etcd.service" ];

  # The module's preStart unconditionally runs `rm /opt/cni/bin/*` on every
  # kubelet restart, and Cilium only reinstalls when its own pod restarts, so
  # a plain switch can leave a node with no CNI.
  #
  # must keep the module's other preStart job: seeding the pause image.
  # docker.io/library/pause:latest does not exist upstream and only resolves
  # because preStart imports the local build.
  systemd.services.kubelet.preStart = lib.mkForce (
    lib.concatMapStrings (img: ''
      echo "Seeding container image: ${img}"
      ${
        if (lib.hasSuffix "gz" img) then
          ''${pkgs.gzip}/bin/zcat "${img}" | ${pkgs.containerd}/bin/ctr -n k8s.io image import -''
        else
          ''${pkgs.coreutils}/bin/cat "${img}" | ${pkgs.containerd}/bin/ctr -n k8s.io image import -''
      }
    '') config.services.kubernetes.kubelet.seedDockerImages
  );

  services.keepalived = {
    enable = true;
    openFirewall = true;

    vrrpScripts.chk_apiserver = {
      script = "${pkgs.curl}/bin/curl -k --silent --max-time 2 --output /dev/null https://localhost:6443/healthz";
      interval = 3;
      # -50 must exceed the spread of the host priorities (110/100/90): a
      # failed check has to drop the primary below every healthy peer.
      weight = -50;
      fall = 3; # ~9s of failed checks before failover, ~6s to return
      rise = 2;
      user = "root";
    };

    vrrpInstances.k8s-apiserver = {
      # Deterministic on every node: a systemd.network link rule
      # renames the r8152 USB NIC to lan0.
      interface = "lan0";
      state = "BACKUP"; # both start BACKUP; highest priority wins
      virtualRouterId = 51;
      priority = keepalivedPriority;
      virtualIps = [ { addr = "${apiVIP}/24"; } ];
      trackScripts = [ "chk_apiserver" ];
    };
  };

  environment.etc."kubernetes/cluster-admin.kubeconfig".source = clusterAdminKubeconfig;

  # Metadata level throughout. Secrets and configmaps stay at Metadata rather
  # than RequestResponse specifically so their plaintext never reaches the log.
  environment.etc."kubernetes/audit-policy.yaml".text = ''
    apiVersion: audit.k8s.io/v1
    kind: Policy
    rules:
      - level: None
        resources:
          - group: ""
            resources: ["events"]
      - level: None
        userGroups: ["system:nodes"]
        verbs: ["get", "list", "watch"]
      - level: None
        nonResourceURLs:
          - "/healthz*"
          - "/livez*"
          - "/readyz*"
          - "/metrics"
          - "/version"
      - level: Metadata
        resources:
          - group: ""
            resources: ["secrets", "configmaps"]
      - level: Metadata
  '';
  environment.variables.KUBECONFIG = "/etc/kubernetes/cluster-admin.kubeconfig";
  security.sudo.extraConfig = ''
    Defaults env_keep += "KUBECONFIG"
  '';

  services.openiscsi = {
    enable = true;
    name = "iqn.2025-01.nixos.k8s:${hostname}";
  };

  # iscsiadm parses every record under /etc/iscsi/nodes on every call and
  # aborts with exit 7 if one names a parameter it does not know - which
  # happens in both directions across the 2.1.11/2.1.12 rename of
  # node.session.{conn,sess}_reopen_log_freq. Every Longhorn attach then
  # fails while the node looks healthy. The records are pure cache.
  systemd.services.iscsi-node-db-sanitize = {
    description = "Remove iSCSI node records the running open-iscsi cannot parse";
    wantedBy = [ "multi-user.target" ];
    before = [
      "iscsid.service"
      "kubelet.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -u
      NODES=/etc/iscsi/nodes
      [ -d "$NODES" ] || exit 0

      # iscsiadm names one bad record per invocation, so loop. The bound is a
      # safety net against an unparseable error format, not an expected count.
      i=0
      while [ "$i" -lt 500 ]; do
        i=$((i + 1))

        if err=$(${pkgs.openiscsi}/bin/iscsiadm -m node -o show 2>&1 >/dev/null); then
          exit 0
        fi
        # Empty DB is a fine resting state; Longhorn repopulates on attach.
        case "$err" in
          *"No records found"*) exit 0 ;;
        esac

        bad=$(printf '%s\n' "$err" \
          | grep -oE "$NODES/[^ ]+" \
          | head -1)
        if [ -z "$bad" ]; then
          echo "iscsi-node-db-sanitize: DB unreadable but no record named, leaving it alone:" >&2
          printf '%s\n' "$err" >&2
          exit 0
        fi

        dir=$(dirname "$bad")
        echo "iscsi-node-db-sanitize: removing unparseable record $dir"
        rm -rf "$dir"
        rmdir "$(dirname "$dir")" 2>/dev/null || true
      done

      echo "iscsi-node-db-sanitize: gave up after $i records; DB still unreadable" >&2
    '';
  };

  systemd.tmpfiles.rules = [
    # CNI conf + bin dirs Cilium installs into (kubelet reads confDir here),
    # real writable dirs, unlike the module's read-only /etc/cni/net.d symlink.
    "d /var/lib/cni/conf 0755 root root -"
    "d /opt/cni/bin 0755 root root -"
    "L+ /usr/local/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/local/bin/dmsetup - - - - ${pkgs.lvm2}/bin/dmsetup"
    "L+ /usr/local/bin/nsenter - - - - ${pkgs.util-linux}/bin/nsenter"
    "L+ /usr/local/bin/blkid - - - - ${pkgs.util-linux}/bin/blkid"
    "L+ /usr/local/bin/lsblk - - - - ${pkgs.util-linux}/bin/lsblk"
    "L+ /usr/local/bin/findmnt - - - - ${pkgs.util-linux}/bin/findmnt"
    "L+ /usr/local/bin/mkfs.ext4 - - - - ${pkgs.e2fsprogs}/bin/mkfs.ext4"
    "L+ /usr/local/bin/cryptsetup - - - - ${pkgs.cryptsetup}/bin/cryptsetup"
    "d /usr/bin 0755 root root -"
    "d /usr/sbin 0755 root root -"
    "d /var/log/kubernetes 0750 kubernetes kubernetes -"
    "L+ /usr/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/sbin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
  ];

  boot.supportedFilesystems = [ "nfs" ];
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes
    etcd
    kubernetes-helm # helm CLI for deploying Longhorn
    nfs-utils # NFSv4 client (Longhorn backups + RWX)
    cryptsetup # Longhorn volume encryption
    lvm2 # device-mapper (dmsetup)
    util-linux # findmnt, blkid, lsblk
    curl
    gawk
    step-cli # step CA client (cert requests)
  ];

  # Bias the kernel toward killing a build rather than the control-plane daemons
  # this node exists to run. containerd already gets -999 from the NixOS module.
  systemd.services.etcd.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.kube-apiserver.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.kubelet.serviceConfig.OOMScoreAdjust = -900;
}
