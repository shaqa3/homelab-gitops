# react-app — Keycloak + React login demo

A minimal React app (single `index.html`, no build step) that logs in against the
local Keycloak using OpenID Connect (Authorization Code + PKCE). **`index.html`
in this folder is the single source of truth** — it's both what ArgoCD deploys
and what you serve for local dev.

- Keycloak: `https://keycloak.192.168.64.3.nip.io`, realm `demo`, client `react-app`
- React + keycloak-js are loaded from CDN; JSX is compiled in-browser by Babel.
- Log in with a federated LDAP user, e.g. **`jdoe` / `secret123`** or
  **`asmith` / `secret123`**.

## How it's deployed

`nginx:alpine` serves `index.html` from a Kustomize-generated ConfigMap
(`kustomization.yaml` → `configMapGenerator`), exposed at
**https://react.192.168.64.3.nip.io** and managed by ArgoCD (`apps/react-app.yaml`).

> **HTTPS / trust the local CA.** The app and Keycloak are served over HTTPS with
> an [mkcert](https://github.com/FiloSottile/mkcert) cert (Kubernetes secret
> `homelab-tls`, created out-of-band in each namespace — not in Git). HTTPS is
> required: the app uses PKCE (S256), whose Web Crypto API only works in a secure
> context, and an HTTPS page can't call an HTTP Keycloak (mixed content). For the
> browser to trust the cert (and the Users-page `fetch` to succeed), run
> **`mkcert -install`** once in your terminal, then restart the browser.

To change the app: **edit `index.html`, commit, and push.** Kustomize re-hashes
the ConfigMap name from the file contents, so ArgoCD rolls the pod automatically.
No image build, no registry.

## Local dev (optional)

Serve this same folder over HTTP (not `file://`, so the OIDC redirect works):

```bash
cd gitops/manifests/react-app
python3 -m http.server 8000
```

Open **http://localhost:8000**. The `react-app` Keycloak client allows redirects
from `http://localhost:8000/*` and `:5173/*` as well as the ingress host, so both
local and in-cluster work. (To use another port, add it to the client's Valid
redirect URIs and Web origins.)

## Theme

Top-right **☀️ Light / 🌙 Dark** button toggles the theme. The choice is saved in
`localStorage`; on first visit it follows your OS `prefers-color-scheme`. Colors
are CSS custom properties under `[data-theme]`, and an inline script applies the
saved theme before first paint so there's no flash.

## How the login works

1. `keycloak.init()` runs on load. With no session it resolves "not
   authenticated" and the app shows a **Log in** button.
2. `keycloak.login()` redirects the browser to Keycloak. You authenticate (your
   password is checked against OpenLDAP via federation).
3. Keycloak redirects back with an authorization code; `keycloak.init()`
   exchanges it (with PKCE) for tokens.
4. The app reads the ID-token claims (`preferred_username`, `name`, `email`) and
   renders the signed-in view. **Log out** calls `keycloak.logout()`.

`checkLoginIframe` is disabled because the app and Keycloak are different origins,
so the session-status iframe would be blocked by third-party-cookie rules.

## Users page

After logging in, the **Users** tab lists every user in the `demo` realm, fetched
live from the Keycloak **Admin REST API** (`GET /admin/realms/demo/users`) using
your access token. Each row shows username, name, email, source (**LDAP** =
federated from OpenLDAP vs **local** = created in Keycloak), and enabled status.

### It needs the `view-users` permission

Listing users is an admin operation. A normal login can't do it, so the demo
users were granted the `view-users` (and `query-users`) client roles from
`realm-management`:

```bash
# grant view-users to a user (replace <USER>)
KC=http://keycloak.192.168.64.3.nip.io
TOKEN=$(curl -s -X POST $KC/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
RM=$(curl -s -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/demo/clients?clientId=realm-management" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
ROLE=$(curl -s -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/demo/clients/$RM/roles/view-users")
UID=$(curl -s -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/demo/users?username=<USER>&exact=true" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$KC/admin/realms/demo/users/$UID/role-mappings/clients/$RM" -d "[$ROLE]"
```

`jdoe` and `asmith` already have it. A user *without* the role still loads the app
fine; the Users tab just shows a "you don't have permission" message (`403`).

### Creating users (＋ New user)

