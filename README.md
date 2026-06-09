# minikube GitOps (ArgoCD)

ArgoCD-managed workloads for the local minikube lab, using the **app-of-apps**
pattern. One root Application watches `apps/` and creates the child Applications.

```
gitops/
├── bootstrap/
│   └── root-app.yaml          # app-of-apps root (apply this once)
├── apps/                      # child ArgoCD Applications (watched by root)
│   ├── openldap.yaml          # Helm chart (external repo) + inlined values
│   ├── phpldapadmin.yaml      # -> manifests/phpldapadmin
│   └── keycloak.yaml          # -> manifests/keycloak
└── manifests/
    ├── phpldapadmin/          # Deployment + Service + Ingress
    └── keycloak/              # Secret + Deployment + Service + Ingress
```

## Scope

- **Managed by ArgoCD:** OpenLDAP, phpLDAPadmin, Keycloak (workloads only).
- **NOT managed by ArgoCD:** the Keycloak `demo` realm and the LDAP user
  federation — those are configured via the Keycloak Admin API / the
  `keycloak-ldap-federation.sh` script, because they aren't plain Kubernetes
  objects.

## Bootstrap

1. Push this repo to your Git remote and set the URL in the Application manifests
   (replace every `__REPO_URL__`). The `openldap` app uses the upstream Helm repo
   and needs no change.
2. Apply the root app once:

   ```bash
   kubectl apply -f bootstrap/root-app.yaml
   ```

3. Watch ArgoCD reconcile:

   ```bash
   kubectl -n argocd get applications.argoproj.io -w
   ```

## Notes

- `automated.prune` + `selfHeal` are on: ArgoCD reverts out-of-band `kubectl`
  changes and deletes resources removed from Git.
- The `*.nip.io` ingress hostnames embed the minikube IP (`192.168.64.3`). If the
  IP changes, update the Ingress hosts and commit.
- Secrets (Keycloak bootstrap admin, LDAP passwords) are in plaintext here for a
  local lab. For anything real, use Sealed Secrets / External Secrets instead.
