# Installing OpenLDAP in Minikube

A step-by-step guide to deploying a single-node OpenLDAP server into a local
minikube cluster using Helm. Tested with Helm v4, minikube, and the
`osixia/openldap` image.

---

## Prerequisites

- A running minikube cluster (`minikube status` shows `host: Running`)
- `kubectl` pointed at the minikube context (`kubectl config current-context` → `minikube`)
- `helm` installed (`helm version`)

---

## Why this chart / image

There are two community charts in the `helm-openldap` repo:

| Chart | Image | Notes |
|---|---|---|
| `helm-openldap/openldap` | `osixia/openldap` (public) | Lightweight, simple. **Use this for local/dev.** |
| `helm-openldap/openldap-stack-ha` | Bitnami | HA + replication + UIs, but pulls Bitnami images whose free access is now restricted. |

We use the lightweight `openldap` chart with the public `osixia/openldap` image —
no registry credentials required.

---

## Step 1 — Add the Helm repo

```bash
helm repo add helm-openldap https://jp-gouin.github.io/helm-openldap/
helm repo update helm-openldap
helm search repo helm-openldap
```

## Step 2 — Create a values file

Save as `openldap-values.yaml`:

```yaml
# Minikube-friendly OpenLDAP values (helm-openldap/openldap, osixia image)
replicaCount: 1

image:
  repository: osixia/openldap
  tag: 1.5.0
  pullPolicy: IfNotPresent
  pullSecret: ""   # empty -> anonymous pull of the public osixia image

# Single-node: no replication
replication:
  enabled: false

# Disable TLS to keep things simple for local testing (plain LDAP on 389)
tls:
  enabled: false
env:
  LDAP_ORGANISATION: "Example Inc."
  LDAP_DOMAIN: "example.org"
  LDAP_TLS: "false"
  LDAP_BACKEND: "mdb"

adminPassword: admin
configPassword: config

persistence:
  enabled: true
  size: 1Gi

# Disable the self-service password ingress component
ltb-passwd:
  enabled: false

# Disable phpldapadmin (its subchart uses a deprecated Ingress API version)
phpldapadmin:
  enabled: false

service:
  type: ClusterIP
  ldapPort: 389
  sslLdapPort: 636
```

> Change `adminPassword` / `configPassword` for anything beyond local testing.

## Step 3 — Install

```bash
kubectl create namespace openldap

helm install openldap helm-openldap/openldap --version 2.0.4 \
  -n openldap -f openldap-values.yaml
```

## Step 4 — Wait for the pod to become ready

```bash
kubectl -n openldap rollout status statefulset/openldap --timeout=180s
kubectl -n openldap get pods,svc
```

Expected:

```
NAME             READY   STATUS    RESTARTS   AGE
pod/openldap-0   1/1     Running   0          33s
```

## Step 5 — Verify it works

Run an `ldapsearch` from inside the pod:

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin
```

A healthy server returns the base entry and `result: 0 Success`:

```ldif
dn: dc=example,dc=org
objectClass: top
objectClass: dcObject
objectClass: organization
o: Example Inc.
dc: example

result: 0 Success
```

---

## Connection details

| Setting | Value |
|---|---|
| Service (in-cluster) | `openldap.openldap.svc.cluster.local:389` |
| Base DN | `dc=example,dc=org` |
| Admin bind DN | `cn=admin,dc=example,dc=org` |
| Admin password | `admin` |
| Config password | `config` |

### Credentials (username & password)

The **username** is the bind DN (fixed by convention, derived from the domain):

| Role | Bind DN (username) | Password source |
|---|---|---|
| Directory admin | `cn=admin,dc=example,dc=org` | `LDAP_ADMIN_PASSWORD` |
| Config admin (`olc*`) | `cn=admin,cn=config` | `LDAP_CONFIG_PASSWORD` |

The **passwords** are stored in the `openldap` Kubernetes secret. Retrieve them:

```bash
# admin password
kubectl get secret -n openldap openldap -o jsonpath="{.data.LDAP_ADMIN_PASSWORD}" | base64 --decode; echo

