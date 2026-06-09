# Managing the minikube lab with ArgoCD (GitOps)

Bring the OpenLDAP / phpLDAPadmin / Keycloak workloads under ArgoCD using the
**app-of-apps** pattern, syncing from a Git repo. This took the stack from
imperative (`helm install` / `kubectl apply`) to declarative GitOps.

- Git repo: `https://github.com/shaqa3/homelab-gitops`
- Local working copy: `/Users/shahab/gitops/`
- Companion guides: `openldap-minikube-guide.md`, `keycloak-minikube-guide.md`,
  `keycloak-openldap-federation-guide.md`

---

## What ArgoCD manages (and what it doesn't)

| Managed by ArgoCD | How |
|---|---|
| OpenLDAP | Helm chart (upstream repo) + inlined values |
| phpLDAPadmin | plain manifests (`manifests/phpldapadmin`) |
| Keycloak | plain manifests (`manifests/keycloak`) |

**Not** managed by ArgoCD: the Keycloak `demo` realm and LDAP user federation —
those aren't plain Kubernetes objects, so they stay configured via the Keycloak
Admin API / `keycloak-ldap-federation.sh`. (To make the realm declarative you'd
use the Keycloak Operator's `KeycloakRealmImport` CRD or a realm-import
ConfigMap — out of scope here.)

---

## Repo layout (app-of-apps)

```
gitops/
├── bootstrap/
│   └── root-app.yaml          # the ONE app you apply by hand; watches apps/
├── apps/                      # child Applications (managed by root)
│   ├── openldap.yaml          # Helm source + inlined values
│   ├── phpldapadmin.yaml      # -> manifests/phpldapadmin
│   └── keycloak.yaml          # -> manifests/keycloak
└── manifests/
    ├── phpldapadmin/          # Deployment + Service + Ingress
    └── keycloak/              # Secret + Deployment + Service + Ingress
```

The **root** Application points at `apps/`; ArgoCD turns each file there into a
child Application. All apps use `automated: { prune: true, selfHeal: true }` and
`CreateNamespace=true`.

---

## Bootstrap from scratch

1. **Create an empty Git repo** (e.g. GitHub `homelab-gitops`), push this tree:

   ```bash
   cd /Users/shahab/gitops
   git init && git add -A && git commit -m "init"
   git branch -M main
   git remote add origin https://github.com/<you>/homelab-gitops.git
   git push -u origin main
   ```

   > **Auth:** GitHub needs a Personal Access Token (not a password) for HTTPS.
   > On macOS, store it once and pushes go silent:
   > ```bash
   > printf "protocol=https\nhost=github.com\nusername=<you>\npassword=<TOKEN>\n\n" \
   >   | git credential-osxkeychain store
   > ```
   > Run that in a real terminal — never where it lands in a log/transcript.

2. **Point the child apps at your repo** — replace `__REPO_URL__` (or the existing
   URL) in `apps/*.yaml` and `bootstrap/root-app.yaml`. The `openldap` app uses
   the upstream Helm repo and needs no change.

3. **Apply the root app once:**

   ```bash
   kubectl apply -f bootstrap/root-app.yaml
   ```

4. **Watch it reconcile:**

   ```bash
   kubectl -n argocd get applications.argoproj.io \
     -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' -w
   ```

   Target state — all four `Synced` / `Healthy`:

   ```
   root           Synced   Healthy
   openldap       Synced   Healthy
   phpldapadmin   Synced   Healthy
   keycloak       Synced   Healthy
   ```

---

## Day-2: making changes

Never `kubectl edit` a managed resource — `selfHeal` reverts it. Instead:

```bash
# edit a manifest or an app's values, then:
git -C /Users/shahab/gitops commit -am "change X" && git -C /Users/shahab/gitops push
# ArgoCD picks it up within ~3 min, or force it:
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
```

`prune: true` means **deleting a manifest from Git deletes it from the cluster**.

---

## Adopting already-running resources