The Users tab has a **＋ New user** form that `POST`s to
`/admin/realms/demo/users`. Because the LDAP federation runs in `WRITABLE` mode
with `syncRegistrations` on, **a user created here is written straight into
OpenLDAP** — verify with:

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "ou=people,dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin "(uid=<new>)"
```

Creating users needs the stronger `manage-users` role (also granted to `jdoe` and
`asmith`). The form surfaces `403` (no permission) and `409` (already exists) as
inline messages.

### Editing users (Edit / reset password / delete)

Each row has an **Edit** button that opens an inline panel to:

- **Update** first name, last name, email, and the enabled flag — `PUT
  /admin/realms/demo/users/{id}`.
- **Reset password** — fill the "new password" field; it calls `PUT
  …/users/{id}/reset-password` (leave blank to keep the current one).
- **Delete user** — the red button (with a confirm prompt) → `DELETE
  …/users/{id}`.

All of these **write through to OpenLDAP** for federated users (WRITABLE edit
mode) and need the `manage-users` role. Username isn't editable — it's the
federation key.

> **Email is required.** Keycloak 26's user profile requires email (and
> first/last name); a user created/edited without an email is flagged *"Account
> is not fully set up"* and **cannot log in** until it's filled. That's why the
> create form makes email mandatory.

### Realm role assignment

The user table's **Roles (effective)** column shows each user's *effective* realm
roles — fetched per user from both `/role-mappings/realm` (direct) and
`/role-mappings/realm/composite` (effective). Solid pills are **directly
assigned**; dashed pills are **inherited from a group** (a role in the composite
set but not the direct set). The technical defaults (`default-roles-demo`,
`offline_access`, `uma_authorization`) are hidden. The Edit panel lists the
realm's roles as checkboxes; toggling one immediately assigns/unassigns it via
`POST`/`DELETE` on `/role-mappings/realm`, and the table refreshes when the panel
closes.

This needs two realm-management roles, both granted to `jdoe`/`asmith`:
`view-realm` (to *list* roles) and `manage-users` (to *change* mappings). Sample
roles `app-admin`, `app-user`, `viewer` were created for the demo:

```bash
# create a realm role
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  http://keycloak.192.168.64.3.nip.io/admin/realms/demo/roles -d '{"name":"app-admin"}'
```

> Realm roles live in Keycloak only — they are **not** written to LDAP (LDAP
> stores identity/credentials; authorization stays in Keycloak).

The Edit panel also has:

- **Client roles** — a client dropdown (defaults to `realm-management`) +
  checkboxes to assign that client's roles (`role-mappings/clients/{id}`). Needs
  `view-clients` to list clients.
- **Required actions** — toggle pending actions like `UPDATE_PASSWORD` /
  `VERIFY_EMAIL` (`PUT` the user's `requiredActions`). Useful when a user is
  *"not fully set up"*.
- **Active sessions** — lists the user's sessions (clients, IP, start time) from
  `/users/{id}/sessions`, with a **Log out all sessions** button
  (`POST /users/{id}/logout`).

> The demo users `jdoe`/`asmith` were granted a broad realm-management set
> (`view-realm`, `manage-realm`, `view-users`, `query-users`, `manage-users`,
> `view-clients`) so all of the above work from a normal login.

### LDAP directory entry

For a federated user, the Edit panel shows a read-only **LDAP directory entry**
box: the federation provider name, the **DN**, the **entryUUID**, and the LDAP
create/modify timestamps. These come from the *full* user representation
(`GET /users/{id}`, which includes `attributes` — `LDAP_ENTRY_DN`, `LDAP_ID`,
`createTimestamp`, `modifyTimestamp`) that the brief list response omits; the
provider name is resolved from `federationLink` via
`/components?type=…UserStorageProvider` (needs `view-realm`).

> The browser can call the admin API because the `react-app` client's **Web
> origins** include the app's origin, so the access token carries an
> `allowed-origins` claim and Keycloak returns CORS headers for it.

## Groups tab

Lists the realm's groups (`GET /groups`), each group's members
(`/groups/{id}/members`), and its assigned realm roles
(`/groups/{id}/role-mappings/realm`). The groups are **federated from OpenLDAP**
via a `group-ldap-mapper` (`ou=groups`, `groupOfNames`), so **membership is
read-only** (managed in LDAP).

**Group-based role mapping:** roles assigned to a group are **inherited by all its
members** (visible in a user's *composite* role mappings). The **Edit roles**
button per group toggles its realm roles (`POST`/`DELETE`
`/groups/{id}/role-mappings/realm`). Demo: the `developers` group has `viewer`, so
`asmith` — with no direct roles — effectively has `viewer` through membership.

> Group role mappings are stored in Keycloak (not LDAP), so they're editable here
> even though the groups themselves are read-only/federated. Like per-user grants,
> they're imperative state (not in the realm import), since the groups come from
> LDAP rather than the realm JSON.

## LDAP tab (federation settings)

The **LDAP** nav tab shows a read-only view of the realm's LDAP user-storage
provider config — connection URL, bind DN, users DN, edit mode, search scope,
the attribute mappings (username/RDN/UUID), object classes, and the
import/sync/pagination flags. This is realm-level config (not per-user), read
from `/components?type=…UserStorageProvider` (needs `view-realm`). The bind
credential is write-only and never returned by Keycloak.

A **Synchronisation** section adds **Sync all users** (full) and **Sync changed
users** (incremental) buttons — `POST
/user-storage/{id}/sync?action=triggerFullSync|triggerChangedUsersSync` (needs
`manage-users`) — and shows the resulting added/updated/removed/failed counts.
The config itself is read-only: editing connection/bind settings stays with the
Keycloak Admin Console, not this SPA.

The tab also has **Test connection** / **Test authentication** buttons
(`POST /testLDAPConnection`, needs `manage-realm`) and an **Attribute mappers**
table showing how LDAP attributes map to Keycloak — e.g. `uid → username`,
`mail → email`, `cn → firstName`, `sn → lastName` (this is also why a seeded
`cn: John Doe` shows as first name "John Doe").

## Upgrade to a real Vite project (optional)

This CDN/Babel setup is for zero-install simplicity (no Node needed). For a
production-style app, install Node and scaffold Vite:

```bash
npm create vite@latest keycloak-react -- --template react
cd keycloak-react && npm install keycloak-js
```

…then port the logic from `index.html` into `src/`. The `react-app` Keycloak
client already allows Vite's default port (`http://localhost:5173`).
