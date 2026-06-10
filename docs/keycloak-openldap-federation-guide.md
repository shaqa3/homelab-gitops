# Federating Keycloak to OpenLDAP (Minikube)

Wire Keycloak's **User Federation** to the OpenLDAP server so that LDAP users
can log into Keycloak (and any app that uses Keycloak for SSO), with passwords
verified against LDAP. Builds on the two earlier guides:

- `openldap-minikube-guide.md` — OpenLDAP running at `openldap.openldap.svc.cluster.local:389`
- `keycloak-minikube-guide.md` — Keycloak running at `http://keycloak.192.168.64.3.nip.io`

There are two ways to configure this: the **Admin Console UI** (recommended —
it avoids the `parentId` pitfall described below) and a **scripted REST**
approach (good for automation). Both are covered.

---

## Step 1 — Put some users in OpenLDAP

Federation needs LDAP entries to import. Create an `ou=people` and two users:

```bash
cat > seed.ldif <<'EOF'
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
EOF

kubectl -n openldap cp seed.ldif openldap-0:/tmp/seed.ldif
kubectl -n openldap exec openldap-0 -- ldapadd -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=org" -w admin -f /tmp/seed.ldif
```

Verify:

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "ou=people,dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin "(uid=*)" uid mail
```

---

## Step 2 — Add the LDAP provider

### Option A — Admin Console UI (recommended)

1. Open `http://keycloak.192.168.64.3.nip.io`, log in as `admin` / `admin`.
2. Top-left realm switcher → **Create realm** → name `demo` → **Create**.
   (Best practice: federate into a dedicated realm, **not** `master`.)
3. Left menu → **User federation** → **Add LDAP providers**.
4. Fill in:

   | Field | Value |
   |---|---|
   | UI display name | `openldap` |
   | Vendor | `Other` |
   | Connection URL | `ldap://openldap.openldap.svc.cluster.local:389` |
   | Bind type | `simple` |
   | Bind DN | `cn=admin,dc=example,dc=org` |
   | Bind credentials | `admin` |
   | Edit mode | `WRITABLE` |
   | Users DN | `ou=people,dc=example,dc=org` |
   | Username LDAP attribute | `uid` |
   | RDN LDAP attribute | `uid` |
   | UUID LDAP attribute | `entryUUID` |
   | User object classes | `inetOrgPerson` |
   | Search scope | `One Level` |

5. Click **Test connection** and **Test authentication** — both should be green.
6. **Save**.
7. On the provider page, **Action ▸ Sync all users** to bulk-import.

The UI sets the provider's internal `parentId` to the realm correctly — you
don't have to think about it. (The REST option below does require care.)

### Option B — Scripted REST API

A ready-to-run script is provided: **`keycloak-ldap-federation.sh`**. It creates
the `demo` realm, adds the LDAP provider, triggers a sync, and lists the
imported users. Run it:

```bash
./keycloak-ldap-federation.sh
```

Expected output:

```
create realm demo: HTTP 201
realm demo internal id: e561c3cf-...
create ldap provider: HTTP 201
ldap component id: Ix8cmxc4...
full sync: {"ignored":false,"added":2,"updated":0,"removed":0,"failed":0,"status":"2 imported users, 0 updated users"}
users in demo:
  - asmith | email= asmith@example.org | federated= True
  - jdoe   | email= jdoe@example.org   | federated= True
```

> ⚠️ **The critical detail (see Troubleshooting):** when creating the provider
> via REST, its `parentId` **must be the realm's internal UUID**, not the realm
> name. The script looks the UUID up with `GET /admin/realms/demo` → `.id` and
> uses that.

---

## Step 3 — Verify end-to-end

Users imported into Keycloak should authenticate with their **LDAP** password:

```bash
KC=http://keycloak.192.168.64.3.nip.io

# jdoe logs in with the LDAP password (secret123) -> expect an access_token
curl -s -X POST $KC/realms/demo/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=jdoe -d password=secret123 -d grant_type=password

# wrong password -> expect "invalid_grant"
curl -s -X POST $KC/realms/demo/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=jdoe -d password=wrong -d grant_type=password
```

In the Admin Console: realm `demo` → **Users** → the LDAP users appear, each
showing a federation link back to `openldap`.