# config password
kubectl get secret -n openldap openldap -o jsonpath="{.data.LDAP_CONFIG_PASSWORD}" | base64 --decode; echo
```

List every key stored in the secret:

```bash
kubectl get secret -n openldap openldap -o jsonpath='{.data}' | tr ',' '\n'
# or, decode all keys at once:
kubectl get secret -n openldap openldap -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
```

> These passwords are whatever you set in `openldap-values.yaml`
> (`adminPassword` / `configPassword`). The secret is the source of truth if you
> forget them.

### Access from your laptop

```bash
kubectl -n openldap port-forward svc/openldap 1389:389

# in another terminal
ldapsearch -x -H ldap://localhost:1389 -b dc=example,dc=org \
  -D "cn=admin,dc=example,dc=org" -w admin
```

---

## Adding entries (optional)

Create an OU and a user, then load it:

```bash
cat > seed.ldif <<'EOF'
dn: ou=people,dc=example,dc=org
objectClass: organizationalUnit
ou: people

dn: uid=jdoe,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
cn: John Doe
sn: Doe
uid: jdoe
userPassword: secret123
EOF

kubectl -n openldap cp seed.ldif openldap-0:/tmp/seed.ldif
kubectl -n openldap exec openldap-0 -- ldapadd -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=org" -w admin -f /tmp/seed.ldif
```

---

## Viewing / listing users

All commands bind as admin — osixia hides the directory from anonymous queries,
so `-D`/`-w` are required (an anonymous search returns `No such object`).

**List all users** (with chosen attributes):

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "ou=people,dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin \
  "(objectClass=inetOrgPerson)" uid cn mail
```

**Just the usernames (DNs):**

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "ou=people,dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin \
  "(uid=*)" dn
```

**One specific user, all attributes:**

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "uid=jdoe,ou=people,dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin
```

**The whole tree** (base entry, OUs, and all users):

```bash
kubectl -n openldap exec openldap-0 -- ldapsearch -x -H ldap://localhost:389 \
  -b "dc=example,dc=org" -D "cn=admin,dc=example,dc=org" -w admin "(objectClass=*)" dn
```

`-b` = search base · `-D` = bind DN · `-w` = password · the last quoted arg is
the LDAP filter · any trailing words are the attributes to return.

**From your laptop** instead of inside the pod — port-forward and use a local
`ldapsearch` (macOS: `brew install openldap`):

```bash
kubectl -n openldap port-forward svc/openldap 1389:389
# in another terminal:
ldapsearch -x -H ldap://localhost:1389 -b "ou=people,dc=example,dc=org" \
  -D "cn=admin,dc=example,dc=org" -w admin "(uid=*)" uid cn mail
```

**Visually:** browse the tree in phpLDAPadmin (see the next section) — expand
`dc=example,dc=org → ou=people` and click a user.

---

## Web UI: phpLDAPadmin (optional)

The chart's bundled phpLDAPadmin is disabled (deprecated Ingress API). Instead,
deploy the companion `osixia/phpldapadmin` image with a plain manifest — no
chart, no API-version issues.

Save as `phpldapadmin.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: phpldapadmin
  namespace: openldap
  labels:
    app: phpldapadmin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: phpldapadmin
  template:
    metadata:
      labels:
        app: phpldapadmin
    spec:
      containers:
        - name: phpldapadmin
          image: osixia/phpldapadmin:0.9.0
          imagePullPolicy: IfNotPresent
          env:
            # Point at the OpenLDAP service in the same namespace
            - name: PHPLDAPADMIN_LDAP_HOSTS
              value: "openldap"
            # Serve plain HTTP (OpenLDAP here runs without TLS)
            - name: PHPLDAPADMIN_HTTPS
              value: "false"
          ports:
            - containerPort: 80
              name: http
---
apiVersion: v1
kind: Service
metadata:
  name: phpldapadmin
  namespace: openldap
  labels:
    app: phpldapadmin
spec:
  type: ClusterIP
  selector:
    app: phpldapadmin
  ports:
    - port: 80
      targetPort: 80
      name: http
```

