#!/usr/bin/env bash
#
# Build patched images for the two published images that currently block the
# OID4VCI issuance flow (see README.md) and point the deployments at them.
#
# Usage: ./apply-image-fixes.sh <ocm-namespace> [registry-prefix]
#   Without a registry prefix the images stay local, which works on clusters
#   whose container runtime is docker (the kubelet sees locally built images).
#   With a prefix the images are pushed there and referenced by that name.

set -euo pipefail

OCM_NS="${1:?ocm namespace is required}"
REGISTRY="${2:-local}"
DIR="$(cd "$(dirname "$0")" && pwd)"

SDJWT_IMG="$REGISTRY/sd-jwt-service:hashalg-fix"
RETRIEVAL_IMG="$REGISTRY/credential-retrieval-service:identifier-fix"

echo ">> building $SDJWT_IMG (lowercase IANA hash name, sd-jwt-service#33)"
docker build -t "$SDJWT_IMG" - <<'EOF'
FROM node-654e3bca7fbeeed18f81d7c7.ps-xaas.io/common-services/sd-jwt-service:latest
USER root
RUN sed -i "s/hashAlg: 'SHA-256'/hashAlg: 'sha-256'/g" /home/node/app/dist/server.js
USER node
EOF

echo ">> building $RETRIEVAL_IMG (credential request fix, oid4-vci-credential-retrieval-service#11)"
if [ ! -d "$DIR/.retrieval-src" ]; then
  git clone --depth 1 https://github.com/eclipse-xfsc/oid4-vci-credential-retrieval-service.git "$DIR/.retrieval-src"
fi
if git -C "$DIR/.retrieval-src" apply --check "$DIR/credential-retrieval-service.patch" 2>/dev/null; then
  git -C "$DIR/.retrieval-src" apply "$DIR/credential-retrieval-service.patch"
fi
docker build -f "$DIR/.retrieval-src/deployment/docker/Dockerfile" -t "$RETRIEVAL_IMG" "$DIR/.retrieval-src"

if [ "$REGISTRY" != "local" ]; then
  docker push "$SDJWT_IMG"
  docker push "$RETRIEVAL_IMG"
fi

for pair in "sd-jwt-service=$SDJWT_IMG" "credential-retrieval-service=$RETRIEVAL_IMG"; do
  deploy="${pair%%=*}"
  image="${pair#*=}"
  container="$(kubectl -n "$OCM_NS" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].name}')"
  kubectl -n "$OCM_NS" set image "deploy/$deploy" "$container=$image"
  if [ "$REGISTRY" = "local" ]; then
    kubectl -n "$OCM_NS" patch deploy "$deploy" --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  fi
  kubectl -n "$OCM_NS" rollout status "deploy/$deploy" --timeout=3m
done

echo "done - issuance-blocking image issues remediated in namespace $OCM_NS"
