#!/usr/bin/env bash
# Post-ArgoCD bootstrap for the homelab. Reproduces the IMPERATIVE / out-of-band
# state that isn't (and can't easily be) in Git: the mkcert TLS secrets, the LDAP
# seed data (users + groups), the permanent master admin, the per-user/per-group
# role grants, and the LDAP-group sync. Idempotent — safe to re-run.
#
# Prereqs: kubectl (pointed at the cluster), mkcert, python3, curl, and the
# ArgoCD apps already synced (OpenLDAP + Keycloak running). Run AFTER the cluster
# and ArgoCD apps are up.
set -euo pipefail

IP="${MINIKUBE_IP:-192.168.64.3}"
KC="https://keycloak.${IP}.nip.io"
CA="$(mkcert -CAROOT)/rootCA.pem"
c() { curl -s --cacert "$CA" "$@"; }
say() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
say "1. TLS — mkcert CA + cert + secrets in each namespace"
mkcert -install || true   # trusts the local CA (idempotent; may prompt for password)
CRT=/tmp/homelab.pem KEY=/tmp/homelab-key.pem
mkcert -cert-file "$CRT" -key-file "$KEY" \
  "react.${IP}.nip.io" "keycloak.${IP}.nip.io" "phpldapadmin.${IP}.nip.io"
for ns in react-app keycloak openldap; do
  kubectl -n "$ns" create secret tls homelab-tls --cert="$CRT" --key="$KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# ---------------------------------------------------------------------------
say "2. LDAP seed — users (ou=people) + groups (ou=groups)"
kubectl -n openldap exec -i openldap-0 -- ldapadd -c -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=org" -w admin >/dev/null 2>&1 <<'LDIF' || true
dn: ou=people,dc=example,dc=org
objectClass: organizationalUnit
ou: people

dn: uid=jdoe,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: organizationalPerson
cn: John Doe
sn: Doe
uid: jdoe
mail: jdoe@example.org
userPassword: secret123

dn: uid=asmith,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: organizationalPerson
cn: Alice Smith
sn: Smith
uid: asmith
mail: asmith@example.org
userPassword: secret123

dn: ou=groups,dc=example,dc=org
objectClass: organizationalUnit
ou: groups

dn: cn=admins,ou=groups,dc=example,dc=org
objectClass: groupOfNames
cn: admins
member: uid=jdoe,ou=people,dc=example,dc=org

dn: cn=developers,ou=groups,dc=example,dc=org
objectClass: groupOfNames
cn: developers
member: uid=asmith,ou=people,dc=example,dc=org
member: uid=jdoe,ou=people,dc=example,dc=org
LDIF
echo "  LDAP seed applied (existing entries skipped)"

# ---------------------------------------------------------------------------
say "3. Keycloak — permanent admin/admin in master realm"
TU=$(kubectl -n keycloak get secret kc-initial-admin -o jsonpath='{.data.username}' | base64 -d)
TP=$(kubectl -n keycloak get secret kc-initial-admin -o jsonpath='{.data.password}' | base64 -d)
tok() { c -X POST "$KC/realms/$1/protocol/openid-connect/token" -d client_id=admin-cli \
  -d "username=$2" -d "password=$3" -d grant_type=password \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
T=$(tok master "$TU" "$TP")
A=(-H "Authorization: Bearer $T")
if ! c "${A[@]}" "$KC/admin/realms/master/users?username=admin&exact=true" | grep -q '"username":"admin"'; then
  c "${A[@]}" -X POST -H 'Content-Type: application/json' "$KC/admin/realms/master/users" \
    -d '{"username":"admin","enabled":true,"credentials":[{"type":"password","value":"admin","temporary":false}]}' >/dev/null
  AID=$(c "${A[@]}" "$KC/admin/realms/master/users?username=admin&exact=true" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
  ROLE=$(c "${A[@]}" "$KC/admin/realms/master/roles/admin")
  c "${A[@]}" -X POST -H 'Content-Type: application/json' "$KC/admin/realms/master/users/$AID/role-mappings/realm" -d "[$ROLE]" >/dev/null
  echo "  created admin/admin"
else echo "  admin/admin already exists"; fi
T=$(tok master admin admin); A=(-H "Authorization: Bearer $T")

# ---------------------------------------------------------------------------
say "4. Sync LDAP groups into Keycloak (group mapper is declared in the realm import)"
LID=$(c "${A[@]}" "$KC/admin/realms/demo/components?type=org.keycloak.storage.UserStorageProvider" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
MID=$(c "${A[@]}" "$KC/admin/realms/demo/components?parent=$LID&name=groups" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')
[ -n "$MID" ] && c "${A[@]}" -X POST "$KC/admin/realms/demo/user-storage/$LID/mappers/$MID/sync?direction=fedToKeycloak" >/dev/null && echo "  groups synced from LDAP"

# ---------------------------------------------------------------------------
say "5. Per-user role grants (federated users aren't in the realm JSON)"
RM=$(c "${A[@]}" "$KC/admin/realms/demo/clients?clientId=realm-management" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
clientroles() { c "${A[@]}" "$KC/admin/realms/demo/clients/$RM/roles" \
  | python3 -c "import sys,json;rs=[r for r in json.load(sys.stdin) if r['name'] in {$1}];print(json.dumps([{'id':r['id'],'name':r['name']} for r in rs]))"; }
uid_of() { c "${A[@]}" "$KC/admin/realms/demo/users?username=$1&exact=true" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")'; }
ROLES=$(clientroles "'view-users','query-users','manage-users','view-realm','manage-realm','view-clients','view-events'")
for u in jdoe asmith; do
  UU=$(uid_of "$u"); [ -z "$UU" ] && { echo "  $u not imported yet — log in once or sync users"; continue; }
  c "${A[@]}" -X POST -H 'Content-Type: application/json' "$KC/admin/realms/demo/users/$UU/role-mappings/clients/$RM" -d "$ROLES" >/dev/null
  echo "  $u: realm-management roles granted"
done
# app-admin (realm role) to jdoe
JU=$(uid_of jdoe); APPADMIN=$(c "${A[@]}" "$KC/admin/realms/demo/roles/app-admin")
[ -n "$JU" ] && c "${A[@]}" -X POST -H 'Content-Type: application/json' "$KC/admin/realms/demo/users/$JU/role-mappings/realm" -d "[$APPADMIN]" >/dev/null && echo "  jdoe: app-admin granted"

# ---------------------------------------------------------------------------
say "6. Group-based role mapping — developers -> viewer"
DEV=$(c "${A[@]}" "$KC/admin/realms/demo/groups?search=developers" | python3 -c 'import sys,json;d=[g for g in json.load(sys.stdin) if g["name"]=="developers"];print(d[0]["id"] if d else "")')
VIEWER=$(c "${A[@]}" "$KC/admin/realms/demo/roles/viewer")
[ -n "$DEV" ] && c "${A[@]}" -X POST -H 'Content-Type: application/json' "$KC/admin/realms/demo/groups/$DEV/role-mappings/realm" -d "[$VIEWER]" >/dev/null && echo "  developers group: viewer granted"

say "Bootstrap complete"
echo "Open https://react.${IP}.nip.io and log in as jdoe / secret123 (or asmith)."