---

## Step 4 — Add a new LDAP user later (and watch it federate)

Once federation is configured, new users created in OpenLDAP show up in Keycloak
automatically — no reconfiguration needed.

Add a user to LDAP:

```bash
cat > newuser.ldif <<'EOF'
dn: uid=bwayne,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: organizationalPerson
cn: Bruce Wayne
sn: Wayne
uid: bwayne
mail: bwayne@example.org
userPassword: batman123
EOF

kubectl -n openldap cp newuser.ldif openldap-0:/tmp/newuser.ldif
kubectl -n openldap exec openldap-0 -- ldapadd -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=org" -w admin -f /tmp/newuser.ldif
```

It reaches Keycloak in one of two ways:

**A. On-demand (automatic, nothing to run).** Keycloak queries LDAP live whenever
it lists or looks up a user, so a brand-new LDAP user is usable immediately — it
appears in **Users** and can log in straight away, which imports it on first
authentication:

```bash
KC=http://keycloak.192.168.64.3.nip.io
# bwayne logs in with the LDAP password -> expect an access_token
curl -s -X POST $KC/realms/demo/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=bwayne -d password=batman123 -d grant_type=password
```

**B. Full sync (proactive bulk import).** To pull everyone in at once (e.g. so
all users are listed before they've logged in), trigger a sync — Admin Console
**User federation → openldap → Sync all users**, or:

```bash
TOKEN=$(curl -s -X POST $KC/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
RID=$(curl -s -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/demo" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
DCID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/demo/components?type=org.keycloak.storage.UserStorageProvider&parent=$RID" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/demo/user-storage/$DCID/sync?action=triggerFullSync"
# -> {"added":1,...} for a new user, or {"updated":N} if already imported
```

> A full sync is **not required** for a user to work — option A handles that. Sync
> is for bulk pre-population and for reconciling deletions. `added` counts users
> new to Keycloak; `updated` counts already-imported users refreshed from LDAP.

---

## Step 5 — Remove a user

Always delete from **LDAP first**, then clean up the leftover Keycloak copy.

```bash
# 1. Delete the entry from OpenLDAP
kubectl -n openldap exec openldap-0 -- ldapdelete -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  "uid=bwayne,ou=people,dc=example,dc=org"
```

The user **can no longer log in** immediately — authentication binds to LDAP, and
the entry is gone. But with `importEnabled=true`, Keycloak keeps an **imported
copy** in its own DB: a standard LDAP sync only adds/updates and does **not**
delete users that vanished from LDAP, so the stale record lingers in the user
list until it's reconciled.

Clean it up by removing the orphaned Keycloak user:

```bash
KC=http://keycloak.192.168.64.3.nip.io
TOKEN=$(curl -s -X POST $KC/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# look up the leftover user's Keycloak id, then delete it
KID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/demo/users?username=bwayne&exact=true" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')
[ -n "$KID" ] && curl -s -o /dev/null -w "%{http_code}\n" \
  -X DELETE -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/demo/users/$KID"
```

> **Two gotchas seen in practice:**
> - That `DELETE` can return **HTTP 500** because the provider is in `WRITABLE`
>   edit mode — Keycloak tries to propagate the deletion back to LDAP, where the
>   entry no longer exists. It's harmless: the local copy is still removed.
> - Simply *looking the user up* (the `username=bwayne` query above) often
>   reconciles it on its own — Keycloak notices the LDAP entry is missing and
>   drops the stale local record. So the user may already be gone before the
>   `DELETE` runs.

In the Admin Console you can do the same: realm `demo` → **Users** → open the
user → **Delete**.

---

## Group federation (optional)

LDAP groups can federate into Keycloak too. Create a `groups` OU with
`groupOfNames` entries (each needs ≥1 `member` DN):

```bash
cat > groups.ldif <<'EOF'
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
EOF
kubectl -n openldap cp groups.ldif openldap-0:/tmp/groups.ldif
kubectl -n openldap exec openldap-0 -- ldapadd -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=org" -w admin -f /tmp/groups.ldif
```

Then add a **`group-ldap-mapper`** sub-component to the LDAP provider (key config:
`groups.dn=ou=groups,…`, `group.object.classes=groupOfNames`,
`membership.ldap.attribute=member`, `membership.attribute.type=DN`,
`membership.user.ldap.attribute=uid`, `mode=READ_ONLY`). In GitOps this lives in
`manifests/keycloak-cr/realmimport.yaml` under the provider's `subComponents`.
Sync it (`…/user-storage/{ldapId}/mappers/{mapperId}/sync?direction=fedToKeycloak`)
and the groups appear in Keycloak with their LDAP membership — visible in the
React app's **Groups** tab. Membership stays managed in LDAP (READ_ONLY).

## How it works

- **Import vs. bind.** With `importEnabled=true`, Keycloak copies a lightweight
  user record into its own DB on first sync/login, but **passwords are always
  verified by binding to LDAP** — Keycloak never stores the LDAP password.
- **Edit mode `WRITABLE`** lets changes made in Keycloak (e.g. profile edits,
  new users) propagate back into LDAP using the bind DN's write access.
- **`entryUUID`** is OpenLDAP's stable per-entry id; Keycloak uses it to track
  an LDAP entry across renames.
- **Search scope `One Level`** matches users directly under `ou=people`.

---

## Troubleshooting

### Sync reports "0 imported users" and the log shows `Realm with id <name> not found`

This is the big one, and it is **not** a database or connectivity problem.

**Cause:** the LDAP provider component was created via REST with
`"parentId": "demo"` (the realm *name*). Keycloak components must be parented to
the realm's **internal id (a UUID)**. With the wrong parent the component is
orphaned: Keycloak finds no provider when it enumerates the realm's federation
providers (so logins return `user_not_found` and **no LDAP query is even
attempted**), and the sync task tries to load a realm literally named "demo" and
fails with `ModelIllegalStateException: Realm with id demo not found`.

**Fix:** use the realm UUID as `parentId`:

```bash
RID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  http://keycloak.192.168.64.3.nip.io/admin/realms/demo \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
# ...then POST the component with "parentId": "$RID"
```

The Admin Console and `kcadm.sh` handle this automatically — the trap is
specific to hand-rolled REST calls. (Misleading detail: `Test connection` /
`Test authentication` still pass even when the component is orphaned, because
they bind using the values in the request, independent of `parentId`.)

### `Test authentication` works but sync still imports 0, and anonymous search fails

osixia OpenLDAP's default ACLs **hide the directory from anonymous binds**
(`ldapsearch` without `-D/-w` returns `No such object`). So a correct, non-empty
**Bind DN + Bind credentials** is mandatory — there is no anonymous fallback.
Confirm the bind works:

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x \
  -H ldap://openldap.openldap.svc.cluster.local:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  -b "ou=people,dc=example,dc=org" "(uid=jdoe)" dn
```

### Federate into a dedicated realm, not `master`

`master` is Keycloak's management realm; keep external identities in their own
realm (`demo` here). It also avoids confusing the bootstrap admin with LDAP
users.

### Reaching LDAP from Keycloak

Keycloak (namespace `keycloak`) reaches OpenLDAP (namespace `openldap`) via the
cross-namespace service DNS `openldap.openldap.svc.cluster.local:389`. Quick
reachability check from the Keycloak pod:

```bash
kubectl -n keycloak exec deploy/keycloak -- \
  bash -c 'cat < /dev/null > /dev/tcp/openldap.openldap.svc.cluster.local/389 && echo reachable'
```

---

## Note on persistence

The Keycloak guide runs in **dev mode** (in-memory H2). Federation works fine
there, but **the `demo` realm and provider config are wiped when the Keycloak
pod restarts** — just re-run `keycloak-ldap-federation.sh` to rebuild them. (The
LDAP users themselves persist in OpenLDAP's PVC.) For a durable setup, back
Keycloak with PostgreSQL; federation behaves identically.

---

## Cleanup

Remove just the federation (leave realms intact) by deleting the provider in the
Admin Console (**User federation → openldap → Delete**), or drop the whole demo
realm:

```bash
TOKEN=$(curl -s -X POST http://keycloak.192.168.64.3.nip.io/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  http://keycloak.192.168.64.3.nip.io/admin/realms/demo
```
