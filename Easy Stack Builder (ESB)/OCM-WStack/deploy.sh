#! /bin/bash

set -euo pipefail

# ./deploy.sh ocmnamespace domain FULLCHAINCERT keypath email KUBECONFIG

NAMESPACE="$1"
DOMAIN="$2"
CERT_PATH="$3"
KEY_PATH="$4"
EMAIL="$5"
KUBE="$6"
TLS_SECRET="xfsc-wildcard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d /tmp/ocm-w-stack-XXXXXX)"
START_TS="$(date +%s)"
STATUS_CONFIGMAP="ocm-deployment-status"
KEYCLOAK_REALM="$NAMESPACE"
KEYCLOAK_CLIENT_ID="bridge"
ROLLBACK_IN_PROGRESS=0
LAST_PHASE="init"

export KUBECONFIG="$KUBE"

cleanup_workdir() {
  rm -rf "$WORKDIR" 2>/dev/null || true
}

emit_event() {
  local phase="$1"
  local status="$2"
  local detail="${3:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  jq -cn --arg phase "$phase" --arg status "$status" --arg detail "$detail" --arg timestamp "$ts" \
    '{phase:$phase,status:$status,detail:$detail,timestamp:$timestamp}' | sed 's/^/EVENT_JSON=/'
}

emit_warning() {
  local message="$1"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  jq -cn --arg message "$message" --arg timestamp "$ts" '{message:$message,timestamp:$timestamp}' | sed 's/^/WARN_JSON=/'
}

persist_status() {
  local phase="$1"
  local status="$2"
  local detail="${3:-}"

  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi

  kubectl create configmap "$STATUS_CONFIGMAP" \
    -n "$NAMESPACE" \
    --from-literal=phase="$phase" \
    --from-literal=status="$status" \
    --from-literal=detail="$detail" \
    --from-literal=updatedAt="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
}

record_phase() {
  local phase="$1"
  local status="$2"
  local detail="${3:-}"
  LAST_PHASE="$phase"
  emit_event "$phase" "$status" "$detail"
  persist_status "$phase" "$status" "$detail"
}

ensure_namespace() {
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
}

apply_namespace_guardrails() {
  ensure_namespace
  kubectl label namespace "$NAMESPACE" app.kubernetes.io/part-of=ocm-w-stack --overwrite >/dev/null 2>&1 || true

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ocm-runtime
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ocm-observer
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ocm-observer-binding
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ocm-runtime
    namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ocm-observer
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ocm-resource-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    pods: "80"
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    persistentvolumeclaims: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: ocm-default-limits
  namespace: ${NAMESPACE}
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 500m
        memory: 512Mi
YAML
}

ensure_postgres_database() {
  local database_name="$1"
  local exists

  exists="$(kubectl exec -i -n "$NAMESPACE" "$POSTGRES_POD" -- \
    env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${database_name}'" | tr -d '[:space:]' || true)"

  if [[ "$exists" != "1" ]]; then
    kubectl exec -i -n "$NAMESPACE" "$POSTGRES_POD" -- \
      env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
      psql -U postgres -c "CREATE DATABASE ${database_name};"
  fi
}

ensure_vault_key() {
  local path="$1"
  if ! kubectl -n "$NAMESPACE" exec vault-0 -- sh -lc "$VAULT_ENV vault read -format=json ${path} >/dev/null 2>&1"; then
    kubectl -n "$NAMESPACE" exec vault-0 -- sh -lc "$VAULT_ENV vault write -f ${path} type=ecdsa-p256"
  fi
}

collect_external_ip() {
  local external
  external="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -z "$external" ]]; then
    external="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi
  if [[ -z "$external" ]]; then
    external="cloud-wallet.${DOMAIN}"
  fi
  printf '%s' "$external"
}

post_deploy_smoke_checks() {
  kubectl -n "$NAMESPACE" get ingress >/dev/null
  kubectl -n "$NAMESPACE" get ingress -o json \
    | jq -e --arg host "cloud-wallet.${DOMAIN}" 'any(.items[]?; any(.spec.rules[]?; .host == $host))' >/dev/null

  kubectl -n "$NAMESPACE" exec "$KC_POD" -- sh -lc "HOME='${KCADM_DIR}' /opt/bitnami/keycloak/bin/kcadm.sh get realms/${KEYCLOAK_REALM} --config '${KCADM_CFG}' >/dev/null"
  kubectl -n "$NAMESPACE" get secret ocm-keycloak-client >/dev/null
}

