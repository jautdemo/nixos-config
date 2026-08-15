#!/bin/bash
# Restore non-persistent config on Synology NAS after a DSM update.
# DSM owns SSSD and LDAP client config via its Domain/LDAP join.
# This script only restores items DSM doesn't manage:
#   - Root SSH access (PermitRootLogin prohibit-password)
#   - Step-CA TLS trust (mozilla CA store + symlinks)
#   - NFS idmapd GSS-Methods (nsswitch instead of synomap for Kerberos)
#   - NFS idmapd Local-Realms (map HOMELAB.INVALID realm to local users)
#   - SSSD use_fully_qualified_names = false (NFS idmapd needs short names)
#   - syslog-ng forwarding to the cluster's Alloy receiver
#   - node_exporter install/upgrade
#   - its own crontab entries (daily run + 5-minute --net-check selfheal)
# Deployed to /volume1/data/scripts/ on the NAS by `nix run .#nas-deploy`.
# Runs at boot via DSM Task Scheduler and daily/every-5-min via the
# self-installed crontab entries.
set -euo pipefail

# --net-check: the 5-minute cron path. The aqc111 USB NIC can break and
# take the box off the network while it runs fine; ladder mirrors the k8s
# hosts' network-selfheal. /tmp clears on boot, so the reboot sentinel and
# fail counter reset themselves.
GW="192.168.1.1"; NIC="eth2"; FAILS_F=/tmp/nas-selfheal.fails
if [[ "${1:-}" == "--net-check" ]]; then
    if ping -c1 -W2 "$GW" >/dev/null 2>&1; then rm -f "$FAILS_F"; exit 0; fi
    n=$(cat "$FAILS_F" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAILS_F"
    logger -t nas-selfheal "gateway unreachable ($n)" || true
    if [[ $n -lt 3 ]]; then
        ip link set "$NIC" down; sleep 2; ip link set "$NIC" up
    elif [[ $n -lt 5 ]]; then
        for d in /sys/bus/usb/drivers/aqc111/[0-9]*; do
            [[ -e "$d" ]] || continue
            dev=$(basename "$d")
            echo "$dev" > /sys/bus/usb/drivers/aqc111/unbind 2>/dev/null || true
            sleep 3
            echo "$dev" > /sys/bus/usb/drivers/aqc111/bind 2>/dev/null || true
        done
    elif [[ ! -f /tmp/nas-selfheal.rebooted ]]; then
        touch /tmp/nas-selfheal.rebooted
        logger -t nas-selfheal "rebooting to recover $NIC" || true
        sync; reboot
    fi
    exit 0
fi

SCRIPTS_DIR="/volume1/data/scripts"
STEP_CA_ROOT="$SCRIPTS_DIR/homelab-root-ca.crt"
CA_MOZILLA_DIR="/usr/share/ca-certificates/mozilla"
CA_CERT_LINK="/etc/ssl/certs/homelab-root-ca.pem"
CA_HASH_LINK="/etc/ssl/certs/84d12033.0"
CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
FIXES=0

echo "=== Synology NAS boot restore $(date) ==="

if [[ ! -f "$STEP_CA_ROOT" ]]; then
    echo "ERROR: Root CA not found at $STEP_CA_ROOT"
    echo "Run 'nix run .#nas-deploy' from the repo to deploy."
    exit 1
fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if grep -q "^PermitRootLogin prohibit-password" /etc/ssh/sshd_config 2>/dev/null; then
    echo "[ok] PermitRootLogin already set"
else
    echo "[fix] Enabling PermitRootLogin (key-only)"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || true
    FIXES=$((FIXES + 1))
fi

cp "$STEP_CA_ROOT" "$CA_MOZILLA_DIR/homelab-root-ca.crt"

ln -sf "$CA_MOZILLA_DIR/homelab-root-ca.crt" "$CA_CERT_LINK"

# Hash symlink for openldap TLS_CACERTDIR lookup
ln -sf homelab-root-ca.pem "$CA_HASH_LINK"

# Rebuild CA bundle from mozilla store
cat "$CA_MOZILLA_DIR"/*.crt > "$CA_BUNDLE"
echo "[ok] TLS trust updated"

echo "[fix] Restarting SSSD to apply updated TLS trust..."
systemctl restart sssd
sleep 3
echo "[ok] SSSD restarted"
FIXES=$((FIXES + 1))

# NFS Kerberos idmapd fix
# DSM sets GSS-Methods=static,synomap by default. The synomap plugin does its
# own direct LDAP bind which fails with lldap. Switch to nsswitch (uses SSSD).
IDMAPD="/etc/idmapd.conf"
if grep -q "^GSS-Methods=nsswitch" "$IDMAPD" 2>/dev/null; then
    echo "[ok] idmapd GSS-Methods already set to nsswitch"
else
    echo "[fix] Setting idmapd GSS-Methods to nsswitch (synomap incompatible with lldap)"
    sed -i 's/^GSS-Methods=.*/GSS-Methods=nsswitch/' "$IDMAPD"
    systemctl restart rpc-svcgssd 2>/dev/null || true
    FIXES=$((FIXES + 1))
fi

if grep -q "^Local-Realms=HOMELAB.INVALID" "$IDMAPD" 2>/dev/null; then
    echo "[ok] idmapd Local-Realms already set"
else
    echo "[fix] Adding Local-Realms=HOMELAB.INVALID to idmapd.conf"
    sed -i '/^Domain=/a Local-Realms=HOMELAB.INVALID' "$IDMAPD"
    kill "$(pidof idmapd)" 2>/dev/null || true
    sleep 1
    /usr/sbin/idmapd
    FIXES=$((FIXES + 1))
fi

SSSD_CONF="/etc/sssd/sssd.conf"
if grep -qE "^use_fully_qualified_names\s*=\s*false" "$SSSD_CONF" 2>/dev/null; then
    echo "[ok] SSSD use_fully_qualified_names already set to false"
else
    echo "[fix] Setting use_fully_qualified_names = false in SSSD"
    sed -i '/use_fully_qualified_names/d' "$SSSD_CONF"
    sed -i '/\[domain\/homelab.invalid\]/a use_fully_qualified_names = false' "$SSSD_CONF"
    systemctl restart sssd
    sleep 3
    FIXES=$((FIXES + 1))
fi

SYSLOG_HOST="syslog.infra.homelab.invalid"
SYSLOG_CONF="/etc/syslog-ng/patterndb.d/loki-forward.conf"
SYSLOG_EXPECTED='destination d_loki'
if grep -q "$SYSLOG_EXPECTED" "$SYSLOG_CONF" 2>/dev/null; then
    echo "[ok] syslog-ng Loki forwarding config present"
else
    echo "[fix] Installing syslog-ng Loki forwarding config"
    cat > "$SYSLOG_CONF" << SYSLOGEOF
# Forward all NAS logs to the cluster Alloy syslog receiver (TLS); Alloy relays to Loki.
# Deployed by nas-boot-restore.sh, survives DSM updates.

destination d_loki {
  syslog("$SYSLOG_HOST"
    port(1514)
    transport("tls")
    tls(
      ca-file("/etc/ssl/certs/ca-certificates.crt")
    )
  );
};

log {
  source(src);
  destination(d_loki);
};
SYSLOGEOF
    systemctl reload syslog-ng 2>/dev/null || systemctl restart syslog-ng 2>/dev/null
    FIXES=$((FIXES + 1))
fi

if [[ $FIXES -gt 0 ]]; then
    echo ""
    echo "$FIXES repair(s) applied - sending DSM notification"
    synodsmnotify -c admin "Boot Restore" "NAS boot restore applied $FIXES fix(es)." 2>/dev/null || true
else
    echo ""
    echo "Everything intact, no repairs needed."
fi

NODE_EXPORTER_VERSION="1.9.1"
# from the release's sha256sums.txt; bump together with the version
NODE_EXPORTER_SHA256="becb950ee80daa8ae7331d77966d94a611af79ad0d3307380907e0ec08f5b4e8"
BINARY="/usr/local/bin/node_exporter"

install_node_exporter() {
    local tarball="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${tarball}"
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "[fix] Installing node_exporter v${NODE_EXPORTER_VERSION}..."
    curl -fsSL "$url" -o "$tmpdir/$tarball"
    echo "${NODE_EXPORTER_SHA256}  $tmpdir/$tarball" | sha256sum -c - >/dev/null
    tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
    cp "$tmpdir/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "$BINARY"
    chmod 755 "$BINARY"
    rm -rf "$tmpdir"
}

# Daily re-run via crontab: DSM updates undo the fixes this script makes,
# and a boot-only task waits for a reboot nobody schedules. Self-heals the
# crontab line too, since DSM rewrites /etc/crontab on updates.
CRON_CHANGED=0
if ! grep -qF "nas-boot-restore.sh >>" /etc/crontab; then
    echo "[fix] Installing daily crontab entry"
    echo "0 4 * * *	root	bash /volume1/data/scripts/nas-boot-restore.sh >> /var/log/nas-boot-restore.log 2>&1" >> /etc/crontab
    CRON_CHANGED=1
fi
if ! grep -qF -- "--net-check" /etc/crontab; then
    echo "[fix] Installing 5-minute net-check crontab entry"
    echo "*/5 * * * *	root	bash /volume1/data/scripts/nas-boot-restore.sh --net-check" >> /etc/crontab
    CRON_CHANGED=1
fi
[[ $CRON_CHANGED -eq 1 ]] && { systemctl restart crond 2>/dev/null || synoservice --restart crond 2>/dev/null || true; }

if [[ ! -x "$BINARY" ]]; then
    install_node_exporter
elif ! "$BINARY" --version 2>&1 | grep -q "$NODE_EXPORTER_VERSION"; then
    echo "[fix] Upgrading node_exporter to v${NODE_EXPORTER_VERSION}..."
    install_node_exporter
else
    echo "[ok] node_exporter v${NODE_EXPORTER_VERSION} already installed"
fi

killall node_exporter 2>/dev/null || true
sleep 1
echo "[ok] Starting node_exporter on :9100"
"$BINARY" --web.listen-address=":9100" >> /var/log/node_exporter.log 2>&1 &

echo "Done."
