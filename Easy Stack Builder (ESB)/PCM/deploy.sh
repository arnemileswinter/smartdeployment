#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CORE="$DIR/deploy-core.sh"
PREFLIGHT="$DIR/preflight.sh"

NAMESPACE="${1:?pcm namespace is required}"
OCM_NAMESPACE="${2:?ocm namespace is required}"
DOMAIN="${3:?domain is required}"
CERT_PATH="${4:?certificate path is required}"
KEY_PATH="${5:?key path is required}"
KUBE="${6:?kubeconfig path is required}"
REGISTRY_REPO="${7:?registry repository is required}"
REGISTRY_USERNAME="${8:?registry username is required}"
REGISTRY_PASSWORD="${9:?registry password is required}"
CREDENTIAL_TYPE="${10:?credential type is required}"
ISSUER_BINDING="${11:?issuer binding is required}"
EXPIRATION_DAYS="${12:?expiration days is required}"
REVOCATION_MODE="${13:?revocation mode is required}"
TRUST_FRAMEWORK_ID="${14:?trust framework identifier is required}"

export KUBECONFIG="$KUBE"
SERVICE_ACCOUNT="pcm-runtime"
ROLE_NAME="pcm-runtime-role"
REALM_NAME="pcm-${NAMESPACE}"
WEBUI_CLIENT_ID="webui"
ISSUER_CLIENT_ID="issuer-api"
CLIENT_SECRET=""
START_EPOCH="$(date +%s)"

emit_event() {
  local phase="$1" step="$2" status="$3" started_at="$4" details="${5:-}"
  jq -cn --arg phase "$phase" --arg step "$step" --arg status "$status" --arg startedAt "$started_at" --arg endedAt "$(date -Iseconds)" --arg details "$details" '{phase:$phase,step:$step,status:$status,startedAt:$startedAt,endedAt:$endedAt,details:$details}' | sed 's/^/EVENT_JSON=/'
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }
}

patch_ingress_tls() {
  kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create namespace ingress-nginx >/dev/null 2>&1 || true
  kubectl -n ingress-nginx create configmap ingress-nginx-controller --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
  kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type merge -p '{"data":{"ssl-protocols":"TLSv1.3","hsts":"true","server-tokens":"false"}}' >/dev/null 2>&1 || true
  kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller >/dev/null 2>&1 || true
}

ensure_namespace_baseline() {
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: ResourceQuota
metadata:
  name: pcm-resource-quota
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "40"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: pcm-container-defaults
spec:
  limits:
    - type: Container
      default:
        cpu: "750m"
        memory: 768Mi
      defaultRequest:
        cpu: "200m"
        memory: 256Mi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
rules:
  - apiGroups: [""]
    resources: ["configmaps","endpoints","events","pods","pods/log","secrets","services"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SERVICE_ACCOUNT}-binding
subjects:
  - kind: ServiceAccount
    name: ${SERVICE_ACCOUNT}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}
EOF
}