handle_error() {
  local exit_code=$?
  local line="$1"

  set +e
  record_phase "$LAST_PHASE" "failed" "Deployment failed at line ${line}; starting rollback"

  emit_event "rollback" "skipped" "Rollback disabled for local iterative deployment; namespace ${NAMESPACE} left as-is"

  exit "$exit_code"
}

trap cleanup_workdir EXIT
trap 'handle_error $LINENO' ERR

cp -R "$SCRIPT_DIR"/. "$WORKDIR"/
cd "$WORKDIR"

for cmd in kubectl helm jq openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

record_phase "preflight" "running" "Validating kubeconfig, domain, namespace, and TLS material"
bash "$SCRIPT_DIR/preflight.sh" "$NAMESPACE" "$DOMAIN" "$CERT_PATH" "$KEY_PATH" "$EMAIL" "$KUBE"
record_phase "preflight" "done" "Input validation completed"

record_phase "helm-bootstrap" "running" "Preparing Helm repositories and ingress controller"
helm repo add jetstack https://charts.jetstack.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Ingress NGINX install/patch (robust + idempotent)

# 1) Ensure namespace exists
kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create namespace ingress-nginx

# 2) Best-effort cleanup of leftover admission webhook jobs
kubectl -n ingress-nginx delete job -l app.kubernetes.io/component=admission-webhook --ignore-not-found

# 3) Apply a pinned ingress-nginx release (avoid 'main' drift)
NGINX_ING_VER="controller-v1.11.1"
ING_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${NGINX_ING_VER}/deploy/static/provider/cloud/deploy.yaml"
curl -fsSL "$ING_URL" | kubectl apply -f -

# 4) Wait for the Deployment (safer than waiting on pods by selector)
#    Handle initial creation race where the resource may not exist yet.
for i in {1..30}; do
  kubectl -n ingress-nginx get deploy/ingress-nginx-controller >/dev/null 2>&1 && break
  sleep 2
done
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5m

# 5) Best-effort: remove validating webhook if it hinders bootstrap
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found

# 6) Make idempotent config changes and restart once
#    Ensure the ConfigMap exists even if chart/manifests did not create it with data.
kubectl -n ingress-nginx create configmap ingress-nginx-controller --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ingress-nginx patch configmap ingress-nginx-controller \
  --type merge \
  -p '{"data":{"allow-snippet-annotations":"true","annotations-risk-level":"Critical","ssl-protocols":"TLSv1.3"}}' || true

kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5m || true
record_phase "helm-bootstrap" "done" "Ingress controller and Helm repositories are ready"

record_phase "namespace" "running" "Creating namespace, TLS secret, and guardrails"
ensure_namespace
apply_namespace_guardrails
kubectl create secret tls "$TLS_SECRET" \
  --cert="$CERT_PATH" \
  --key="$KEY_PATH" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic signing \
  --from-file=signing-key="$KEY_PATH" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
record_phase "namespace" "done" "Namespace guardrails and TLS materials applied"

record_phase "nats" "running" "Deploying NATS"
helm dependency build "./Nats Chart"
helm upgrade --install nats "./Nats Chart" --namespace "$NAMESPACE"
record_phase "nats" "done" "NATS deployed"

record_phase "cert-manager" "running" "Deploying cert-manager and cluster issuer"
# Apply CRDs once (idempotent)
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.11.0/cert-manager.crds.yaml
kubectl get clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration,apiservice,crd -o name \
  | grep -E '(^|/)(cert-?manager|cm-)' \
  | while read -r resource; do
      kubectl annotate "$resource" \
        meta.helm.sh/release-name=cert-manager \
        meta.helm.sh/release-namespace="$NAMESPACE" \
        --overwrite || true
      kubectl label "$resource" app.kubernetes.io/managed-by=Helm \
        --overwrite || true
    done || true

# Re-own kube-system leader-election RBAC (namespaced) so Helm can adopt them
for kind in role rolebinding; do
  kubectl -n kube-system get "$kind" -o name \
    | grep -E '(^|/)(cert-?manager|cm-).*(leaderelection|dynamic-serving)' \
    | while read -r resource; do
        kubectl -n kube-system annotate "$resource" \
          meta.helm.sh/release-name=cert-manager \
          meta.helm.sh/release-namespace="$NAMESPACE" \
          --overwrite || true
        kubectl -n kube-system label "$resource" app.kubernetes.io/managed-by=Helm \
          --overwrite || true
      done || true
