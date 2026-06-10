# Rebuild runbook

How to recreate the whole homelab from scratch. **Git holds the declarative
state** (workloads, the Keycloak realm structure); a single **`bootstrap.sh`**
reproduces the imperative/out-of-band bits that can't live in Git.

## What's in Git vs. imperative

| In Git (ArgoCD reconciles) | Imperative (`bootstrap.sh`) |
|---|---|
| OpenLDAP, phpLDAPadmin, react-app, metrics-server | LDAP seed data: users + groups |
| Keycloak Operator + `Keycloak` CR + Postgres | Permanent `admin/admin` master user |
| `KeycloakRealmImport` (clients, roles, LDAP federation + group mapper, events config) | Per-user role grants (jdoe/asmith) + `app-admin` to jdoe |
| All Ingresses | LDAP→Keycloak group sync; `developers`→`viewer` group role |
| **TLS** via cert-manager (CA + leaf certs → `homelab-tls`) | (trust the CA once — see below) |
| **Sealed Secrets**: `keycloak-db` (encrypted in Git) | |

The imperative items are per-identity state (federated users/groups aren't part
of the realm JSON). Secrets that *can* be: `keycloak-db` is a SealedSecret; TLS
is issued by cert-manager.

> **Sealed Secrets key caveat:** the controller's private key (in `kube-system`,
> label `sealedsecrets.bitnami.com/sealed-secrets-key`) decrypts the committed
> SealedSecrets. On a fresh cluster a *new* key is generated and the old
> SealedSecrets can't be decrypted. Either back up that key and restore it before
> the controller starts, or re-seal `keycloak-db` (value `keycloak`) after rebuild.

> **Remaining plaintext:** the LDAP `bindCredential` is inline in the realm-import
> CR (no secretRef in the realm JSON), so it can't be sealed; the OpenLDAP Helm
> value mirrors it. Both are the lab LDAP admin password (`admin`).

## Prerequisites

- minikube running; `kubectl` pointed at it
- ingress-nginx installed (class `nginx`)
- `python3`, `curl`, `helm`, `kubeseal` (TLS is now via cert-manager, not mkcert)
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

4. **Trust the cert-manager CA** (once — so the browser accepts the TLS and the
   app's `fetch` to Keycloak works):

   ```bash
   kubectl -n cert-manager get secret homelab-ca-key-pair \
     -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
   # macOS:
   sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain homelab-ca.crt
   ```

5. **Verify**: open `https://react.192.168.64.3.nip.io` and log in as
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
