# Installing Keycloak in Minikube

A step-by-step guide to running Keycloak (SSO / identity provider) in a local
minikube cluster. Uses the official `quay.io/keycloak/keycloak` image in **dev
mode** (`start-dev`) — an in-memory H2 database, so there's no external database
to set up — exposed via ingress-nginx using a `nip.io` hostname.

> Dev mode is for local/testing only. For anything persistent or
> production-like, run `start` (not `start-dev`) with an external Postgres and
> proper hostname/TLS configuration.

---

## Prerequisites

- A running minikube cluster (`minikube status` → `host: Running`)
- `kubectl` pointed at the minikube context
- **ingress-nginx** installed with an `nginx` IngressClass (`kubectl get ingressclass`)
- Your minikube IP (`minikube ip`) — used in the ingress hostname below

---

## Step 1 — Manifest

Save as `keycloak.yaml`. Replace `192.168.64.3` with your `minikube ip`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
---
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin
  namespace: keycloak
type: Opaque
stringData:
  # Bootstrap (temporary) admin account created on first start
  KC_BOOTSTRAP_ADMIN_USERNAME: admin
  KC_BOOTSTRAP_ADMIN_PASSWORD: admin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.6.3
          imagePullPolicy: IfNotPresent
          args: ["start-dev"]   # dev mode: in-memory H2 DB, no external database needed
          env:
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: KC_BOOTSTRAP_ADMIN_USERNAME
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: KC_BOOTSTRAP_ADMIN_PASSWORD
            # Trust X-Forwarded-* headers from the ingress so redirect URLs are correct
            - name: KC_PROXY_HEADERS
              value: "xforwarded"
            - name: KC_HTTP_ENABLED
              value: "true"
            # dev mode already relaxes hostname strictness
            - name: KC_HOSTNAME_STRICT
              value: "false"
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /realms/master
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 30
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              memory: "1Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  type: ClusterIP
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
spec:
  ingressClassName: nginx
  rules:
    # nip.io resolves *.192.168.64.3.nip.io -> 192.168.64.3 (the minikube IP)
    - host: keycloak.192.168.64.3.nip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080
```

## Step 2 — Deploy and wait

```bash
kubectl apply -f keycloak.yaml
kubectl -n keycloak rollout status deploy/keycloak --timeout=300s
```

The image is ~450 MB, so the first pull can take a minute or two.

## Step 3 — Access the admin console

Open in a browser:

```
http://keycloak.192.168.64.3.nip.io
```

Click **Administration Console** and log in:

| Field | Value |
|---|---|
| Username | `admin` |
| Password | `admin` |

## Step 4 — Verify (optional)

```bash
# Master realm should return HTTP 200 through the ingress
curl -s -o /dev/null -w "%{http_code}\n" http://keycloak.192.168.64.3.nip.io/realms/master

# Obtain an admin access token (proves login works end-to-end)
curl -s -X POST http://keycloak.192.168.64.3.nip.io/realms/master/protocol/openid-connect/token \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
  -d "grant_type=password" | head -c 80; echo
```

A working server returns `200` and a JSON object beginning with
`{"access_token":"eyJ...`.

---

## Credentials (username & password)

The admin credentials come from the `keycloak-admin` secret. Retrieve them:

```bash
kubectl get secret -n keycloak keycloak-admin \
  -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
```

> The `KC_BOOTSTRAP_ADMIN_*` account is a **temporary** bootstrap admin (Keycloak
> 26+). For a lasting setup, log into the `master` realm, create a permanent
> admin user, then remove the bootstrap credentials.

---

## Connection details

| Setting | Value |
|---|---|
| Admin console | `http://keycloak.192.168.64.3.nip.io/admin/` |
| Master realm (OIDC issuer) | `http://keycloak.192.168.64.3.nip.io/realms/master` |
| In-cluster URL | `http://keycloak.keycloak.svc.cluster.local:8080` |
| OIDC discovery | `…/realms/<realm>/.well-known/openid-configuration` |
| Admin user / pass | `admin` / `admin` |

### Access without ingress (port-forward)

```bash
kubectl -n keycloak port-forward svc/keycloak 8080:8080
# then open http://localhost:8080
```

---

## Notes & gotchas

- **Proxy headers:** `KC_PROXY_HEADERS=xforwarded` makes Keycloak trust the
  ingress's `X-Forwarded-*` headers so issuer/redirect URLs use the external
  hostname rather than the pod IP. Without it, OIDC redirects can break.
- **Buffer size:** the `proxy-buffer-size: 128k` ingress annotation prevents
  nginx `502`s caused by Keycloak's large auth response headers/cookies.
- **Data is ephemeral:** dev mode's H2 database lives inside the container.
  Deleting the pod wipes all realms/users. Add Postgres + a PVC for persistence.
- **IP changes on restart:** the `nip.io` hostname embeds the minikube IP. If
  minikube restarts and the IP changes, update the ingress `host` and re-apply.
- **Memory:** Keycloak wants ~512 MB–1 GB. If the pod gets OOMKilled, raise the
  memory limit (minikube node here has 2 CPU allocatable).

---

## Uninstall / cleanup

```bash
kubectl delete -f keycloak.yaml
```
