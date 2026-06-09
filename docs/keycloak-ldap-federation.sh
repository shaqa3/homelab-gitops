#!/usr/bin/env bash
# Configure Keycloak -> OpenLDAP user federation via the Admin REST API.
# Idempotent-ish: creates the 'demo' realm (if missing) and an 'openldap'
# LDAP user-storage provider, triggers a full sync, and verifies.
#
# Requires: curl, python3, and a reachable Keycloak.
set -euo pipefail

KC="${KC:-http://keycloak.192.168.64.3.nip.io}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
REALM="${REALM:-demo}"

# LDAP connection (in-cluster service DNS of the OpenLDAP install)
LDAP_URL="${LDAP_URL:-ldap://openldap.openldap.svc.cluster.local:389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=example,dc=org}"
LDAP_BIND_PW="${LDAP_BIND_PW:-admin}"
LDAP_USERS_DN="${LDAP_USERS_DN:-ou=people,dc=example,dc=org}"

token() {
  curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d username="$ADMIN_USER" -d password="$ADMIN_PASS" \
    -d grant_type=password | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

TOKEN="$(token)"
auth=(-H "Authorization: Bearer $TOKEN")

# 1. Create the realm if it does not exist
if ! curl -s "${auth[@]}" "$KC/admin/realms/$REALM" | grep -q '"realm"'; then
  curl -s -o /dev/null -w "create realm $REALM: HTTP %{http_code}\n" -X POST "${auth[@]}" \
    -H "Content-Type: application/json" "$KC/admin/realms" -d "{\"realm\":\"$REALM\",\"enabled\":true}"
fi

# 2. Look up the realm's INTERNAL id (UUID) -- this MUST be the component parentId,
#    NOT the realm name. Using the name orphans the provider:
#    symptom = "0 imported users" + "Realm with id <name> not found" during sync.
RID="$(curl -s "${auth[@]}" "$KC/admin/realms/$REALM" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
echo "realm $REALM internal id: $RID"

# 3. Create the LDAP user-storage provider (skip if one already exists)
EXIST="$(curl -s "${auth[@]}" \
  "$KC/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider&parent=$RID" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')"
if [ -z "$EXIST" ]; then
  curl -s -o /dev/null -w "create ldap provider: HTTP %{http_code}\n" -X POST "${auth[@]}" \
    -H "Content-Type: application/json" "$KC/admin/realms/$REALM/components" -d "{
      \"name\":\"openldap\",\"providerId\":\"ldap\",
      \"providerType\":\"org.keycloak.storage.UserStorageProvider\",\"parentId\":\"$RID\",
      \"config\":{
        \"enabled\":[\"true\"],\"priority\":[\"0\"],\"vendor\":[\"other\"],
        \"connectionUrl\":[\"$LDAP_URL\"],
        \"bindDn\":[\"$LDAP_BIND_DN\"],\"bindCredential\":[\"$LDAP_BIND_PW\"],\"authType\":[\"simple\"],
        \"editMode\":[\"WRITABLE\"],\"usersDn\":[\"$LDAP_USERS_DN\"],
        \"usernameLDAPAttribute\":[\"uid\"],\"rdnLDAPAttribute\":[\"uid\"],\"uuidLDAPAttribute\":[\"entryUUID\"],
        \"userObjectClasses\":[\"inetOrgPerson\"],\"searchScope\":[\"1\"],
        \"importEnabled\":[\"true\"],\"syncRegistrations\":[\"true\"],\"pagination\":[\"true\"],\"trustEmail\":[\"true\"]
      }}"
fi

DCID="$(curl -s "${auth[@]}" \
  "$KC/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider&parent=$RID" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
echo "ldap component id: $DCID"

# 4. Trigger a full sync (bulk-import LDAP users)
echo -n "full sync: "
curl -s -X POST "${auth[@]}" "$KC/admin/realms/$REALM/user-storage/$DCID/sync?action=triggerFullSync"; echo

# 5. Show imported users
echo "users in $REALM:"
curl -s "${auth[@]}" "$KC/admin/realms/$REALM/users?max=50" \
  | python3 -c 'import sys,json
for u in json.load(sys.stdin):
    print("  -", u.get("username"), "| email=", u.get("email"), "| federated=", bool(u.get("federationLink")))'