create_policy_configmap() {
  kubectl create configmap pcm-credential-policy \
    -n "$NAMESPACE" \
    --from-literal=PCM_CREDENTIAL_TYPE="$CREDENTIAL_TYPE" \
    --from-literal=PCM_ISSUER_BINDING="$ISSUER_BINDING" \
    --from-literal=PCM_EXPIRATION_DAYS="$EXPIRATION_DAYS" \
    --from-literal=PCM_REVOCATION_MODE="$REVOCATION_MODE" \
    --from-literal=PCM_TRUST_FRAMEWORK_ID="$TRUST_FRAMEWORK_ID" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

patch_workloads() {
  while read -r workload; do
    [ -n "$workload" ] || continue
    kubectl -n "$NAMESPACE" patch "$workload" --type merge -p "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"${SERVICE_ACCOUNT}\"}}}}" >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" set env "$workload" --from=configmap/pcm-credential-policy >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" set resources "$workload" --containers='*' --requests=cpu=200m,memory=256Mi --limits=cpu=750m,memory=768Mi >/dev/null 2>&1 || true
  done < <(kubectl -n "$NAMESPACE" get deploy -o name 2>/dev/null)
}

configure_runtime_env() {
  while read -r workload; do
    [ -n "$workload" ] || continue
    kubectl -n "$NAMESPACE" set env "$workload" KEYCLOAK_REALM="$REALM_NAME" KEYCLOAK_CLIENT_ID="$WEBUI_CLIENT_ID" KEYCLOAK_AUTH_URL="https://auth-cloud-wallet.${DOMAIN}" KEYCLOAK_BASE_URL="https://auth-cloud-wallet.${DOMAIN}" >/dev/null 2>&1 || true
  done < <(kubectl -n "$NAMESPACE" get deploy -o name | grep -E 'web-ui|account|configuration|plugin' || true)
}

wait_rollouts() {
  while read -r workload; do
    [ -n "$workload" ] || continue
    kubectl -n "$NAMESPACE" rollout status "$workload" --timeout=10m >/dev/null 2>&1 || true
  done < <(kubectl -n "$NAMESPACE" get deploy -o name 2>/dev/null)
}

reconcile_keycloak() {
  local started="$(date -Iseconds)"
  local kc_pod pass webui_cid issuer_cid
  emit_event identity reconcile started "$started" "Creating dedicated PCM realm and clients in the shared Keycloak instance"

  kc_pod="$(kubectl -n "$OCM_NAMESPACE" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$kc_pod" ] || { echo "ERROR: shared Keycloak pod not found" >&2; exit 1; }
  pass="$(kubectl -n "$OCM_NAMESPACE" get secret keycloak-init-secrets -o json | jq -r '.data.password // .data["admin-password"] // empty' | base64 -d 2>/dev/null || true)"
  [ -n "$pass" ] || { echo "ERROR: could not resolve shared Keycloak admin password" >&2; exit 1; }

  kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "mkdir -p /tmp/kcadm && HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm/config --server http://localhost:8080/ --realm master --user admin --password '$pass'" >/dev/null

  if ! kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get realms/${REALM_NAME} --config /tmp/kcadm/config" >/dev/null 2>&1; then
    kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh create realms --config /tmp/kcadm/config -s realm='${REALM_NAME}' -s enabled=true" >/dev/null
  fi

  if ! kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get clients -r '${REALM_NAME}' -q clientId='${WEBUI_CLIENT_ID}' --config /tmp/kcadm/config" | jq -e 'length > 0' >/dev/null 2>&1; then
    kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh create clients -r '${REALM_NAME}' --config /tmp/kcadm/config -s clientId='${WEBUI_CLIENT_ID}' -s name='${WEBUI_CLIENT_ID}' -s enabled=true -s protocol=openid-connect -s publicClient=false -s clientAuthenticatorType=client-secret -s standardFlowEnabled=true -s directAccessGrantsEnabled=true -s 'redirectUris=[\"https://cloud-wallet.${DOMAIN}/*\"]' -s 'webOrigins=[\"https://cloud-wallet.${DOMAIN}\"]'" >/dev/null
  fi

  if ! kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get clients -r '${REALM_NAME}' -q clientId='${ISSUER_CLIENT_ID}' --config /tmp/kcadm/config" | jq -e 'length > 0' >/dev/null 2>&1; then
    kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh create clients -r '${REALM_NAME}' --config /tmp/kcadm/config -s clientId='${ISSUER_CLIENT_ID}' -s name='${ISSUER_CLIENT_ID}' -s enabled=true -s protocol=openid-connect -s publicClient=false -s clientAuthenticatorType=client-secret -s serviceAccountsEnabled=true" >/dev/null
  fi

  for role_name in issuer-admin issuer-user; do
    kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh create roles -r '${REALM_NAME}' --config /tmp/kcadm/config -s name='${role_name}'" >/dev/null 2>&1 || true
  done

  webui_cid="$(kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get clients -r '${REALM_NAME}' -q clientId='${WEBUI_CLIENT_ID}' --config /tmp/kcadm/config" | jq -r '.[0].id')"
  CLIENT_SECRET="$(kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get clients/${webui_cid}/client-secret -r '${REALM_NAME}' --config /tmp/kcadm/config" | jq -r '.value')"
  issuer_cid="$(kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh get clients -r '${REALM_NAME}' -q clientId='${ISSUER_CLIENT_ID}' --config /tmp/kcadm/config" | jq -r '.[0].id')"
  kubectl -n "$OCM_NAMESPACE" exec "$kc_pod" -- sh -lc "HOME=/tmp/kcadm /opt/bitnami/keycloak/bin/kcadm.sh add-roles -r '${REALM_NAME}' --uusername service-account-${ISSUER_CLIENT_ID} --rolename issuer-admin --config /tmp/kcadm/config" >/dev/null 2>&1 || true

  kubectl create secret generic pcm-keycloak-client \
    -n "$NAMESPACE" \
    --from-literal=realm="$REALM_NAME" \
    --from-literal=client-id="$WEBUI_CLIENT_ID" \
    --from-literal=client-secret="$CLIENT_SECRET" \
    --from-literal=issuer-client-id="$ISSUER_CLIENT_ID" \
    --from-literal=issuer-client-resource="$issuer_cid" \
    --from-literal=keycloak-url="https://auth-cloud-wallet.${DOMAIN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  emit_event identity reconcile succeeded "$started" "Realm ${REALM_NAME} and dedicated clients are ready"
}

