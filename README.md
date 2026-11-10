# Install Digin

Digin is a self-hosted work app: issues, pages, chat, calls and meetings in one small server you run
yourself, built to run inside a government boundary (FISMA Moderate, IL4 for the native apps).

This repository installs it, with Helm or Docker Compose. More at **https://about.digin.work**.

## The 90-day evaluation

Anyone may install Digin and evaluate it for **90 days** from its first start, with no sign-up and no
call home. Digin checks its license on your server, offline: no telemetry, no update check. After 90 days
without a license key it becomes **read-only**: people can still sign in, read, search and export, and
nothing can be created or changed until an administrator enters a key. Digin is proprietary, not open
source; see [LICENSE](LICENSE). To buy a license: **sales@digin.work**.

## What you need

- An **https address** for it, such as `https://digin.example.com`, with TLS ended at your ingress or proxy.
- An **OpenID Connect provider** (Keycloak, Entra ID, Okta, Authentik, Google Workspace and others) with
  a client whose redirect URL is `https://digin.example.com/auth/callback`. Digin keeps no passwords.
- Kubernetes 1.27 or later and Helm 3.8 or later, or a Linux host with Docker Compose 2.24 or later.

The images are `ghcr.io/arlintdev/digin:vX.Y.Z` and, with the validated Go Cryptographic Module in
FIPS 140-3 mode, `ghcr.io/arlintdev/digin:vX.Y.Z-fips`.

## Install with Helm

```bash
cat > digin-values.yaml <<'EOF'
publicUrl: https://digin.example.com
signIn:
  oidc:
    issuer: https://login.example.com/realms/work
    clientId: digin
    clientSecret: "<from your provider>"
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-buffering: "off"      # GET /api/v1/live is a long-lived stream
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: 25m
  tls:
    secretName: digin-tls
EOF
helm install digin oci://ghcr.io/arlintdev/charts/digin -n digin --create-namespace -f digin-values.yaml
```

The chart runs PostgreSQL 17 beside the app and generates the database passwords and the **files key**,
which seals every uploaded file. Back the key up now; without it the files cannot be read:

```bash
kubectl -n digin get secret digin-secrets -o jsonpath='{.data.files-key}' | base64 -d
```

Every setting is in [charts/digin/values.yaml](charts/digin/values.yaml). The ones most installs change:

