# minikube GitOps (ArgoCD)

ArgoCD-managed workloads for the local minikube lab, using the **app-of-apps**
pattern. One root Application watches `apps/` and creates the child Applications.

```
gitops/
├── bootstrap/
│   └── root-app.yaml          # app-of-apps root (apply this once)
├── apps/                      # child ArgoCD Applications (watched by root)
│   ├── openldap.yaml          # Helm chart (external repo) + values from this repo
│   ├── phpldapadmin.yaml      # -> manifests/phpldapadmin
│   ├── keycloak.yaml          # -> manifests/keycloak
│   └── react-app.yaml         # -> manifests/react-app
├── manifests/
│   ├── openldap/             # values.yaml for the Helm chart (no raw objects)
│   ├── phpldapadmin/          # Deployment + Service + Ingress
│   ├── keycloak/             # Secret + Deployment + Service + Ingress
│   └── react-app/            # nginx + Kustomize ConfigMap (index.html) + Ingress
└── docs/                      # step-by-step guides for the whole lab
```

> **`manifests/` vs `apps/`:** files in `manifests/` are the *payload* — for
> phpLDAPadmin/Keycloak the actual `Deployment`/`Service`/`Ingress` objects, and
> for OpenLDAP the Helm `values.yaml`. Files in `apps/` are ArgoCD `Application`
> objects that *point* at those and keep them synced. OpenLDAP installs from an
> external Helm chart rather than raw YAML, so its `manifests/openldap/` folder
> holds only the chart values, not Kubernetes objects.

## Documentation

Full walkthroughs in [`docs/`](docs/):

- [openldap-minikube-guide.md](docs/openldap-minikube-guide.md) — install OpenLDAP + phpLDAPadmin
- [keycloak-minikube-guide.md](docs/keycloak-minikube-guide.md) — install Keycloak
- [keycloak-openldap-federation-guide.md](docs/keycloak-openldap-federation-guide.md) — federate Keycloak to OpenLDAP (+ `keycloak-ldap-federation.sh`)
- [argocd-gitops-guide.md](docs/argocd-gitops-guide.md) — this GitOps setup, adoption, and the `imagePullSecrets` gotcha

## Scope

- **Managed by ArgoCD:** OpenLDAP, phpLDAPadmin, Keycloak, react-app (workloads only).
- **NOT managed by ArgoCD:** the Keycloak `demo` realm and the LDAP user
  federation — those are configured via the Keycloak Admin API / the
  `keycloak-ldap-federation.sh` script, because they aren't plain Kubernetes
  objects.

## Bootstrap

1. Push this repo to your Git remote
   (`https://github.com/shaqa3/homelab-gitops.git`). The child Application
   manifests already point at it; the `openldap` app uses the upstream Helm repo
   and needs no change.
2. Apply the root app once:

   ```bash
   kubectl apply -f bootstrap/root-app.yaml
   ```

3. Watch ArgoCD reconcile:

   ```bash
   kubectl -n argocd get applications.argoproj.io -w
   ```

## OpenLDAP values explained

OpenLDAP installs from the upstream Helm chart (`helm-openldap/openldap` 2.0.4),
but its values live in this repo at
[`manifests/openldap/values.yaml`](manifests/openldap/values.yaml). The
`apps/openldap.yaml` Application wires them in with a **multi-source** setup: the
chart from the Helm repo, the values file from this Git repo, joined via a
`$values` reference (`valueFiles: [$values/manifests/openldap/values.yaml]`).

| Value | Meaning |
|---|---|
| `replicaCount: 1` | Single instance — no HA for a local lab. |
| `image.repository/tag` | `osixia/openldap:1.5.0`, the public OpenLDAP image. |
| `image.pullSecret: "no-pull-secret"` | **Must be a non-empty name.** The chart always renders an `imagePullSecrets` entry from this; `""` produces a null-named entry that breaks ArgoCD's diff and makes self-heal append empties forever. The named secret need not exist — the public image pulls anonymously. |
| `replication.enabled: false` | No multi-master replication. |
| `tls.enabled: false` / `LDAP_TLS: "false"` | Plain LDAP on port 389 (simpler for local testing). |
| `LDAP_ORGANISATION` / `LDAP_DOMAIN` | `Example Inc.` / `example.org` → base DN `dc=example,dc=org`. |
| `LDAP_BACKEND: "mdb"` | LMDB storage backend (the OpenLDAP default). |
| `adminPassword` / `configPassword` | Bind passwords for `cn=admin,dc=example,dc=org` and `cn=admin,cn=config`. |
| `persistence.enabled: true`, `size: 1Gi` | A 1Gi PVC so LDAP data survives pod restarts. |
| `ltb-passwd.enabled: false`, `phpldapadmin.enabled: false` | Disable the chart's bundled UIs (they ship a deprecated Ingress apiVersion). phpLDAPadmin is deployed separately under `manifests/phpldapadmin`. |
| `service.*` | ClusterIP exposing 389 (LDAP) and 636 (LDAPS). |

To change OpenLDAP config, edit `manifests/openldap/values.yaml`, commit, and
push — ArgoCD re-renders the chart and syncs.

## react-app (static SPA, no image build)

The React login demo (`docs/`-documented app) is served at
`http://react.192.168.64.3.nip.io` by a stock **`nginx:alpine`** with the app's
`index.html` provided by a **Kustomize `configMapGenerator`** — so there's **no
custom image to build or push**, and the whole thing is reproducible from Git.
Kustomize hashes the ConfigMap name from the file contents, so editing
`manifests/react-app/index.html` and pushing automatically rolls the pod.

The app authenticates against Keycloak's `demo` realm using the public client
`react-app`. That client's Valid redirect URIs / Web origins include
`http://react.192.168.64.3.nip.io` (alongside the local dev ports). The Keycloak
client itself is **not** in Git (it's realm config, like the LDAP federation).

## Notes

- `automated.prune` + `selfHeal` are on: ArgoCD reverts out-of-band `kubectl`
  changes and deletes resources removed from Git.
- The `*.nip.io` ingress hostnames embed the minikube IP (`192.168.64.3`). If the
  IP changes, update the Ingress hosts and commit.
- Secrets (Keycloak bootstrap admin, LDAP passwords) are in plaintext here for a
  local lab. For anything real, use Sealed Secrets / External Secrets instead.
