# Rebuild runbook

How to recreate the whole homelab from scratch. **Git holds the declarative
state** (workloads, the Keycloak realm structure); a single **`bootstrap.sh`**
reproduces the imperative/out-of-band bits that can't live in Git.

## What's in Git vs. imperative

| In Git (ArgoCD reconciles) | Imperative (`bootstrap.sh`) |
|---|---|
| OpenLDAP, phpLDAPadmin, react-app, metrics-server | mkcert CA + TLS secrets (`homelab-tls`) |
| Keycloak Operator + `Keycloak` CR + Postgres | LDAP seed data: users + groups |
| `KeycloakRealmImport` (clients, roles, LDAP federation + group mapper, events config) | Permanent `admin/admin` master user |
| All Ingresses | Per-user role grants (jdoe/asmith) + `app-admin` to jdoe |
| | LDAP→Keycloak group sync; `developers`→`viewer` group role |

The imperative items are either secrets (shouldn't be in Git) or per-identity
state (federated users/groups aren't part of the realm JSON).

## Prerequisites

- minikube running; `kubectl` pointed at it
- ingress-nginx installed (class `nginx`)
- `mkcert`, `python3`, `curl`, `helm`
- ArgoCD installed (this repo assumes ArgoCD is already present — it's adopted
  into its own Helm release outside this repo)

## Steps

1. **Confirm the minikube IP** matches the nip.io hostnames used throughout
   (`192.168.64.3`). If different, update the ingress hosts + the `react-app`
   client redirect URIs + `bootstrap.sh`'s `IP`.

   ```bash
   minikube ip
   ```

2. **Point ArgoCD at this repo** (app-of-apps root):

   ```bash
   kubectl apply -f bootstrap/root-app.yaml
   kubectl -n argocd get applications.argoproj.io -w   # wait for Synced/Healthy
   ```

   The operator app (sync-wave -1) installs the Keycloak CRDs before the
   `keycloak-cr` app creates the `Keycloak` + `KeycloakRealmImport`. First
   Keycloak start builds the image (`startOptimized: false`) — a few minutes.

3. **Run the bootstrap** (reproduces TLS, LDAP data, admin, grants):

   ```bash
   ./bootstrap/bootstrap.sh
   ```

   `mkcert -install` will ask for your password once (to trust the local CA).
   The script is idempotent — re-run it any time the imperative state drifts.

4. **Verify**: open `https://react.192.168.64.3.nip.io` and log in as
   `jdoe` / `secret123`. Users/Groups/Clients/Events/LDAP tabs should all work.

## Notes & gotchas

- **Keycloak image is pinned to `26.6.3`** (`manifests/keycloak-cr/keycloak.yaml`).
  26.3.x has an NPE in the fine-grained-admin-permissions + LDAP group-mapper
  path that breaks admin API calls for federated users in groups.
- **`startOptimized: false`** is required because the pinned image isn't
  pre-built for our DB config; otherwise the operator's `--optimized` first
  start fails.
- LDAP users re-import from OpenLDAP automatically (federation). If a grant in
  step 5 reports "not imported yet", log in once as that user (or trigger a
  federation sync) and re-run `bootstrap.sh`.
- Secrets here (LDAP/Keycloak/DB passwords) are plaintext for a local lab. For
  anything real, use Sealed Secrets / External Secrets and cert-manager.
