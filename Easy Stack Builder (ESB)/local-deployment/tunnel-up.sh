#!/usr/bin/env bash
#
# Expose a locally deployed OCM-W + PCM cloud wallet through Cloudflare quick
# tunnels (trycloudflare.com), without owning a domain or public IP.
#
# Prerequisites:
#   - OCM-WStack deployed (see OCM-WStack/deploy.sh) into $OCM_NS
#   - PCM deployed (see PCM/deploy.sh) into $PCM_NS
#   - ingress-nginx answering on https://127.0.0.1:443 (Rancher Desktop
#     forwards the LoadBalancer service there; adjust ORIGIN otherwise)
#   - cloudflared in PATH
#
# What it does:
#   1. Starts two quick tunnels against the local ingress controller, using
#      --http-host-header so the existing ingress rules match:
#        tunnel A -> cloud-wallet.$DOMAIN       (wallet UI + APIs)
#        tunnel B -> auth-cloud-wallet.$DOMAIN  (Keycloak)
#   2. Points Keycloak's KC_HOSTNAME_URL/KC_HOSTNAME_ADMIN_URL at tunnel B so
#      issuer and all OIDC endpoints are generated with the public URL.
#   3. Rewrites the Configuration Service data (auth/baseUrl) so the web UI,
#      which fetches its Keycloak config at runtime, receives the tunnel URLs.
#   4. Adds the tunnel URL to the webui client's redirectUris/webOrigins.
#
# Quick-tunnel URLs are random and change on every cloudflared restart:
# rerun this script after restarting the tunnels.
#
# Usage: ./tunnel-up.sh <domain> <ocm-namespace> <pcm-namespace> [origin]

set -euo pipefail

DOMAIN="${1:?domain used at deploy time is required (e.g. xfsc.internal)}"
OCM_NS="${2:?ocm namespace is required}"
PCM_NS="${3:?pcm namespace is required}"
ORIGIN="${4:-https://127.0.0.1:443}"
STATE_DIR="${TUNNEL_STATE_DIR:-/tmp/xfsc-tunnels}"

mkdir -p "$STATE_DIR"

start_tunnel() {
  local name="$1" host="$2" log="$STATE_DIR/$1.log"
  : > "$log"
  nohup cloudflared tunnel --url "$ORIGIN" --no-tls-verify \
    --http-host-header "$host" --origin-server-name "$host" \
    > "$log" 2>&1 &
  echo $! > "$STATE_DIR/$name.pid"
  for _ in $(seq 1 30); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | head -1 || true)"
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    sleep 1
  done
  echo "ERROR: tunnel $name did not report a URL, see $log" >&2
  return 1
}

echo ">> starting quick tunnels against $ORIGIN"
WALLET_URL="$(start_tunnel wallet "cloud-wallet.${DOMAIN}")"
AUTH_URL="$(start_tunnel auth "auth-cloud-wallet.${DOMAIN}")"
printf 'WALLET_URL=%s\nAUTH_URL=%s\n' "$WALLET_URL" "$AUTH_URL" | tee "$STATE_DIR/urls.env"

echo ">> pointing Keycloak hostname config at $AUTH_URL"
kubectl set env statefulset/keycloak -n "$OCM_NS" \
  KC_HOSTNAME_URL="$AUTH_URL" KC_HOSTNAME_ADMIN_URL="$AUTH_URL"
kubectl rollout status statefulset/keycloak -n "$OCM_NS" --timeout=5m

echo ">> rewriting Configuration Service data"
kubectl patch configmap configuration-service -n "$PCM_NS" --type merge \
  -p "{\"data\":{\"auth\":\"$AUTH_URL\",\"baseUrl\":\"$WALLET_URL\"}}"
kubectl rollout restart deploy/configuration-service -n "$PCM_NS"
kubectl rollout status deploy/configuration-service -n "$PCM_NS" --timeout=2m

echo ">> repointing OID4VCI issuer components at $WALLET_URL"
# The credential offer deep links, issuer metadata (/.well-known/openid-credential-issuer),
# and the pre-auth token endpoint all embed the public wallet URL. Rewrite every
# occurrence of the deploy-time domain or a previous tunnel hostname.
WALLET_HOST="${WALLET_URL#https://}"
REWRITE="s|https://cloud-wallet\.${DOMAIN}|$WALLET_URL|g; s|https://[a-z0-9-]+\.trycloudflare\.com|$WALLET_URL|g; s|cloud-wallet\.${DOMAIN}|$WALLET_HOST|g; s|[a-z0-9-]+\.trycloudflare\.com|$WALLET_HOST|g"
for cm in credential-issuance-service-configmap preauthbridge-configmap; do
  kubectl get configmap "$cm" -n "$OCM_NS" -o json | sed -E "$REWRITE" | kubectl apply -f -
done
for d in issuance-service well-known-service didcomm-connector pre-authorization-bridge; do
  kubectl get deploy "$d" -n "$OCM_NS" -o json | sed -E "$REWRITE" | kubectl apply -f -
  kubectl rollout status deploy/"$d" -n "$OCM_NS" --timeout=3m || true
done
# dummycontentsigner's rendered manifest carries an invalid empty imagePullSecrets
# entry that breaks strategic-merge patching, and its readiness probe never passes
# (it still broadcasts issuer metadata over NATS). Clean both up, then set the env
# directly; with maxUnavailable=1 the stale broadcaster pod is actually replaced.
kubectl patch deploy dummycontentsigner -n "$OCM_NS" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/imagePullSecrets"}]' 2>/dev/null || true
kubectl patch deploy dummycontentsigner -n "$OCM_NS" --type=merge \
  -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1}}}}'
kubectl set env deploy/dummycontentsigner -n "$OCM_NS" \
  ORIGIN="$WALLET_URL" CREDENTIAL_ISSUER="$WALLET_URL" \
  AUTHORIZATION_SERVER="$WALLET_URL" CREDENTIAL_ENDPOINT="$WALLET_URL/api/issuance/credential"
# Stale metadata rows (previous hostname) age out of the well-known store once the
# old broadcaster is gone; allow up to ~2 minutes before offers show the new URL.

echo ">> updating webui client redirect URIs"
KC_POD="$(kubectl -n "$OCM_NS" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"
PASS="$(kubectl -n "$OCM_NS" get secret keycloak-init-secrets -o jsonpath='{.data.password}' | base64 -d)"
kubectl -n "$OCM_NS" exec -i "$KC_POD" -- sh -lc "
  mkdir -p /tmp/kcadm && HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh config credentials \
    --config /tmp/kcadm/config --server http://localhost:8080/ --realm master \
    --user admin --password '$PASS' >/dev/null
  CID=\$(HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get clients -r master -q clientId=webui \
    --config /tmp/kcadm/config | sed -n 's/.*\"id\" : \"\([^\"]*\)\".*/\1/p' | head -1)
  HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh update clients/\$CID -r master --config /tmp/kcadm/config \
    -s 'redirectUris=[\"$WALLET_URL/*\",\"https://cloud-wallet.${DOMAIN}/*\",\"http://localhost:3000/*\"]' \
    -s 'webOrigins=[\"$WALLET_URL\",\"https://cloud-wallet.${DOMAIN}\",\"http://localhost:3000\"]' \
    -s rootUrl='$WALLET_URL' -s baseUrl='$WALLET_URL'
"

echo
echo "Wallet UI:  $WALLET_URL   (ingress basic auth: admin/admin)"
echo "Keycloak:   $AUTH_URL"
echo "Tunnel PIDs and logs in $STATE_DIR; kill \$(cat $STATE_DIR/*.pid) to stop."
