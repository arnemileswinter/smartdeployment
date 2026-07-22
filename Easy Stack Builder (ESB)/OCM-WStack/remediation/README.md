# Image-level remediation for OID4VCI issuance

The chart-value and deploy-script fixes in this repository get a fresh OCM-W
deployment healthy, but two of the container images the stack pulls currently
carry issues that block the issuance flow itself. Both are fixed or proposed in
the respective source repositories; this directory bridges the gap until
rebuilt images are published.

| Image | Issue | Source status |
|---|---|---|
| `common-services/sd-jwt-service:latest` | Hardcodes `hashAlg: 'SHA-256'`; the bundled `@sd-jwt/core` accepts only IANA lowercase names, so every SD-JWT creation fails with `Invalid hash algorithm: SHA-256` | Fixed on `main` by [sd-jwt-service#33](https://github.com/eclipse-xfsc/sd-jwt-service/pull/33) (merged 2026-05-29); image rebuild requested in [sd-jwt-service#34](https://github.com/eclipse-xfsc/sd-jwt-service/issues/34) |
| `ocm-wstack/credential-retrieval-service:latest` | Panics (`index out of range`) on the token response produced by the stack's own authorization bridge, and its fallback request is rejected by the issuer service image (which predates [oid4-vci-issuer-service#17](https://github.com/eclipse-xfsc/oid4-vci-issuer-service/pull/17)) | Fix proposed in [oid4-vci-credential-retrieval-service#11](https://github.com/eclipse-xfsc/oid4-vci-credential-retrieval-service/pull/11); the bridge side is addressed by [oid4-vci-authorization-bridge#25](https://github.com/eclipse-xfsc/oid4-vci-authorization-bridge/pull/25) |

`apply-image-fixes.sh` builds patched images from the published bases and points
the deployments at them:

```bash
# Cluster whose container runtime is docker (e.g. Rancher Desktop): local images
# are directly visible to the kubelet, no registry needed.
./apply-image-fixes.sh <ocm-namespace>

# Any other cluster: provide a registry prefix the cluster can pull from.
./apply-image-fixes.sh <ocm-namespace> registry.example.com/myproject
```

Once rebuilt images are published upstream, this directory becomes obsolete and
the deployments can simply be rolled back to the upstream image references.
