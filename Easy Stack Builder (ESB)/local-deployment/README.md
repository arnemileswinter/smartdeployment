# Local deployment: OCM-W cloud wallet + PCM web UI behind trycloudflare

Notes from getting the full OCM-W stack plus the PCM web wallet UI running on a
single machine (Rancher Desktop k3s on WSL2, docker container runtime) and
exposing it publicly through Cloudflare quick tunnels — no owned domain, no
public IP, no registry account.

## Overview

1. Deploy the OCM-W stack with a **fake domain** and a **self-signed wildcard
   certificate**:

   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
     -keyout wildcard.key -out wildcard.crt \
     -subj "/CN=*.xfsc.internal" \
     -addext "subjectAltName=DNS:*.xfsc.internal,DNS:xfsc.internal"

   bash OCM-WStack/deploy.sh ocm xfsc.internal wildcard.crt wildcard.key you@example.com ~/.kube/config
   ```

2. Deploy PCM on top. With a docker-runtime cluster (Rancher Desktop) the web
   UI image is built locally and consumed directly by the kubelet, so the
   registry arguments are placeholders:

   ```bash
   bash PCM/deploy.sh pcm ocm xfsc.internal wildcard.crt wildcard.key ~/.kube/config \
     local/cloud-wallet-web-ui local local \
     DeveloperCredential ocm 365 statuslist xfsc
   ```

3. Apply the stack correctness fixes (see "Making issuance actually work"):

   ```bash
   ./local-deployment/fix-stack.sh ocm
   ```

4. Expose it and wire all OIDC URLs to the tunnel:

   ```bash
   ./local-deployment/tunnel-up.sh xfsc.internal ocm pcm
   ```

The script prints the two `*.trycloudflare.com` URLs. The wallet UI sits behind
the ingress basic auth (admin/admin) from the PCM deployment.

## Why each change was needed

- **`PCM/deploy.sh`** created namespace-scoped baseline resources before any
  step created the namespace, so a fresh install always failed with
  `namespaces "pcm" not found`. The namespace is now ensured first. The
  failure-rollback (which deleted the whole namespace on any error) is skipped
  so a failed run can be diagnosed and resumed instead of starting over.
- **`PCM/deploy-core.sh`** resolved its Helm charts relative to the caller's
  working directory; it now `cd`s to its own location so it can be run from
  anywhere. The Docker Hub login/push was replaced with a plain local build:
  on a cluster whose container runtime is docker (Rancher Desktop), a locally
  built image is immediately visible to pods, no registry required.
- **`PCM/preflight.sh`** validated registry credentials with a real
  `docker login`; skipped for the same reason.
- **`PCM/Web-UI Service/values.yaml`** used `imagePullPolicy: Always`, which
  forces a registry pull even when the image only exists locally; changed to
  `IfNotPresent`.
- **`.env.production`** (new, was referenced by the build but not present in
  the repo): uses **relative** API URLs (`/api`, `/api/accounts`,
  `/api/configuration`). Next.js inlines these at build time; relative paths
  make the built UI hostname-agnostic, which is what allows it to be served
  through a random trycloudflare hostname without rebuilding. The Keycloak
  endpoint is not baked in at all — the UI fetches it at runtime from the
  Configuration Service, which `tunnel-up.sh` rewrites.
- **`AccountButton.tsx`** built the login `redirectUri` from the build-time
  `ENV_URL` variable, which either produced a malformed URI (relative
  `ENV_URL`, rejected by Keycloak with `Invalid parameter: redirect_uri`) or
  pinned the UI to one hostname. It now uses `window.location.origin`, so the
  redirect always matches the host the user is actually on.
- **`OCM-WStack/deploy.sh`**: rollback-on-error skipped, same reasoning as
  above (the uninstall step deletes the namespace including all state).

## How the tunnel wiring works

Cloudflare quick tunnels assign one random hostname per tunnel and cannot serve
subdomains, while the stack routes everything by `Host` header off one shared
domain. Two tunnels are used, each targeting the local ingress-nginx over TLS
(`--no-tls-verify`, self-signed origin cert) with `--http-host-header`
rewriting to the internal hostname the ingress rules expect:

| Tunnel | Host header sent to ingress | Serves |
|---|---|---|
| A | `cloud-wallet.<domain>` | web UI, account/config/plugin APIs, OCM endpoints |
| B | `auth-cloud-wallet.<domain>` | Keycloak |

Absolute URLs that leave the cluster are then repointed at the tunnels:
Keycloak's `KC_HOSTNAME_URL`/`KC_HOSTNAME_ADMIN_URL` (so the OIDC issuer and
all endpoints in the discovery document are public URLs), the Configuration
Service's `auth`/`baseUrl` data, and the `webui` client's
`redirectUris`/`webOrigins`. In-cluster service-to-service traffic keeps using
cluster-internal URLs and is unaffected.

## Making issuance actually work

As deployed, the stack cannot complete a single OID4VCI issuance — the published
images and chart values contain several incompatibilities that `fix-stack.sh`
repairs (each is documented inline in the script):

1. The pre-authorization bridge signs tokens in a Vault transit namespace derived
   from the k8s namespace, while the deploy script creates the signing key (and
   the JWKS publishes it) under `tenant_space`; its token `kid` (`did:web:…#signerkey`)
   also does not exist in the published key set, so the issuer rejects every token.
2. The credential-retrieval chart ships the placeholder NATS topic `signer-topic`
   for holder-binding signatures; the signer listens on `sign`.
3. The retrieval service panics on the token response of this stack's own bridge
   (`authorization_details` with empty `credential_identifiers`), and its fallback
   format-based credential request is rejected by the issuer service. A one-file
   patch (`credential-retrieval-service.patch`) requests by
   `credential_configuration_id` instead.
4. The published `sd-jwt-service:latest` hardcodes `hashAlg: 'SHA-256'` while its
   bundled `@sd-jwt/core` only accepts IANA lowercase names — every SD-JWT
   creation fails with `Invalid hash algorithm: SHA-256`.
5. The dummycontentsigner (which both broadcasts the issuer metadata and
   materializes the demo credentials) has a readiness probe against an HTTP
   server the app does not have, plus an invalid `imagePullSecrets` entry that
   breaks patching; rollouts wedge and stale pods keep broadcasting old metadata.

## Using the wallet

The web wallet does not scan QR codes — a QR is just an encoded
`openid-credential-offer://` link, and the wallet consumes the link directly:

1. Log in, go to **DID** and create a DID (this is the holder key; without it
   offers cannot be accepted).
2. Go to **Issuance**, pick a credential type (e.g. SDJWTCredential), fill the
   fields, and copy the generated offer link.
3. Go to **Offering**, paste the link, then select the offer and **Accept** it,
   choosing your DID. The credential lands under **Credentials**.

Any external OID4VCI issuer offer (e.g. decoded from a QR) can be pasted the
same way, as long as its `credential_issuer` URL is reachable from the cluster.

## Known quirks

- Quick-tunnel URLs rotate on every cloudflared restart; rerun `tunnel-up.sh`
  afterwards.
- The very first authenticated `/api/accounts` request for a new user can
  return `424 crypto engine failed` while the per-user Vault key is being
  bootstrapped; it succeeds from the second request on.
- Let's Encrypt issuance obviously cannot complete for the fake domain; the
  ingress TLS falls back to the provided wildcard secret, which is fine because
  Cloudflare terminates public TLS at the tunnel edge.