done
# Install/upgrade cert-manager WITHOUT CRDs (already applied above)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$NAMESPACE" \
  --version v1.11.0 \
  --set installCRDs=false

### Cluster Issuer
kubectl annotate clusterissuer letsencrypt-prod \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  meta.helm.sh/release-name=cluster-issuer --overwrite || true
helm dependency build "./Cluster-Issuer"
helm upgrade --install cluster-issuer "./Cluster-Issuer" --set email="$EMAIL" --namespace "$NAMESPACE"
record_phase "cert-manager" "done" "cert-manager and cluster issuer deployed"

record_phase "cassandra" "running" "Deploying Cassandra"
helm upgrade --install cassandra \
  oci://registry-1.docker.io/bitnamicharts/cassandra \
  --namespace "$NAMESPACE" --wait \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/cassandra \
  --set image.tag=5.0.5-debian-12-r7 \
  --set global.security.allowInsecureImages=true

CASSANDRA_PASSWORD="$(kubectl -n "$NAMESPACE" get secret cassandra -o jsonpath='{.data.cassandra-password}' | base64 -d)"
kubectl -n "$NAMESPACE" wait --for=condition=ready pod cassandra-0 --timeout=10m
ok=""
for i in {1..60}; do
  if kubectl -n "$NAMESPACE" exec cassandra-0 -c cassandra -- \
    bash -lc "/opt/bitnami/cassandra/bin/cqlsh 127.0.0.1 9042 -u cassandra -p '$CASSANDRA_PASSWORD' -e 'SHOW VERSION'" >/dev/null 2>&1; then
    ok="y"
    break
  fi
  sleep 5
done
[ -n "$ok" ] || { echo "Cassandra auth not ready"; exit 1; }
kubectl -n "$NAMESPACE" exec -i cassandra-0 -c cassandra -- \
  bash -lc "/opt/bitnami/cassandra/bin/cqlsh 127.0.0.1 9042 -u cassandra -p '$CASSANDRA_PASSWORD'" <<'CQL'
CREATE KEYSPACE IF NOT EXISTS tenant_space
  WITH REPLICATION = { 'class' : 'SimpleStrategy', 'replication_factor' : 1 };

CREATE TABLE IF NOT EXISTS tenant_space.offerings (
  partition text,
  region text,
  country text,
  groupId text,
  requestId text,
  last_update_timestamp timestamp,
  type text,
  metadata text,
  offerParams text,
  status text,
  PRIMARY KEY ((partition, region, country), groupId, requestId)
) WITH default_time_to_live = 17800;

CREATE TABLE IF NOT EXISTS tenant_space.credentials (
  accountPartition text,
  region text,
  country text,
  account text,
  last_update_timestamp timestamp,
  metadata map<text,text>,
  credentials map<text,text>,
  presentations map<text,text>,
  id text,
  recovery_nonce text,
  device_key text,
  nonce text,
  locked boolean,
  signature text,
  PRIMARY KEY ((accountPartition, region, country), account)
);

CREATE INDEX IF NOT EXISTS credentials_locked_idx ON tenant_space.credentials (locked);
CREATE INDEX IF NOT EXISTS credentials_id_idx ON tenant_space.credentials (id);
CQL
record_phase "cassandra" "done" "Cassandra initialized"

record_phase "redis" "running" "Deploying Redis"
REDIS_PASSWORD="$(openssl rand -hex 16)"
kubectl create secret generic preauthbridge-redis \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --from-literal=redis-user="default" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install redis \
  oci://registry-1.docker.io/bitnamicharts/redis \
  --namespace "$NAMESPACE" -f ./Redis/values.yaml \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/redis \
  --set global.security.allowInsecureImages=true
record_phase "redis" "done" "Redis deployed"

record_phase "postgres" "running" "Deploying PostgreSQL"
helm upgrade --install postgres \
  oci://registry-1.docker.io/bitnamicharts/postgresql \
  --namespace "$NAMESPACE" --wait \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/postgresql \
  --set global.security.allowInsecureImages=true

POSTGRES_ADMIN_PASSWORD="$({
  kubectl get secret -n "$NAMESPACE" postgres-postgresql \
    -o jsonpath='{.data.postgres-password}' | base64 -d
})"
POSTGRES_POD="$({
  kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance=postgres,app.kubernetes.io/component=primary \
    -o jsonpath='{.items[0].metadata.name}'
})"
record_phase "postgres" "done" "PostgreSQL deployed"