Deploy and wait for it to be ready:

```bash
kubectl apply -f phpldapadmin.yaml
kubectl -n openldap rollout status deploy/phpldapadmin --timeout=120s
```

Open the UI via port-forward:

```bash
kubectl -n openldap port-forward svc/phpldapadmin 8081:80
# then browse to http://localhost:8081
```

Log in with:

| Field | Value |
|---|---|
| Login DN | `cn=admin,dc=example,dc=org` |
| Password | `admin` |

> **Note on `PHPLDAPADMIN_HTTPS`:** it's set to `false` because this OpenLDAP
> runs without TLS. If you re-enable TLS on OpenLDAP, also set
> `PHPLDAPADMIN_LDAP_HOSTS` appropriately and consider serving the UI over HTTPS.

### Expose it via Ingress (no port-forward)

If you have ingress-nginx installed, you can reach the UI at a stable hostname
instead of port-forwarding. This uses [`nip.io`](https://nip.io) — a wildcard
DNS service where `anything.<IP>.nip.io` resolves to `<IP>` — so no `/etc/hosts`
editing is needed.

First find your minikube IP and confirm the ingress controller is reachable:

```bash
minikube ip                       # e.g. 192.168.64.3
kubectl get ingressclass          # confirm an "nginx" class exists
```

Save as `phpldapadmin-ingress.yaml` (replace `192.168.64.3` with your minikube IP):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phpldapadmin
  namespace: openldap
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
    # nip.io resolves *.192.168.64.3.nip.io -> 192.168.64.3 (the minikube IP)
    - host: phpldapadmin.192.168.64.3.nip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: phpldapadmin
                port:
                  number: 80
```

Apply and browse:

```bash
kubectl apply -f phpldapadmin-ingress.yaml
# then open in a browser:
open http://phpldapadmin.192.168.64.3.nip.io
```

> **Reaching the controller:** with the `vfkit`/`hyperkit` minikube drivers the
> node IP is routable from the host and the nginx controller binds host port 80,
> so the hostname above works directly. With the **docker** driver, run
> `minikube tunnel` (keep it running) so `192.168.64.x:80` is reachable, or use
> `minikube service ingress-nginx-controller -n ingress-nginx --url` and append
> that NodePort to the URL.

### Remove phpLDAPadmin

```bash
kubectl delete -f phpldapadmin-ingress.yaml   # if you created the ingress
kubectl delete -f phpldapadmin.yaml
```

---

## Troubleshooting (gotchas hit during this install)

**`ImagePullBackOff` → `unauthorized: incorrect username or password`**
The chart always renders an `imagePullSecrets` entry (defaults to a `harbor`
secret). If you point it at a docker-registry secret holding *dummy* credentials,
Docker tries to authenticate with those bad creds instead of pulling the public
image anonymously — and fails. **Fix:** set `image.pullSecret: ""` so the pull
falls back to anonymous.

**`no matches for kind "Ingress" in version "extensions/v1beta1"`**
The bundled `phpldapadmin` (and `ltb-passwd`) subcharts use a long-removed
Ingress API version. **Fix:** disable both in values
(`phpldapadmin.enabled: false`, `ltb-passwd.enabled: false`). If you want a web
UI, install a current phpLDAPadmin chart separately.

**Pod stuck `Pending` with `unbound immediate PersistentVolumeClaims`**
Transient while minikube's default `standard` StorageClass provisions the PVC;
it resolves on its own. Confirm with `kubectl -n openldap get pvc`.

---

## Uninstall / cleanup

```bash
helm uninstall openldap -n openldap
kubectl -n openldap delete pvc --all     # removes persisted data
kubectl delete namespace openldap
```
