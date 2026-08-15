# Unattended patching for a control-plane node. Reboots are kured's job, not
# autoUpgrade's; this only stages them and hands over.
{
  autoUpgradeDay ? null,
}:
{
  config,
  pkgs,
  lib,
  ...
}:

let
  hostname = config.networking.hostName;
in
{
  # "Reboot pending" means the active generation boots a different
  # kernel/initrd than the running one - comparing those paths, not the whole
  # system path, which would fire for any config change.
  systemd.services.k8s-reboot-sentinel = {
    description = "Flag a pending reboot for kured when the kernel changed";
    serviceConfig.Type = "oneshot";
    script = ''
      booted=$(readlink -f /run/booted-system/{initrd,kernel,kernel-modules} 2>/dev/null || true)
      current=$(readlink -f /run/current-system/{initrd,kernel,kernel-modules} 2>/dev/null || true)
      if [ "$booted" != "$current" ]; then
        echo "kernel/initrd changed since boot - flagging for kured"
        touch /var/run/reboot-required
      else
        rm -f /var/run/reboot-required
      fi
    '';
  };
  systemd.timers.k8s-reboot-sentinel = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
    };
  };

  system.autoUpgrade = lib.mkIf (autoUpgradeDay != null) {
    enable = true;
    flake = "/etc/nixos-config";
    flags = [
      "--update-input"
      "nixpkgs"
      "--no-write-lock-file"
      "-L"
    ];
    dates = "${autoUpgradeDay} 03:00";
    randomizedDelaySec = "30min";

    # False on purpose: kured owns reboots.
    allowReboot = false;
  };

  # These nodes carry live etcd/apiserver/kubelet during their own patch window,
  # so the build gets a bounded budget rather than contending with the control
  # plane it is patching underneath.
  systemd.services.nixos-upgrade.serviceConfig = lib.mkIf (autoUpgradeDay != null) {
    MemoryHigh = "8G";
    MemoryMax = "10G";
    CPUQuota = "600%";

    # A nixpkgs bump restarts containerd, killing longhorn's instance-manager
    # and leaving the kernel holding iSCSI sessions to a dead pod's IP. Those
    # cannot be reaped, so no engine starts here until a reboot. Draining
    # first logs them out while the target is alive. ExecStartPre failing
    # ABORTS the upgrade - better to skip a week than strand the storage.
    ExecStartPre = "${pkgs.writeShellScript "k8s-upgrade-drain" ''
      set -eu
      K="${pkgs.kubectl}/bin/kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig"
      # Marks the cordon PLANNED so cluster-healthcheck stays quiet. A
      # timestamp, not a flag, so it expires by itself, the check honours it
      # for 30 minutes and reports a still-cordoned node after that regardless.
      $K annotate node ${hostname} \
        maintenance.homelab.invalid/drain-started="$(date +%s)" --overwrite >/dev/null || true
      echo "cordoning ${hostname} before upgrade"
      $K cordon ${hostname}
      echo "draining ${hostname}"
      $K drain ${hostname} --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
    ''}";
    # Re-evaluate the sentinel immediately rather than waiting for its
    # 15-minute timer; that gap dominates the upgrade-to-reboot delay.
    ExecStartPost = "${pkgs.systemd}/bin/systemctl start --no-block k8s-reboot-sentinel.service";

    # Hand off to kured without bouncing the workload twice: if a kernel is
    # staged, kured is about to drain anyway. If no reboot is pending -
    # including a failed upgrade - uncordon now, because nothing else will.
    ExecStopPost = "${pkgs.writeShellScript "k8s-upgrade-uncordon" ''
      set -u
      K="${pkgs.kubectl}/bin/kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig"
      if [ -f /var/run/reboot-required ]; then
        echo "reboot pending - leaving ${hostname} cordoned; kured will reboot and uncordon it"
        exit 0
      fi
      $K uncordon ${hostname} || echo "WARN: could not uncordon ${hostname}" >&2
    ''}";
  };
}