record_phase "policy" "running" "Deploying policy service"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Policy Chart/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Policy Chart/values.yaml"
helm dependency build "./Policy Chart"
helm upgrade --install policy-service "./Policy Chart" --namespace "$NAMESPACE"
mv ./Policy\ Chart/values.yaml.bak ./Policy\ Chart/values.yaml
record_phase "policy" "done" "Policy service deployed"

record_phase "keycloak" "running" "Deploying Keycloak and provisioning realm/client"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' ./Keycloak/values.yaml
helm dependency build "./Keycloak"
helm upgrade --install keycloak "./Keycloak" \
  --namespace "$NAMESPACE" \
  -f "./Keycloak/values.yaml" \
  --set keycloak.auth.adminUser=admin \
  --set keycloak.image.registry=docker.io \
  --set keycloak.image.repository=bitnamilegacy/keycloak \
  --set global.security.allowInsecureImages=true \
  --set keycloak.resources.requests.cpu=500m \
  --set keycloak.resources.requests.memory=768Mi \
  --set keycloak.resources.limits.cpu=1500m \
  --set keycloak.resources.limits.memory=1536Mi \
  --wait
mv ./Keycloak/values.yaml.bak ./Keycloak/values.yaml

KC_POD="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"
PASS="$(kubectl -n "$NAMESPACE" get secret keycloak-init-secrets -o jsonpath='{.data.password}' | base64 -d)"
KCADM_DIR="/tmp/kcadm"
KCADM_CFG="$KCADM_DIR/kcadm.config"
ok=""
for i in {1..60}; do
  if kubectl -n "$NAMESPACE" exec -i "$KC_POD" -- sh -lc "
    mkdir -p '$KCADM_DIR' &&
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh config credentials \
      --config '$KCADM_CFG' \
      --server http://localhost:8080/ \
      --realm master \
      --user admin \
      --password '$PASS'
  " >/dev/null 2>&1; then
    ok="y"
    break
  fi
  sleep 5
done
[ -n "$ok" ] || { echo 'Keycloak admin not ready'; exit 1; }

if ! kubectl -n "$NAMESPACE" exec -i "$KC_POD" -- sh -lc "HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh get realms/${KEYCLOAK_REALM} --config '$KCADM_CFG' >/dev/null 2>&1"; then
  kubectl -n "$NAMESPACE" exec -i "$KC_POD" -- sh -lc "
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh create realms \
      --config '$KCADM_CFG' \
      -s realm='${KEYCLOAK_REALM}' \
      -s enabled=true
  " >/dev/null
else
  kubectl -n "$NAMESPACE" exec -i "$KC_POD" -- sh -lc "
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM} \
      --config '$KCADM_CFG' \
      -s enabled=true
  " >/dev/null
fi

CID="$({
  kubectl -n "$NAMESPACE" exec "$KC_POD" -- sh -lc "
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh get clients -r ${KEYCLOAK_REALM} -q clientId=${KEYCLOAK_CLIENT_ID} --config '$KCADM_CFG'
  " | jq -r '.[0].id // empty'
})"
if [[ -z "$CID" ]]; then
  kubectl -n "$NAMESPACE" exec -i "$KC_POD" -- sh -lc "
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh create clients -r ${KEYCLOAK_REALM} \
      --config '$KCADM_CFG' \
      -s clientId='${KEYCLOAK_CLIENT_ID}' \
      -s enabled=true \
      -s protocol='openid-connect' \
      -s publicClient=false \
      -s clientAuthenticatorType='client-secret' \
      -s serviceAccountsEnabled=true
  " >/dev/null
  CID="$({
    kubectl -n "$NAMESPACE" exec "$KC_POD" -- sh -lc "
      HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh get clients -r ${KEYCLOAK_REALM} -q clientId=${KEYCLOAK_CLIENT_ID} --config '$KCADM_CFG'
    " | jq -r '.[0].id // empty'
  })"
fi
kubectl -n "$NAMESPACE" exec -i "$KC_POD" -- sh -lc "
  HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh update clients/${CID} -r ${KEYCLOAK_REALM} \
    --config '$KCADM_CFG' \
    -s enabled=true \
    -s protocol='openid-connect' \
    -s publicClient=false \
    -s clientAuthenticatorType='client-secret' \
    -s serviceAccountsEnabled=true
