# LDAP

Users, groups and schema are declared in [config.nix](config.nix); apply with
`nix run .#lldap-bootstrap`. UID policy: humans 10000+, service accounts
11000+, below 10000 stays local to each host.

## Secrets (not in git)

On edenprairie, `/var/lib/private/lldap/private/`:

    user_pass            lldap admin password
    nas_bind_pass        nas-bind service account
    authelia_bind_pass   authelia-bind service account
    lldap.env            JWT_SECRET + SMTP password

On every LDAP client host: `/etc/ldap-bind-password`, distributed by
agenix (secrets/ldap-bind-password.age); rotate = update the .age, deploy, restart nslcd.

## Synology NAS

DSM owns SSSD and the LDAP join. What DSM updates lose, and one thing
restores: `scripts/dsm/nas-boot-restore.sh` runs from DSM Task Scheduler on
boot (root), self-heals, and lists every fix it applies in its header.
Redeploy it, the root CA and the scheduler task with `nix run .#nas-deploy`.
Run it manually:

    ssh nas "bash /volume1/data/scripts/nas-boot-restore.sh"
