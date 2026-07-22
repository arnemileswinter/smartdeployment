#! /bin/bash
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ./deploy.sh pcmnamespace(instacne_name), ocmnamespace, domain, cert_path, key_path, KUBECONFIG
#               registry_repo, registry_username, registry_password

NAMESPACE="$1"
OCMNAMESPACE="$2"
DOMAIN="$3"
CERT_PATH="$4"
KEY_PATH="$5"   
KUBE="$6"
TLS_SECRET="xfsc-wildcard"
REGISTRY_REPO="$7"  # docker.io/manifaridi/custom-webui
REGISTRY_USERNAME="$8"
REGISTRY_PASSWORD="$9"

helm repo add kong https://charts.konghq.com
helm repo update

export KUBECONFIG="$KUBE"
kubectl create ns $NAMESPACE 2>/dev/null || true
kubectl create secret tls "${TLS_SECRET}" \
    --cert="${CERT_PATH}" \
    --key="${KEY_PATH}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

reown_from_chart() {
  local chart_dir="$1" rel="$2" ns="$3"

  echo ">>> Reowning resources for release=$rel namespace=$ns chart_dir=$chart_dir"

  # Always try to build deps first
  helm dependency build "$chart_dir" >/dev/null 2>&1 || true

  # Reown resources rendered by the chart (namespaced + cluster-scoped)
  helm template "$rel" "$chart_dir" -n "$ns" \
  | yq -o=json eval-all '.' - 2>/dev/null \
  | jq -r '
      select(.kind != null and .metadata != null and .metadata.name != null)
      | [.kind, (.metadata.namespace // ""), .metadata.name]
      | @tsv
    ' \
  | while IFS=$'\t' read -r kind rns name; do
      [[ -z "$kind" || -z "$name" ]] && continue

      if [[ -z "$rns" ]]; then
        if kubectl get "$kind" "$name" >/dev/null 2>&1; then
          echo "Reowning $kind/$name (cluster-scoped)"
          kubectl annotate "$kind" "$name" \
            meta.helm.sh/release-name="$rel" \
            meta.helm.sh/release-namespace="$ns" \
            --overwrite >/dev/null 2>&1 || true
          kubectl label "$kind" "$name" \
            app.kubernetes.io/managed-by=Helm \
            --overwrite >/dev/null 2>&1 || true
        fi
      else
        if kubectl -n "$rns" get "$kind" "$name" >/dev/null 2>&1; then
          echo "Reowning $kind/$rns/$name"
          kubectl -n "$rns" annotate "$kind" "$name" \
            meta.helm.sh/release-name="$rel" \
            meta.helm.sh/release-namespace="$ns" \
            --overwrite >/dev/null 2>&1 || true
          kubectl -n "$rns" label "$kind" "$name" \
            app.kubernetes.io/managed-by=Helm \
            --overwrite >/dev/null 2>&1 || true
        fi
      fi
    done

  # Extra sweep: cluster-scoped kinds that often block helm upgrade --installs
  for kind in clusterrole clusterrolebinding validatingwebhookconfiguration mutatingwebhookconfiguration apiservice crd ingressclass priorityclass storageclass; do
    kubectl get "$kind" -o name 2>/dev/null \
    | grep -i "$rel" \
    | while read -r r; do
        [[ -z "$r" ]] && continue
        echo "Reowning $kind $r (cluster-scoped sweep)"
        kubectl annotate "$r" \
          meta.helm.sh/release-name="$rel" \
          meta.helm.sh/release-namespace="$ns" \
          --overwrite >/dev/null 2>&1 || true
        kubectl label "$r" \
          app.kubernetes.io/managed-by=Helm \
          --overwrite >/dev/null 2>&1 || true
      done
  done

  # Extra sweep: namespaced RBAC kinds
  for kind in role rolebinding; do
    kubectl -n "$ns" get "$kind" -o name 2>/dev/null \
    | grep -i "$rel" \
    | while read -r r; do
        [[ -z "$r" ]] && continue
        echo "Reowning $kind $ns/$r (namespaced sweep)"
        kubectl -n "$ns" annotate "$r" \
          meta.helm.sh/release-name="$rel" \
          meta.helm.sh/release-namespace="$ns" \
          --overwrite >/dev/null 2>&1 || true
        kubectl -n "$ns" label "$r" \
          app.kubernetes.io/managed-by=Helm \
          --overwrite >/dev/null 2>&1 || true
      done
  done
}



# Examples:
reown_from_chart "./Kong Service"                "kong-service"          "$NAMESPACE" || true
reown_from_chart "./Configuration Service"       "configuration-service" "$NAMESPACE" || true
reown_from_chart "./Plugin Discovery Service"    "plugin-discovery-service" "$NAMESPACE" || true
reown_from_chart "./Account Service"             "account-service"       "$NAMESPACE" || true
reown_from_chart "./Web-UI Service"              "web-ui-service"        "$NAMESPACE" || true

sed -i.bak 's/\<'"DOMAIN"'\>/'"$DOMAIN"'/g' "./Configuration Service/values.yaml"
helm dependency build "./Configuration Service";helm upgrade --install configuration-service "./Configuration Service" -n $NAMESPACE
sed -i.bak 's/\<'"$DOMAIN"'\>/'"DOMAIN"'/g' "./Configuration Service/values.yaml"

kubectl annotate ingressclass kong \
  meta.helm.sh/release-name=kong-service \
  meta.helm.sh/release-namespace=$NAMESPACE --overwrite || true

kubectl label ingressclass kong \
  app.kubernetes.io/managed-by=Helm --overwrite || true


sed -i.bak 's/\<'"DOMAIN"'\>/'"$DOMAIN"'/g' "./Kong Service/values.yaml"
helm dependency build "./Kong Service";helm upgrade --install kong-service "./Kong Service" -n $NAMESPACE
sed -i.bak 's/\<'"$DOMAIN"'\>/'"DOMAIN"'/g' "./Kong Service/values.yaml"

sed -i.bak 's/\<'"PCMNAMESPACE"'\>/'"$NAMESPACE"'/g' "./Plugin Discovery Service/values.yaml"
helm dependency build "./Plugin Discovery Service";helm upgrade --install plugin-discovery-service "./Plugin Discovery Service" -n $NAMESPACE
sed -i.bak 's/\<'"$NAMESPACE"'\>/'"PCMNAMESPACE"'/g' "./Plugin Discovery Service/values.yaml"

export POSTGRES_ADMIN_PASSWORD=$(
  kubectl get secret -n "${OCMNAMESPACE}" postgres-postgresql \
    -o jsonpath="{.data.postgres-password}" | base64 -d)
export POSTGRES_POD=$(
  kubectl get pod -n "${OCMNAMESPACE}" \
    -l app.kubernetes.io/instance=postgres,app.kubernetes.io/component=primary \
    -o jsonpath='{.items[0].metadata.name}')
kubectl create secret generic postgres-postgresql \
  --namespace "${NAMESPACE}" \
  --from-literal=postgresql-username="postgres" \
  --from-literal=postgresql-password="${POSTGRES_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic account-db \
  --namespace "${NAMESPACE}" \
  --from-literal=postgresql-username="postgres" \
  --from-literal=postgresql-password="${POSTGRES_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic vault --namespace "${NAMESPACE}" \
  --from-literal=token="root" \
  --dry-run=client -o yaml | kubectl apply -f -


kubectl exec -i -n "$OCMNAMESPACE" "$POSTGRES_POD" -- \
  env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
  psql -U postgres -c "CREATE DATABASE accounts;" || true
# https://github.com/eclipse-xfsc/cloud-wallet-account-service/blob/main/sql/init.sql
kubectl exec -i -n "$OCMNAMESPACE" "$POSTGRES_POD" -- \
  env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
  psql -U postgres -d accounts -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS accounts CASCADE; CREATE SCHEMA IF NOT EXISTS accounts;
CREATE TABLE IF NOT EXISTS accounts.user_secrets (id SERIAL, user_id text PRIMARY KEY, secret_id text, created_at timestamp, updated_at timestamp, deleted_at timestamp);
CREATE TABLE IF NOT EXISTS accounts.user_configs (id SERIAL PRIMARY KEY, user_id VARCHAR(255) UNIQUE, attributes JSONB NOT NULL DEFAULT '{}'::JSONB, created_at timestamp, updated_at timestamp, deleted_at timestamp);
CREATE TABLE IF NOT EXISTS accounts.history_records (id SERIAL PRIMARY KEY, user_id VARCHAR(255), event_type text, message text, created_at timestamp, updated_at timestamp, deleted_at timestamp);
CREATE TABLE IF NOT EXISTS accounts.backups (id SERIAL PRIMARY KEY, user_id VARCHAR(255),credentials bytea, created_at timestamp, updated_at timestamp, deleted_at timestamp);
CREATE TABLE IF NOT EXISTS accounts.presentation_requests (id SERIAL PRIMARY KEY, user_id VARCHAR(255),request_id text, proof_request_id text, created_at timestamp, updated_at timestamp, deleted_at timestamp, ttl integer);
CREATE TABLE IF NOT EXISTS accounts.user_connections (id SERIAL PRIMARY KEY, user_id text, remote_did text, created_at timestamp, updated_at timestamp, deleted_at timestamp);" || true


sed -i.bak 's/\<'"DOMAIN"'\>/'"$DOMAIN"'/g' "./Account Service/values.yaml"
sed -i.bak 's/\<'"PCMNAMESPACE"'\>/'"$NAMESPACE"'/g' "./Account Service/values.yaml"
sed -i.bak 's/\<'"OCMNAMESPACE"'\>/'"$OCMNAMESPACE"'/g' "./Account Service/values.yaml"
helm dependency build "./Account Service";helm upgrade --install account-service "./Account Service" -n $NAMESPACE
sed -i.bak 's/\<'"$DOMAIN"'\>/'"DOMAIN"'/g' "./Account Service/values.yaml"
sed -i.bak 's/\<'"$NAMESPACE"'\>/'"PCMNAMESPACE"'/g' "./Account Service/values.yaml"
sed -i.bak 's/\<'"$OCMNAMESPACE"'\>/'"OCMNAMESPACE"'/g' "./Account Service/values.yaml"

# get the keycloak secret from the ocm
export KEYCLOAK_ADMIN_PASSWORD=$(
  kubectl get secret -n "${OCMNAMESPACE}" keycloak-init-secrets \
    -o jsonpath="{.data.admin-password}" | base64 -d)

export KEYCLOAK_PASSWORD=$(
  kubectl get secret -n "${OCMNAMESPACE}" keycloak-init-secrets \
    -o jsonpath="{.data.password}" | base64 -d)

export KEYCLOAK_POSTGRES_PASSWORD=$(
  kubectl get secret -n "${OCMNAMESPACE}" keycloak-init-secrets \
    -o jsonpath="{.data.postgres-password}" | base64 -d)

export KEYCLOAK_USERNAME=$(
  kubectl get secret -n "${OCMNAMESPACE}" keycloak-init-secrets \
    -o jsonpath="{.data.username}" | base64 -d)

kubectl create secret generic keycloak-init-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=admin-password="${KEYCLOAK_ADMIN_PASSWORD}" \
  --from-literal=password="${KEYCLOAK_PASSWORD}" \
  --from-literal=postgres-password="${KEYCLOAK_POSTGRES_PASSWORD}" \
  --from-literal=username="${KEYCLOAK_USERNAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---- LOCAL DOCKER BUILD (no registry: k8s uses the docker runtime, so a local image is directly usable) ----
sed -i.bak "s/\<DOMAIN\>/$DOMAIN/g" "./web-ui_image_build/cloud-wallet-web-ui/.env.production"
docker build -f "./web-ui_image_build/cloud-wallet-web-ui/deployment/docker/Dockerfile" \
  -t "$REGISTRY_REPO:custom-webui" "./web-ui_image_build/cloud-wallet-web-ui/"
mv "./web-ui_image_build/cloud-wallet-web-ui/.env.production.bak" "./web-ui_image_build/cloud-wallet-web-ui/.env.production"
kubectl -n "$NAMESPACE" delete secret regcred 2>/dev/null || true
kubectl -n "$NAMESPACE" create secret docker-registry regcred \
  --docker-username="$REGISTRY_USERNAME" \
  --docker-password="$REGISTRY_PASSWORD"
# ---- END LOCAL DOCKER BUILD ----


#htpasswd -c auth admin
printf "admin:$(openssl passwd -apr1 admin)\n" > auth
kubectl create secret generic web-ui-basic-auth \
  --from-file=auth -n $NAMESPACE

sed -i.bak 's/\<'"DOMAIN"'\>/'"$DOMAIN"'/g' "./Web-UI Service/values.yaml"
sed -i "s|REGISTRY_REPO|${REGISTRY_REPO}|g" "./Web-UI Service/values.yaml"
helm dependency build "./Web-UI Service";helm upgrade --install web-ui-service "./Web-UI Service" -n $NAMESPACE --wait --timeout 5m --debug
sed -i.bak 's/\<'"$DOMAIN"'\>/'"DOMAIN"'/g' "./Web-UI Service/values.yaml"
sed -i "s|${REGISTRY_REPO}|REGISTRY_REPO|g" "./Web-UI Service/values.yaml"


KC_POD="$(kubectl -n "$OCMNAMESPACE" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"
PASS="$(kubectl -n "$OCMNAMESPACE" get secret keycloak-init-secrets -o jsonpath='{.data.password}' | base64 -d)"
KCADM_DIR="/tmp/kcadm"
KCADM_CFG="$KCADM_DIR/kcadm.config"
ok=""
for i in {1..60}; do
  if kubectl -n "$OCMNAMESPACE" exec -i "$KC_POD" -- sh -lc "
    mkdir -p '$KCADM_DIR' &&
    HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh config credentials \
      --config '$KCADM_CFG' \
      --server http://localhost:8080/ \
      --realm master \
      --user admin \
      --password '$PASS'
  " >/dev/null 2>&1; then
    ok="y"; break
  fi
  sleep 5
done
[ -n "$ok" ] || { echo 'Keycloak admin not ready'; exit 1; }

kubectl -n "$OCMNAMESPACE" exec -i "$KC_POD" -- sh -lc "
  HOME='$KCADM_DIR' /opt/bitnami/keycloak/bin/kcadm.sh create clients -r master \
    --config '$KCADM_CFG' \
    -s clientId=webui \
    -s name=webui \
    -s protocol=openid-connect \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s frontchannelLogout=true \
    -s rootUrl=https://cloud-wallet.$DOMAIN \
    -s baseUrl=https://cloud-wallet.$DOMAIN \
    -s adminUrl=https://cloud-wallet.$DOMAIN \
    -s 'redirectUris=[\"https://cloud-wallet.'$DOMAIN'/*\",\"http://localhost:3000/*\"]' \
    -s 'webOrigins=[\"https://cloud-wallet.'$DOMAIN'\",\"http://localhost:3000\"]' \
    -s 'attributes.\"pkce.code.challenge.method\"=S256' \
    -s 'attributes.\"access.token.signed.response.alg\"=RS256'
    
"

echo "######################################################"
echo "###################### ALL DONE ######################"
echo "######################################################"