" >/dev/null
SECRET="$({
  kubectl -n "$NAMESPACE" exec "$KC_POD" -- sh -lc "
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh get clients/${CID}/client-secret -r ${KEYCLOAK_REALM} --config '$KCADM_CFG'
  " | jq -r '.value'
})"
BRIDGE_CLIENT_SECRET="$SECRET"

kubectl create secret generic ocm-keycloak-client \
  -n "$NAMESPACE" \
  --from-literal=realm="$KEYCLOAK_REALM" \
  --from-literal=clientId="$KEYCLOAK_CLIENT_ID" \
  --from-literal=clientSecret="$BRIDGE_CLIENT_SECRET" \
  --from-literal=keycloakUrl="https://auth-cloud-wallet.${DOMAIN}" \
  --dry-run=client -o yaml | kubectl apply -f -
record_phase "keycloak" "done" "Keycloak realm and client are provisioned"

record_phase "vault" "running" "Deploying Vault and transit keys"
kubectl delete clusterrolebinding vault-agent-injector-binding || true
kubectl delete clusterrolebinding vault-server-binding || true
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg || true
kubectl delete clusterrole vault-agent-injector-clusterrole || true
helm upgrade --install vault hashicorp/vault --namespace "$NAMESPACE" \
  -f "./Vault/values.yaml" --set "server.dev.enabled=true" --wait

kubectl create secret generic vault --namespace "$NAMESPACE" \
  --from-literal=token="root" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" wait --for=condition=ready pod vault-0 --timeout=10m
VAULT_ENV='VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root'
# enable a TRANSIT engine at path 'tenant_space' and also the default 'transit' engine
kubectl -n "$NAMESPACE" exec vault-0 -- sh -lc "$VAULT_ENV vault secrets enable -path=tenant_space transit || true"
kubectl -n "$NAMESPACE" exec vault-0 -- sh -lc "$VAULT_ENV vault secrets enable transit || true"
ensure_vault_key tenant_space/keys/DeveloperCredential
ensure_vault_key tenant_space/keys/SDJWTCredential
ensure_vault_key tenant_space/keys/signerkey
ensure_vault_key transit/keys/DeveloperCredential
ensure_vault_key transit/keys/SDJWTCredential
kubectl -n "$NAMESPACE" exec vault-0 -- sh -lc "
  cat > /tmp/crypto-engine.hcl <<'POLICY'
path \"transit/sign/DeveloperCredential\" { capabilities = [\"update\"] }
path \"transit/verify/DeveloperCredential\" { capabilities = [\"update\"] }
path \"transit/keys/DeveloperCredential\" { capabilities = [\"read\",\"list\"] }
path \"transit/sign/SDJWTCredential\" { capabilities = [\"update\"] }
path \"transit/verify/SDJWTCredential\" { capabilities = [\"update\"] }
path \"transit/keys/SDJWTCredential\" { capabilities = [\"read\",\"list\"] }
POLICY
  $VAULT_ENV vault policy write crypto-engine-policy /tmp/crypto-engine.hcl
"
record_phase "vault" "done" "Vault transit keys are ready"

record_phase "storage" "running" "Deploying storage service"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Storage Service/values.yaml"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Storage Service/values.yaml"
helm dependency build "./Storage Service"
helm upgrade --install storage-service "./Storage Service" --namespace "$NAMESPACE" -f "./Storage Service/values.yaml"
mv ./Storage\ Service/values.yaml.bak ./Storage\ Service/values.yaml
kubectl set env deployment/storage-service STORAGESERVICE_MESSAGING_URL="nats.$NAMESPACE.svc.cluster.local:4222" -n "$NAMESPACE"
record_phase "storage" "done" "Storage service deployed"

record_phase "status-list" "running" "Deploying status list service"
ensure_postgres_database status
kubectl create secret generic statuslist-db-secret \
  --namespace "$NAMESPACE" \
  --from-literal=postgresql-username="postgres" \
  --from-literal=postgresql-password="$POSTGRES_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Status List Service Chart/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Status List Service Chart/values.yaml"
helm dependency build "./Status List Service Chart"
helm upgrade --install status-list-service-chart "./Status List Service Chart" \
  --namespace "$NAMESPACE" \
  --set database.autoMigrate=true \
  --set status-list-service.database.secretName=statuslist-db-secret \
  -f "./Status List Service Chart/values.yaml"
