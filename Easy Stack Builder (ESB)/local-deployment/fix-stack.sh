#!/usr/bin/env bash
#
# Post-deployment fixes for the OCM-W stack (state of the published images, July 2026).
# All of these are functional defects independent of the tunnel setup: without them the
# wallet cannot complete a single OID4VCI issuance. Run once after OCM-WStack/deploy.sh.
#
# Requires: kubectl, docker (cluster must run the docker container runtime so locally
# built images are visible to the kubelet), git, and network access to the chart images.
#
# Usage: ./fix-stack.sh <ocm-namespace>

set -euo pipefail

OCM_NS="${1:?ocm namespace is required}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">> 1/5 pre-authorization-bridge: sign tokens with the key that is actually published"
# The chart templates the bridge's crypto namespace with the k8s namespace, but
# deploy.sh creates the signing key in the 'tenant_space' transit mount, which is
# also what the published JWKS (/.well-known/jwks.json) serves. In addition the
# engine cannot auto-mount a transit engine at "<ns>" because "<ns>/storage" is
# already mounted. Point the bridge at tenant_space and use the JWKS kid verbatim
# (the did:web kid does not exist in the key set).
kubectl set env deploy/pre-authorization-bridge -n "$OCM_NS" \
  PREAUTHBRIDGE_OAUTH_NAMESPACE=tenant_space \
  PREAUTHBRIDGE_OAUTH_ISSUER_KID=signerkey

echo ">> 2/5 credential-retrieval-service: point holder-binding sign requests at the signer"
# The chart ships the placeholder topic 'signer-topic'; the signer subscribes to 'sign'.
kubectl patch deploy credential-retrieval-service -n "$OCM_NS" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/imagePullSecrets"}]' 2>/dev/null || true
kubectl set env deploy/credential-retrieval-service -n "$OCM_NS" CREDENTIALRETRIEVAL_SIGNER_TOPIC=sign

echo ">> 3/5 credential-retrieval-service: build image with credential-request fix"
# Upstream panics when the token response carries authorization_details with an empty
# credential_identifiers list (which this stack's own bridge always produces), and its
# format-based fallback is rejected by the issuer service. The patch requests by
# credential_configuration_id instead. See credential-retrieval-service.patch.
if [ ! -d "$DIR/.retrieval-src" ]; then
  git clone --depth 1 https://github.com/eclipse-xfsc/oid4-vci-credential-retrieval-service.git "$DIR/.retrieval-src"
fi
git -C "$DIR/.retrieval-src" apply --check "$DIR/credential-retrieval-service.patch" 2>/dev/null \
  && git -C "$DIR/.retrieval-src" apply "$DIR/credential-retrieval-service.patch" || true
docker build -f "$DIR/.retrieval-src/deployment/docker/Dockerfile" \
  -t local/credential-retrieval-service:identifier-fix "$DIR/.retrieval-src"
CN="$(kubectl get deploy credential-retrieval-service -n "$OCM_NS" -o jsonpath='{.spec.template.spec.containers[0].name}')"
kubectl set image deploy/credential-retrieval-service -n "$OCM_NS" "$CN=local/credential-retrieval-service:identifier-fix"
kubectl patch deploy credential-retrieval-service -n "$OCM_NS" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'

echo ">> 4/5 sd-jwt-service: fix hash algorithm casing"
# The published :latest image hardcodes hashAlg 'SHA-256' while its bundled
# @sd-jwt/core only accepts IANA lowercase names ('sha-256'), so every SD-JWT
# creation fails with "Invalid hash algorithm: SHA-256".
docker build -t local/sd-jwt-service:hashalg-fix - <<'EOF'
FROM node-654e3bca7fbeeed18f81d7c7.ps-xaas.io/common-services/sd-jwt-service:latest
USER root
RUN sed -i "s/hashAlg: 'SHA-256'/hashAlg: 'sha-256'/g" /home/node/app/dist/server.js
USER node
EOF
CN="$(kubectl get deploy sd-jwt-service -n "$OCM_NS" -o jsonpath='{.spec.template.spec.containers[0].name}')"
kubectl patch deploy sd-jwt-service -n "$OCM_NS" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/imagePullSecrets"}]' 2>/dev/null || true
kubectl set image deploy/sd-jwt-service -n "$OCM_NS" "$CN=local/sd-jwt-service:hashalg-fix"
kubectl patch deploy sd-jwt-service -n "$OCM_NS" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'

echo ">> 5/5 dummycontentsigner: unstick rollouts"
# The rendered manifest carries an invalid empty imagePullSecrets entry that breaks
# strategic-merge patching, and the chart probes :8080/isAlive although the app has
# no HTTP server at all - the pod can never become Ready, which wedges rollouts at
# maxUnavailable=0 and leaves a stale pod broadcasting outdated issuer metadata
# (it is a NATS worker; readiness does not gate that). It must keep running: it
# both broadcasts the issuer metadata and materializes the demo credentials.
kubectl patch deploy dummycontentsigner -n "$OCM_NS" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/imagePullSecrets"}]' 2>/dev/null || true
kubectl patch deploy dummycontentsigner -n "$OCM_NS" --type=merge \
  -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1}}}}'
kubectl patch deploy dummycontentsigner -n "$OCM_NS" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]' 2>/dev/null || true

for d in pre-authorization-bridge credential-retrieval-service sd-jwt-service dummycontentsigner; do
  kubectl rollout status deploy/"$d" -n "$OCM_NS" --timeout=3m || true
done

echo
echo "All fixes applied. Note: the first authenticated request of a brand-new user may"
echo "still return 424 while the per-user Vault key bootstraps; if a user was created"
echo "before the fixes, verify their user_secrets secret_id has a matching Vault key in"
echo "accountSpace/<user-id>/keys."