These workloads existed before ArgoCD. Adoption was smooth because ArgoCD just
adds a tracking annotation to matching live objects:

- **Keycloak / phpLDAPadmin** (deployed with `kubectl`): adopted with **no pod
  restart** — the manifests matched the live state exactly.
- **OpenLDAP** (deployed with `helm install`): ArgoCD took over reconciliation,
  but Helm's bookkeeping (`sh.helm.release.v1.openldap.*` secrets, visible in
  `helm list`) lingered. Once ArgoCD owns the resources, drop the Helm
  bookkeeping so there's a single owner — this removes **only** the release
  secrets, not the workload or its PVC:

  ```bash
  kubectl -n openldap delete secret sh.helm.release.v1.openldap.v1 sh.helm.release.v1.openldap.v2
  helm -n openldap list   # now empty
  ```

  (The `app.kubernetes.io/managed-by: Helm` labels remain — cosmetic, ArgoCD
  ignores them.)

---

## Gotcha: the OpenLDAP `imagePullSecrets` loop

The single hardest part of this migration. Symptoms, in order:

1. `openldap` app stuck `Sync=Unknown` with
   `ComparisonError: ... does not contain declared merge key: name`.
2. After working around the diff, syncs **failed at apply** with the same error.
3. After working around that, syncs **"succeeded" but never went Synced**, and
   `imagePullSecrets` on the StatefulSet grew `[{}]` → `[{},{}]` → … one empty
   entry **per self-heal cycle**.

**Root cause.** The chart *always* renders an `imagePullSecrets` entry from
`image.pullSecret`. Our value was `""`, producing a **null-named** entry. The
list uses `name` as its merge key, so a null name:
- breaks ArgoCD's client-side three-way-merge diff (and apply), and
- can't be de-duplicated by server-side apply, so each reconcile **appends
  another empty entry** — a runaway loop.

**Things that did _not_ fix it:**
- `ignoreDifferences` on `imagePullSecrets` — fixes the *diff* only, not the apply.
- `ServerSideApply=true` — apply "succeeds" but still never converges, and the
  list keeps growing.

**The actual fix** — give `pullSecret` a real (placeholder) **name** so the
rendered entry is stable and mergeable:

```yaml
image:
  pullSecret: "no-pull-secret"   # NOT ""
```

The secret needn't exist: the public `osixia/openldap` image pulls anonymously,
and with `pullPolicy: IfNotPresent` the cached image isn't re-pulled. With a
non-empty name the diff/apply behave normally and self-heal converges — no
`ignoreDifferences` or `ServerSideApply` workarounds needed.

> If you ever see a list field "does not contain declared merge key: <key>",
> suspect a list entry with a null/empty value for that key.

**Recovering a cluster already stuck in the loop:**

```bash
# 1. stop self-heal from appending more
kubectl -n argocd patch application openldap --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
# 2. reset the live list to one valid entry
kubectl -n openldap patch statefulset openldap --type merge \
  -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"no-pull-secret"}]}}}}'
# 3. push the pullSecret fix to Git; the root app re-enables automated from Git
```

---

## Troubleshooting quick reference

| Symptom | Likely cause / fix |
|---|---|
| App `Unknown` + `ComparisonError` | Bad/empty merge key in a list (see above), or repo unreachable |
| App `OutOfSync` but won't converge | A stale sync operation is stuck — clear `/operation`, hard-refresh |
| `Authentication failed` on push | Use a PAT, not a password; `repo` scope |
| Change in Git not reflected | `automated` polls ~3 min; force with `argocd.argoproj.io/refresh=hard` |
| Resource keeps reverting | It's managed — edit Git, not the live object (`selfHeal`) |

---

## Note on secrets

The Keycloak bootstrap admin and LDAP passwords sit in plaintext in this repo —
fine for a throwaway local lab, **not** for anything real. For a durable setup
use **Sealed Secrets** or **External Secrets** so nothing sensitive lives in Git.