mv ./Status\ List\ Service\ Chart/values.yaml.bak ./Status\ List\ Service\ Chart/values.yaml
kubectl patch ing status-list-service -n "$NAMESPACE" --type='json' -p='[
  {"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"status-list-service-chart-service"},
  {"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":8080}
]'
record_phase "status-list" "done" "Status list service deployed"

record_phase "universal-resolver" "running" "Deploying universal resolver"
helm dependency build "./Universal Resolver"
helm upgrade --install universal-resolver "./Universal Resolver" --namespace "$NAMESPACE"
record_phase "universal-resolver" "done" "Universal resolver deployed"

record_phase "signer" "running" "Deploying signer"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./signer/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./signer/values.yaml"
helm dependency build "./signer"
helm upgrade --install signer "./signer" --namespace "$NAMESPACE" -f "./signer/values.yaml"
mv ./signer/values.yaml.bak ./signer/values.yaml
kubectl set env deployment/signer \
  -n "$NAMESPACE" \
  VAULT_ADDR="https://vault.${NAMESPACE}.svc:8200" \
  TRANSIT_MOUNT_PATH=transit \
  TRANSIT_KEY_NAME=SDJWTCredential
record_phase "signer" "done" "Signer deployed"

record_phase "sdjwt" "running" "Deploying SD-JWT service"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./SdJwt Service/values.yaml"
helm dependency build "./SdJwt Service"
helm upgrade --install sdjwt "./SdJwt Service" --namespace "$NAMESPACE" -f "./SdJwt Service/values.yaml"
mv ./SdJwt\ Service/values.yaml.bak ./SdJwt\ Service/values.yaml
record_phase "sdjwt" "done" "SD-JWT service deployed"

record_phase "dummy-content-signer" "running" "Deploying dummy content signer"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Dummy Content Signer/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Dummy Content Signer/values.yaml"
helm dependency build "./Dummy Content Signer"
helm upgrade --install dummy-content-signer "./Dummy Content Signer" \
  --namespace "$NAMESPACE" -f "./Dummy Content Signer/values.yaml"
mv ./Dummy\ Content\ Signer/values.yaml.bak ./Dummy\ Content\ Signer/values.yaml
record_phase "dummy-content-signer" "done" "Dummy content signer deployed"

record_phase "preauthbridge" "running" "Deploying pre-authorization bridge"
kubectl create secret generic preauthbridge-oauth \
  -n "$NAMESPACE" \
  --from-literal=secret="$BRIDGE_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Pre Authorization Bridge Chart/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Pre Authorization Bridge Chart/values.yaml"
helm dependency build "./Pre Authorization Bridge Chart"
helm upgrade --install preauthbridge "./Pre Authorization Bridge Chart" \
  --namespace "$NAMESPACE" \
  --set keycloak.email="$EMAIL" \
  --set pre-authorization-bridge.config.database.password="$REDIS_PASSWORD" \
  -f "./Pre Authorization Bridge Chart/values.yaml"
mv ./Pre\ Authorization\ Bridge\ Chart/values.yaml.bak ./Pre\ Authorization\ Bridge\ Chart/values.yaml
record_phase "preauthbridge" "done" "Pre-authorization bridge deployed"

record_phase "credential-issuance" "running" "Deploying credential issuance service"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Credential Issuance/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Credential Issuance/values.yaml"
helm dependency build "./Credential Issuance"
helm upgrade --install credential-issuance-service "./Credential Issuance" \
  --namespace "$NAMESPACE" --values "./Credential Issuance/values.yaml"
mv ./Credential\ Issuance/values.yaml.bak ./Credential\ Issuance/values.yaml
record_phase "credential-issuance" "done" "Credential issuance service deployed"

record_phase "credential-retrieval" "running" "Deploying credential retrieval service"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Credential Retrieval/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Credential Retrieval/values.yaml"
helm dependency build "./Credential Retrieval"
helm upgrade --install credential-retrieval-service "./Credential Retrieval" \
  --values "./Credential Retrieval/values.yaml" --namespace "$NAMESPACE"
mv ./Credential\ Retrieval/values.yaml.bak ./Credential\ Retrieval/values.yaml
record_phase "credential-retrieval" "done" "Credential retrieval service deployed"

