#!/usr/bin/env bash
set -Eeuo pipefail

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

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

is_reserved_namespace() {
  case "$1" in
    default|kube-system|kube-public|kube-node-lease|ingress-nginx|cert-manager|kube-service-catalog)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

[[ -f "$CERT_PATH" ]] || fail "certificate file not found: $CERT_PATH"
[[ -f "$KEY_PATH" ]] || fail "key file not found: $KEY_PATH"
[[ -f "$KUBE" ]] || fail "kubeconfig file not found: $KUBE"

for bin in kubectl openssl docker grep awk sed; do
  require "$bin"
done

[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "PCM instance name must be a valid Kubernetes namespace"
[[ "$OCM_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "OCM namespace must be a valid Kubernetes namespace"
is_reserved_namespace "$NAMESPACE" && fail "PCM instance name uses a reserved namespace"
[[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || fail "domain must be a bare FQDN"
[[ "$DOMAIN" != http://* && "$DOMAIN" != https://* && "$DOMAIN" != */* ]] || fail "domain must not include a scheme or path"
[[ "$REGISTRY_REPO" == */* ]] || fail "registry repository should include a registry path"
[[ "$EXPIRATION_DAYS" =~ ^[0-9]+$ ]] || fail "expiration days must be a positive integer"
[ "$EXPIRATION_DAYS" -gt 0 ] || fail "expiration days must be greater than zero"
[ -n "$CREDENTIAL_TYPE" ] || fail "credential type is required"
[ -n "$ISSUER_BINDING" ] || fail "issuer binding is required"
[ -n "$REVOCATION_MODE" ] || fail "revocation mode is required"
[ -n "$TRUST_FRAMEWORK_ID" ] || fail "trust framework identifier is required"

grep -q 'BEGIN CERTIFICATE' "$CERT_PATH" || fail "certificate file does not look like PEM data"
grep -Eq 'BEGIN (RSA |EC |)?PRIVATE KEY' "$KEY_PATH" || fail "private key file does not look like PEM data"
openssl x509 -in "$CERT_PATH" -noout >/dev/null 2>&1 || fail "certificate cannot be parsed by openssl"
openssl pkey -in "$KEY_PATH" -noout >/dev/null 2>&1 || fail "private key cannot be parsed by openssl"
cert_pub="$(openssl x509 -in "$CERT_PATH" -pubkey -noout | openssl pkey -pubin -outform PEM 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"
key_pub="$(openssl pkey -in "$KEY_PATH" -pubout -outform PEM 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"
[[ -n "$cert_pub" && "$cert_pub" = "$key_pub" ]] || fail "certificate and private key do not match"

kubectl --kubeconfig "$KUBE" config view --raw >/dev/null 2>&1 || fail "kubeconfig could not be parsed"
kubectl --kubeconfig "$KUBE" cluster-info >/dev/null 2>&1 || fail "cluster is not reachable"
kubectl --kubeconfig "$KUBE" get namespace "$OCM_NAMESPACE" >/dev/null 2>&1 || fail "OCM namespace does not exist or is not reachable"
kubectl --kubeconfig "$KUBE" -n "$OCM_NAMESPACE" get secret keycloak-init-secrets >/dev/null 2>&1 || fail "required OCM Keycloak secret is missing"
kubectl --kubeconfig "$KUBE" -n "$OCM_NAMESPACE" get secret postgres-postgresql >/dev/null 2>&1 || fail "required OCM PostgreSQL secret is missing"
kubectl --kubeconfig "$KUBE" -n "$OCM_NAMESPACE" get secret vault >/dev/null 2>&1 || fail "required OCM Vault secret is missing"

docker version >/dev/null 2>&1 || fail "docker is not reachable on this host"
# registry login skipped: image is built locally and consumed directly by the docker container runtime

echo "PREFLIGHT_OK=true"
