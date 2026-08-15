# nix run .#lldap-bootstrap
# Ensures lldap schema (custom attributes), users, groups, and memberships
# match the declarative LDAP spec.
# Reads the admin password from edenprairie. Idempotent.
#
# The spec travels as JSON into one static script: every GraphQL request is
# assembled with jq --arg/--argjson, so quoting is jq's job and no config
# value is ever spliced into a query or a remote shell string by hand.
{
  pkgs,
  lib,
  cluster,
  ldapConfig,
  mkApp,
}:
let
  cfg = pkgs.writeText "ldap-config.json" (builtins.toJSON ldapConfig);
in
mkApp {
  name = "lldap-bootstrap";
  runtimeInputs = [
    pkgs.openssh
    pkgs.curl
    pkgs.jq
    pkgs.openssl
    pkgs.sops
    pkgs.coreutils
  ];
  # SC2016: GraphQL variables ($id, $name, ...) sit in single-quoted query
  # strings precisely so the shell cannot expand them.
  excludeShellChecks = [
    "SC2029"
    "SC2016"
  ];
  text = ''
    CFG="${cfg}"
    CA="root@${cluster.infra.edenprairie}"
    # ssh rides the jump host from anywhere, plain http does not: from
    # outside the LAN, tunnel first (ssh -L 17170:127.0.0.1:17170 to the
    # CA host) and point the override at it.
    LLDAP_URL="''${LLDAP_URL_OVERRIDE:-http://${cluster.infra.edenprairie}:17170}"

    # A hole in the spec must fail here, before anything is mutated, not
    # surface later as a literal "null" written into an attribute.
    jq -e '
      ([.users[] | has("email") and has("displayName") and has("firstName")
         and has("lastName") and has("uidnumber") and has("gidnumber")
         and has("sshPublicKeys")] | all)
      and ([.serviceAccounts[] | has("email") and has("displayName")
         and has("firstName") and has("lastName")
         and (has("uidnumber") == has("gidnumber"))] | all)
    ' "$CFG" >/dev/null || {
      echo "FATAL: ldap config is missing required fields" >&2; exit 1; }

    PW=$(ssh -o ConnectTimeout=5 "$CA" "cat /var/lib/private/lldap/private/user_pass")

    LOGIN_BODY=$(jq -cn --arg password "$PW" '{username: "admin", password: $password}')
    TOKEN=$(curl -sf -X POST "$LLDAP_URL/auth/simple/login" \
      -H 'Content-Type: application/json' \
      -d "$LOGIN_BODY" | jq -r .token)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
      echo "FATAL: failed to authenticate" >&2; exit 1
    fi

    # gql QUERY [VARIABLES_JSON]
    # every failure mode must return non-zero: transport error, empty body,
    # unparseable body, GraphQL `errors`, missing `data`. List queries
    # abort the run when gql fails and mutations run under errexit, so a
    # request that fails while returning 0 silently means a missing entity
    # or a skipped mutation goes unnoticed.
    gql() {
      local query="$1" body result rc
      if [ "$#" -ge 2 ]; then
        body=$(jq -cn --arg q "$query" --argjson v "$2" \
          '{query: $q, variables: $v}') || {
          echo "GraphQL request build failed for: $query" >&2; return 1; }
      else
        body=$(jq -cn --arg q "$query" '{query: $q}') || {
          echo "GraphQL request build failed for: $query" >&2; return 1; }
      fi
      result=$(curl -sS -m 20 -X POST "$LLDAP_URL/api/graphql" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $TOKEN" \
        -d "$body" 2>&1)
      rc=$?
      if [ $rc -ne 0 ]; then
        echo "GraphQL transport failure (curl exit $rc): $result" >&2
        return 1
      fi
      if [ -z "$result" ]; then
        echo "GraphQL returned an EMPTY response for: $query" >&2
        return 1
      fi
      if ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
        echo "GraphQL returned unparseable output: $result" >&2
        return 1
      fi
      if printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1; then
        echo "GraphQL error: $result" >&2
        return 1
      fi
      if ! printf '%s' "$result" | jq -e 'has("data") and .data != null' >/dev/null 2>&1; then
        echo "GraphQL response carried no data: $result" >&2
        return 1
      fi
      printf '%s' "$result"
    }

    # createUser takes no password field, so this call is what actually
    # sets one - without it the account exists and cannot be logged into.
    # The password never rides inside the remote command string: it goes
    # over stdin and the remote shell reads it with $(cat), so no value
    # can terminate the quoting and run as shell on the CA.
    set_password_on_ca() {
      local ruid
      ruid=$(printf '%q' "$1")
      ssh "$CA" "LLDAP_USER_PASSWORD=\"\$(cat)\" lldap_set_password -b http://localhost:17170 --admin-username admin --admin-password \"\$(cat /var/lib/private/lldap/private/user_pass)\" -u $ruid"
    }

    echo "==> Ensuring custom attributes..."
    SCHEMA_JSON=$(gql '{ schema { userSchema { attributes { name } } } }') || {
      echo "FATAL: could not list user attributes - refusing to guess" >&2; exit 1; }
    mapfile -t ATTR_ROWS < <(jq -c '.customUserAttributes[]' "$CFG")
    for attr in "''${ATTR_ROWS[@]}"; do
      name=$(jq -r '.name' <<<"$attr")
      type=$(jq -r '.type' <<<"$attr")
      # GraphQL enums cannot travel as String variables, so the bare token
      # is inlined into the query - gated to enum shape so nothing else
      # can ride along.
      if ! [[ "$type" =~ ^[A-Z_]+$ ]]; then
        echo "FATAL: attribute type '$type' is not a bare enum token" >&2; exit 1
      fi
      if ! printf '%s' "$SCHEMA_JSON" | jq -e --arg n "$name" \
           '.data.schema.userSchema.attributes[] | select(.name == $n)' >/dev/null 2>&1; then
        echo "    Creating attribute: $name ($type)"
        gql "mutation(\$name: String!, \$isList: Boolean!) { addUserAttribute(name: \$name, attributeType: $type, isList: \$isList, isVisible: true, isEditable: true) { ok } }" \
          "$(jq -c '{name: .name, isList: .isList}' <<<"$attr")" >/dev/null
      fi
    done

    echo "==> Ensuring users..."
    # Existence must distinguish "absent" from "could not tell".
    # `user(userId:)` returns HTTP 200 with an `errors` array for a
    # missing user, indistinguishable from a real error once it passes
    # through gql. Listing keeps the cases separate: a failed list aborts,
    # an empty match means absent. One list serves every check below;
    # users created in this run are added to it rather than refetched.
    USERS_JSON=$(gql '{ users { id } }') || {
      echo "FATAL: could not list users - refusing to guess who exists" >&2; exit 1; }
    declare -A USER_EXISTS=()
    while IFS= read -r u; do USER_EXISTS["$u"]=1; done \
      < <(printf '%s' "$USERS_JSON" | jq -r '.data.users[].id')

    mapfile -t USER_IDS < <(jq -r '.users | keys[]' "$CFG")
    for uid in "''${USER_IDS[@]}"; do
      user=$(jq -c --arg u "$uid" '.users[$u]' "$CFG")
      if [ -z "''${USER_EXISTS[$uid]:-}" ]; then
        echo "    Creating user: $uid"
        echo "    Set a temporary password for $uid:"
        read -rsp "    Password: " TMPPASS; echo
        gql 'mutation($id: String!, $email: String!, $displayName: String!, $firstName: String!, $lastName: String!) { createUser(user: {id: $id, email: $email, displayName: $displayName, firstName: $firstName, lastName: $lastName}) { id } }' \
          "$(jq -c --arg u "$uid" '{id: $u, email: .email, displayName: .displayName, firstName: .firstName, lastName: .lastName}' <<<"$user")" >/dev/null
        USER_EXISTS["$uid"]=1
        printf '%s' "$TMPPASS" | set_password_on_ca "$uid"
      fi

      # Ensure POSIX attributes
      gql 'mutation($id: String!, $uidnumber: String!, $gidnumber: String!) { updateUser(user: {id: $id, removeAttributes: ["uidnumber", "gidnumber"], insertAttributes: [{name: "uidnumber", value: [$uidnumber]}, {name: "gidnumber", value: [$gidnumber]}]}) { ok } }' \
        "$(jq -c --arg u "$uid" '{id: $u, uidnumber: (.uidnumber|tostring), gidnumber: (.gidnumber|tostring)}' <<<"$user")" >/dev/null
    done

    echo "==> Ensuring service accounts..."
    mapfile -t SVC_IDS < <(jq -r '.serviceAccounts | keys[]' "$CFG")
    for uid in "''${SVC_IDS[@]}"; do
      svc=$(jq -c --arg u "$uid" '.serviceAccounts[$u]' "$CFG")
      # needsPassword defaults to true; only an explicit false disables
      # the generated password (POSIX-only identity, no login).
      wants_password=$(jq -r 'if has("needsPassword") then .needsPassword else true end' <<<"$svc")
      if [ -z "''${USER_EXISTS[$uid]:-}" ]; then
        echo "    Creating service account: $uid"
        if [ "$uid" = "authelia-bind" ] && [ "$wants_password" = "true" ]; then
          # The generated bind password must land in k8s/authelia/secret.yaml
          # in the same run (the authelia Deployment reads ldap-password
          # from there), or the CA copy and the cluster copy desync. The
          # sops write needs the operator's age key, exactly like
          # protonmail-bridge-setup; prove decryption works before creating
          # the account, because an account created without the sync would
          # be skipped as already existing on the next run.
          if ! sops -d k8s/authelia/secret.yaml >/dev/null 2>&1; then
            echo "Cannot decrypt k8s/authelia/secret.yaml." >&2
            echo "Put the SOPS age key at ~/Library/Application Support/sops/age/keys.txt" >&2
            echo "(macOS location - sops does NOT read ~/.config/sops on darwin)," >&2
            echo "or set SOPS_AGE_KEY_FILE. Aborting before creating $uid." >&2
            exit 1
          fi
        fi
        gql 'mutation($id: String!, $email: String!, $displayName: String!, $firstName: String!, $lastName: String!) { createUser(user: {id: $id, email: $email, displayName: $displayName, firstName: $firstName, lastName: $lastName}) { id } }' \
          "$(jq -c --arg u "$uid" '{id: $u, email: .email, displayName: .displayName, firstName: .firstName, lastName: .lastName}' <<<"$svc")" >/dev/null
        USER_EXISTS["$uid"]=1
        if [ "$wants_password" = "true" ]; then
          SVC_PW=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
          # Underscores: the live files and their consumers use
          # nas_bind_pass, not nas-bind_pass.
          PASS_FILE="/var/lib/private/lldap/private/''${uid//-/_}_pass"
          printf '%s' "$SVC_PW" | set_password_on_ca "$uid"
          printf '%s' "$SVC_PW" | ssh "$CA" "cat > $(printf '%q' "$PASS_FILE") && chmod 600 $(printf '%q' "$PASS_FILE")"
          echo "    Password generated and stored at $PASS_FILE"
          if [ "$uid" = "authelia-bind" ]; then
            # authelia: one key inside the shared authelia Secret.
            # `data` (not stringData), so the value is base64 of the
            # password. Same sops set pattern as protonmail-bridge-setup.
            SVC_PW_B64=$(printf '%s' "$SVC_PW" | base64 | tr -d '\n')
            sops set k8s/authelia/secret.yaml '["data"]["ldap-password"]' "\"$SVC_PW_B64\""
            echo "    updated ldap-password in k8s/authelia/secret.yaml"
            echo "    commit + push so Flux applies it, then: kubectl -n authelia rollout restart deployment authelia"
          fi
        else
          echo "    No password needed for $uid (POSIX-only identity)"
        fi
      fi
      if jq -e 'has("uidnumber")' <<<"$svc" >/dev/null; then
        # Ensure POSIX attributes for service account
        gql 'mutation($id: String!, $uidnumber: String!, $gidnumber: String!) { updateUser(user: {id: $id, removeAttributes: ["uidnumber", "gidnumber"], insertAttributes: [{name: "uidnumber", value: [$uidnumber]}, {name: "gidnumber", value: [$gidnumber]}]}) { ok } }' \
          "$(jq -c --arg u "$uid" '{id: $u, uidnumber: (.uidnumber|tostring), gidnumber: (.gidnumber|tostring)}' <<<"$svc")" >/dev/null
      fi
    done

    echo "==> Syncing SSH keys..."
    for uid in "''${USER_IDS[@]}"; do
      user=$(jq -c --arg u "$uid" '.users[$u]' "$CFG")
      nkeys=$(jq -r '.sshPublicKeys | length' <<<"$user")
      if [ "$nkeys" -eq 0 ]; then
        echo "    $uid: no SSH keys defined"
      else
        echo "    $uid: $nkeys keys"
        gql 'mutation($id: String!, $keys: [String!]!) { updateUser(user: {id: $id, removeAttributes: ["sshpublickey"], insertAttributes: [{name: "sshpublickey", value: $keys}]}) { ok } }' \
          "$(jq -c --arg u "$uid" '{id: $u, keys: .sshPublicKeys}' <<<"$user")" >/dev/null
      fi
    done

    echo "==> Ensuring groups..."
    # One group list serves the existence checks and the membership loop.
    # createGroup extends the local copy with the id it returns; the
    # membership read-back replaces the copy wholesale.
    GROUPS_JSON=$(gql '{ groups { id displayName users { id } } }') || {
      echo "FATAL: could not list groups" >&2; exit 1; }
    mapfile -t GROUP_NAMES < <(jq -r '.groups[]' "$CFG")
    for grp in "''${GROUP_NAMES[@]}"; do
      if ! printf '%s' "$GROUPS_JSON" | jq -e --arg g "$grp" \
           '.data.groups[] | select(.displayName == $g)' >/dev/null 2>&1; then
        echo "    Creating group: $grp"
        CREATED=$(gql 'mutation($name: String!) { createGroup(name: $name) { id } }' \
          "$(jq -cn --arg name "$grp" '{name: $name}')")
        NEW_GID=$(printf '%s' "$CREATED" | jq '.data.createGroup.id')
        if [ -z "$NEW_GID" ] || [ "$NEW_GID" = "null" ]; then
          echo "FATAL: createGroup for $grp returned no id" >&2; exit 1
        fi
        GROUPS_JSON=$(printf '%s' "$GROUPS_JSON" | jq --arg g "$grp" --argjson id "$NEW_GID" \
          '.data.groups += [{id: $id, displayName: $g, users: []}]')
      fi
    done

    echo "==> Ensuring group memberships..."
    mapfile -t MEMBER_GROUPS < <(jq -r '.memberships | keys[]' "$CFG")
    for grp in "''${MEMBER_GROUPS[@]}"; do
      mapfile -t MEMBERS < <(jq -r --arg g "$grp" '.memberships[$g][]' "$CFG")
      for member in "''${MEMBERS[@]}"; do
        # NO `|| true` here: a membership either ends up in place or the
        # script says so.
        GID=$(printf '%s' "$GROUPS_JSON" | jq -r --arg g "$grp" \
          '.data.groups[] | select(.displayName == $g) | .id')
        if [ -z "$GID" ] || [ "$GID" = "null" ]; then
          echo "FATAL: group $grp not found when adding $member" >&2; exit 1
        fi
        if printf '%s' "$GROUPS_JSON" | jq -e --arg g "$grp" --arg u "$member" \
             '.data.groups[] | select(.displayName == $g) | .users[] | select(.id == $u)' >/dev/null 2>&1; then
          echo "    $member -> $grp (already a member)"
        else
          gql 'mutation($userId: String!, $groupId: Int!) { addUserToGroup(userId: $userId, groupId: $groupId) { ok } }' \
            "$(jq -cn --arg u "$member" --argjson g "$GID" '{userId: $u, groupId: $g}')" >/dev/null
          # Read it back: the mutation returning ok is not proof it stuck.
          GROUPS_JSON=$(gql '{ groups { id displayName users { id } } }') || {
            echo "FATAL: could not re-list groups after adding $member to $grp" >&2; exit 1; }
          if printf '%s' "$GROUPS_JSON" | jq -e --arg g "$grp" --arg u "$member" \
               '.data.groups[] | select(.displayName == $g) | .users[] | select(.id == $u)' >/dev/null 2>&1; then
            echo "    $member -> $grp (added, verified)"
          else
            echo "FATAL: added $member to $grp but it is not there on read-back" >&2; exit 1
          fi
        fi
      done
    done

    echo ""
    echo "==> lldap bootstrap complete"
  '';
}