record_phase "credential-verification" "running" "Deploying credential verification service"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Credential Verification Service Chart/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Credential Verification Service Chart/values.yaml"
helm dependency build "./Credential Verification Service Chart"
helm upgrade --install credential-verification-service "./Credential Verification Service Chart" \
  --values "./Credential Verification Service Chart/values.yaml" --namespace "$NAMESPACE"
mv ./Credential\ Verification\ Service\ Chart/values.yaml.bak ./Credential\ Verification\ Service\ Chart/values.yaml
container_name="$(kubectl -n "$NAMESPACE" get deploy credential-verification-service -o jsonpath='{.spec.template.spec.containers[0].name}')"

patch_json="$(jq -n \
  --arg name "$container_name" \
  --arg nats "nats.${NAMESPACE}.svc.cluster.local:4222" \
  '{
    spec: {
      template: {
        spec: {
          containers: [
            {
              name: $name,
              env: [
                {
                  name: "CREDENTIALVERIFICATION_MESSAGING_NATS_URL",
                  value: $nats
                }
              ]
            }
          ]
        }
      }
    }
  }'
)"

kubectl -n "$NAMESPACE" patch deploy/credential-verification-service --type=strategic -p "$patch_json"
record_phase "credential-verification" "done" "Credential verification service deployed"

record_phase "well-known" "running" "Deploying well-known services and ingress rules"
ensure_postgres_database wellknown
kubectl create secret generic wellknown-db-secret \
  --namespace "$NAMESPACE" \
  --from-literal=postgresql-username="postgres" \
  --from-literal=postgresql-password="$POSTGRES_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Well Known Chart/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Well Known Chart/values.yaml"
helm dependency build "./Well Known Chart"
helm upgrade --install well-known-service "./Well Known Chart" \
  --namespace "$NAMESPACE" -f "./Well Known Chart/values.yaml" --force
mv ./Well\ Known\ Chart/values.yaml.bak ./Well\ Known\ Chart/values.yaml

sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Well Known Ingress Rules/values.yaml"
helm dependency build "./Well Known Ingress Rules"
helm upgrade --install well-known-ingress-rules "./Well Known Ingress Rules" --namespace "$NAMESPACE"
mv ./Well\ Known\ Ingress\ Rules/values.yaml.bak ./Well\ Known\ Ingress\ Rules/values.yaml
record_phase "well-known" "done" "Well-known services deployed"

record_phase "didcomm" "running" "Deploying DIDComm connector"
sed -i.bak 's/\<DOMAIN\>/'"$DOMAIN"'/g' "./Didcomm/values.yaml"
sed -i.bak 's/\<NAMESPACE\>/'"$NAMESPACE"'/g' "./Didcomm/values.yaml"
helm dependency build "./Didcomm"
helm upgrade --install didcomm "./Didcomm" --namespace "$NAMESPACE" -f "./Didcomm/values.yaml"
mv ./Didcomm/values.yaml.bak ./Didcomm/values.yaml
record_phase "didcomm" "done" "DIDComm connector deployed"

record_phase "smoke-tests" "running" "Verifying ingress, Keycloak connectivity, and stored secrets"
post_deploy_smoke_checks
record_phase "smoke-tests" "done" "Smoke checks completed"

OCM_URL="https://cloud-wallet.${DOMAIN}"
KEYCLOAK_URL="https://auth-cloud-wallet.${DOMAIN}"
EXTERNAL_IP="$(collect_external_ip)"
CLIENT_SECRET="$(kubectl -n "$NAMESPACE" get secret ocm-keycloak-client -o jsonpath='{.data.clientSecret}' | base64 -d)"
DURATION_SECONDS="$(( $(date +%s) - START_TS ))"

if (( DURATION_SECONDS > 600 )); then
  emit_warning "Deployment completed in ${DURATION_SECONDS}s, which exceeds the 10 minute target."
fi
record_phase "complete" "done" "Deployment completed in ${DURATION_SECONDS}s"

jq -cn \
  --arg ocmUrl "$OCM_URL" \
  --arg keycloakUrl "$KEYCLOAK_URL" \
  --arg clientSecret "$CLIENT_SECRET" \
  --arg externalIp "$EXTERNAL_IP" \
  --arg status "Implemented" \
  '{ocmUrl:$ocmUrl,keycloakUrl:$keycloakUrl,clientSecret:$clientSecret,externalIp:$externalIp,status:$status}' | sed 's/^/OUTPUT_JSON=/'