| Value | What it does |
| --- | --- |
| `image.fips: true` | The `-fips` image, and the server refuses to start outside FIPS 140-3 mode |
| `secrets.existingSecret` | Your own Secret instead of the chart's (keys listed in values.yaml) |
| `postgresql.enabled: false` + `externalDatabase.*` | Your own PostgreSQL (below) |
| `clamav.enabled: true` | ClamAV scans every upload before it is kept (needs 1 to 3 GiB of memory) |
| `config.profile: fisma-moderate` | Any departure from Digin's secure baseline stops the server |
| `networkPolicy.ingressFrom` | Who may reach the app (your ingress controller's namespace) |
| `env`, `secretFiles` | Any other Digin setting, and any other secret, as a file |
| `replicaCount` + `persistence.accessModes: [ReadWriteMany]` | Several servers behind the Service (below) |

**Your own PostgreSQL.** Make an empty database owned by a role for Digin. If that role is a superuser
(the default, `database.logins: separate`), Digin's migrate step makes the two logins the app signs in as,
which own nothing and are not superusers. On a managed PostgreSQL where it is an ordinary role, set
`database.logins: owner` and the app signs in as the owner. Give its password as
`secrets.dbOwnerPassword` (or `db-owner-password` in your Secret) and its CA in `externalDatabase.caSecret`.

The app runs as uid 65532 with a read-only root filesystem, no capabilities and the RuntimeDefault seccomp
profile. Database migrations run in an init container (`digin migrate`, as the database's owner) before
every start, so the app container never holds the owner's password. ClamAV starts as root and steps down,
so a namespace with it needs the `baseline` Pod Security level.

**Several replicas.** Set `replicaCount` to 2 or more with a `ReadWriteMany` files volume
(`persistence.accessModes: [ReadWriteMany]` on a storage class that offers it, such as NFS, EFS, Azure
Files or CephFS, or an `existingClaim` that is). The servers share the database and the files: live
updates, presence and calls work across them, and one server holds the calls at a time and hands them over
when it stops. The chart then:

- rolls updates one pod at a time with none down (`RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0`;
  with one `ReadWriteOnce` volume it is `Recreate`);
- keeps one pod up through node drains (a PodDisruptionBudget, `minAvailable: 1`) and spreads the pods
  across nodes (`topologySpreadConstraints`, replaceable);
- names each server after its pod (`DIGIN_INSTANCE`, from the downward API), probes readiness on
  `/readyz` and liveness on `/healthz`, and gives a stopping pod `shutdownDelaySeconds` (5) to drain,
  20s for the requests under way and 5s more (`terminationGracePeriodSeconds` is raised to fit);
- raises the bundled PostgreSQL's `max_connections` to fit (each server opens up to 33; an external
  database needs as many for each server, and one more server's worth for a rolling update);
- runs `digin migrate` in every new pod's init container. Steps started together take their turns
  under a database lock, so the first migrates and the rest find it done; during a rolling update the
  old pods serve on, since every Digin migration only adds.

Calls' media go browser to browser by default, and need nothing per replica. Through the server
(`env: {DIGIN_CALLS_MEDIA: sfu}`) every call's media go to the pod holding the calls at a UDP address
browsers reach directly, never through a load balancer, so each replica needs an address of its own:
for example `hostNetwork` or a `hostPort` with the node's public address, or a `LoadBalancer` Service per
pod, with `DIGIN_CALLS_SFU_UDP` and `DIGIN_CALLS_SFU_ADDRESS` set per pod. The chart does not make these
and leaves it off.

## Install with Docker Compose

```bash
git clone https://github.com/arlintdev/digin-install && cd digin-install/compose
cp .env.example .env && chmod 600 .env     # set DIGIN_PUBLIC_URL, OIDC_ISSUER and OIDC_CLIENT_ID
sudo ./make-secrets.sh                     # the secret files in ./secrets; asks for the OIDC client secret
docker compose up -d                       # add --profile scan for ClamAV, and DIGIN_SCAN in .env
docker compose logs -f digin
```

The app listens on `127.0.0.1:3000` in plain HTTP; point your reverse proxy (Caddy, nginx, Traefik) at it
for the https address. Keep a copy of `secrets/files_key` somewhere safe.

## The first administrator

Sign in once at your address, then make yourself the organization's administrator:

```bash
kubectl -n digin exec deploy/digin -c digin -- digin org admin you@example.com     # Helm
docker compose exec digin digin org admin you@example.com                         # Compose
```

Anyone who signs in can make a workspace and invite others. `digin check` lists anything the deployment
does differently from Digin's secure baseline.

## Enter a license key

In the app: **Organisation → License**, paste the key, **Install**. Or at the shell:

```bash
kubectl -n digin exec -i deploy/digin -c digin -- digin license install - < license.txt   # Helm
docker compose exec -T digin digin license install - < license.txt                        # Compose
```

`digin license show` says the state and the days left. With several replicas, a key installed through one is seen by the
others within half a minute.

## Upgrade

Back up first. A new release migrates the database before it starts; there is no downgrade. With
several replicas the update rolls through them with none down.

```bash
helm upgrade digin oci://ghcr.io/arlintdev/charts/digin -n digin -f digin-values.yaml --version X.Y.Z
```

With Compose, set `DIGIN_RELEASE=vX.Y.Z` in `.env`, then `docker compose pull && docker compose up -d`.
Read the release notes before skipping releases.

## Back up

Three things: the database, the uploaded files, and the files key (kept apart from the other two).

```bash
# Helm, with the bundled PostgreSQL (or set backup.enabled for a nightly dump to a volume)
kubectl -n digin exec digin-postgresql-0 -- sh -c 'pg_dump -U digin -d digin -Fc' > digin.dump
kubectl -n digin exec deploy/digin -c digin -- digin files snapshot > digin-files.tar

# Compose
docker compose exec -T db pg_dump -U digin -d digin -Fc > digin.dump
docker compose exec -T digin digin files snapshot > digin-files.tar
```

The snapshot holds every file the database points at, still sealed with the files key. Encrypt both
before they leave the host.

## Help

- About Digin: https://about.digin.work
- Licenses and questions: sales@digin.work
- Security problems: security@arlint.dev