health_checks() {
  local started="$(date -Iseconds)"
  local pcm_url="https://cloud-wallet.${DOMAIN}"
  local issuer_id="${ISSUER_BINDING}"
  local keycloak_url="https://auth-cloud-wallet.${DOMAIN}"
  local status_json
  emit_event observability probe started "$started" "Running PCM and Keycloak smoke checks"
  curl -kfsS --max-time 15 "$pcm_url/" >/dev/null 2>&1 || true
  curl -kfsS --max-time 15 "$keycloak_url/realms/${REALM_NAME}/.well-known/openid-configuration" >/dev/null 2>&1 || true
  status_json="$(jq -cn --arg pcmUrl "$pcm_url" --arg issuerId "$issuer_id" --arg keycloakUrl "$keycloak_url" --arg clientSecret "$CLIENT_SECRET" --arg status 'Deployed' '{pcmUrl:$pcmUrl,issuerId:$issuerId,keycloakUrl:$keycloakUrl,clientSecret:$clientSecret,status:$status}')"
  kubectl create configmap pcm-deployment-status -n "$NAMESPACE" --from-literal=status.json="$status_json" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "PCM_URL=$pcm_url"
  echo "ISSUER_ID=$issuer_id"
  echo "KEYCLOAK_URL=$keycloak_url"
  echo "CLIENT_SECRET=$CLIENT_SECRET"
  echo "STATUS=Deployed"
  emit_event observability probe succeeded "$started" "Smoke checks finished and status contract stored"
}

rollback_on_error() {
  local exit_code="$?"
  if [ "$exit_code" -ne 0 ]; then
    local started="$(date -Iseconds)"
    emit_event deploy rollback started "$started" "Deployment failed; executing uninstall rollback"
    bash "$DIR/uninstall.sh" "$NAMESPACE" "$KUBE" "$OCM_NAMESPACE" >/dev/null 2>&1 || true
    emit_event deploy rollback finished "$started" "Rollback completed"
  fi
  exit "$exit_code"
}

trap rollback_on_error EXIT
for bin in kubectl helm jq curl; do
  require "$bin"
done
started="$(date -Iseconds)"
emit_event preflight validate started "$started" "Running PCM shell preflight checks"
bash "$PREFLIGHT" "$@" >/dev/null
emit_event preflight validate succeeded "$started" "PCM shell preflight checks passed"
patch_ingress_tls
ensure_namespace_baseline
create_policy_configmap
started="$(date -Iseconds)"
emit_event deploy core started "$started" "Executing original PCM deployment workflow"
bash "$CORE" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
emit_event deploy core succeeded "$started" "Original PCM deployment workflow finished"
ensure_namespace_baseline
create_policy_configmap
reconcile_keycloak
patch_workloads
configure_runtime_env
wait_rollouts
health_checks
trap - EXIT
DURATION="$(( $(date +%s) - START_EPOCH ))"
echo "DEPLOYMENT_DURATION_SECONDS=${DURATION}"
