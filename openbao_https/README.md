# OpenBao over HTTPS (and killing `insecure_skip_verify`)

Goal: every SPIRE → OpenBao request that crosses the network is TLS, with the
server certificate actually verified against a pinned CA.

Two hops exist in these manifests:

| hop | before | after |
| --- | --- | --- |
| spire-server → OpenBao (`server-configmap-ksa.yaml`, k8s auth) | `http://` + `insecure_skip_verify = true` | `https://` + `ca_cert_path` |
| bao-agent → OpenBao (`spire-bao-agent-configmap.yaml`) | `http://` | `https://` + `ca_cert` |
| spire-server → bao-agent `api_proxy` (`127.0.0.1:8200`) | `http://` | unchanged — loopback inside the pod's own netns, never on the wire |

## Why a separate transport CA

OpenBao's `pki_int` is what SPIRE asks to sign its intermediate. OpenBao cannot
issue its own listener cert from a mount that is only reachable *through* that
listener. `01-openbao-tls-certs.yaml` therefore creates a small self-signed CA
in cert-manager purely for transport identity. It is not the SPIRE trust root
and must not be used for workload identity.

## Bring-up

1. Issue the listener cert (needs cert-manager, already in the bring-up notes):

   ```
   kubectl apply -f 01-openbao-tls-certs.yaml
   kubectl wait --for=condition=Ready certificate/openbao-tls -n default --timeout=120s
   ```

   Result: Secret `openbao-tls` in `default` with `tls.crt`, `tls.key`, `ca.crt`.

2. Install/upgrade OpenBao with TLS:

   ```
   helm repo add openbao https://openbao.github.io/openbao-helm
   helm upgrade --install openbao openbao/openbao -n default -f 02-openbao-values-tls.yaml
   ```

   `global.tlsDisable: false` flips `BAO_ADDR`/`BAO_API_ADDR` and the probe
   scheme to https; the listener's `tls_cert_file`/`tls_key_file` come from the
   mounted secret. The readiness probe runs `bao status -tls-skip-verify` over
   loopback — that is the chart's own probe, not a client trust decision.

3. Init/unseal as before (`bao operator init`, `bao operator unseal`). `BAO_CACERT`
   is already set in the pod, so the CLI verifies the cert instead of skipping it.

4. Publish the CA into the `spire` namespace:

   ```
   kubectl apply -f 03-openbao-ca-to-spire.yaml   # trust-manager Bundle
   ```

   Produces ConfigMap `openbao-transport-ca` (key `ca.crt`) in `spire`. Without
   trust-manager, use the static copy shown at the bottom of that file — but then
   the copy must be refreshed whenever the CA rotates.

5. Apply SPIRE. The statefulsets now mount that ConfigMap:
   - `server-statefulset-ksa.yaml` → `/run/spire/openbao-ca/ca.crt`, referenced by
     `ca_cert_path` in the `UpstreamAuthority "vault"` block.
   - `server-statefulset.yaml` (bao-agent variant) → `/etc/openbao/ca/ca.crt`,
     referenced by `ca_cert` in both agent HCL files.

## Validating that it is really verified

Do not trust "the pod is Running". The failure mode of a mispinned CA is a
`x509: certificate signed by unknown authority` at the moment SPIRE first calls
`sign-intermediate`, which can be minutes after start.

- `kubectl logs -n default openbao-0 | grep -i tls` — should show the listener
  bound with TLS, no `tls: disabled`.
- `kubectl logs -n spire spire-server-0 -c spire-server | grep -iE 'upstream|x509|tls'`
  — a successful run logs the signed intermediate; a trust failure logs
  `certificate signed by unknown authority`.
- Negative test (the important one): temporarily point `ca_cert_path` at an
  unrelated CA and confirm SPIRE *fails*. If it still succeeds, verification is
  not happening and something is still skipping it.
- Confirm plaintext is dead: `bao status -address=http://openbao.default.svc:8200`
  from a debug pod must fail (the listener speaks TLS only).
- `kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server bundle show`
  still returns the OpenBao-rooted bundle.

## Remaining plaintext hops in this tutorial

- `jwt_issuer` / the OIDC discovery provider is still `http://spire-server.spire.svc:8080`.
  If OpenBao's `auth/jwt` fetches JWKS from it, that hop is unauthenticated:
  give the provider its own cert-manager cert and configure
  `oidc_discovery_ca_pem` on `auth/jwt/config`.
- The listener does not require client certificates. Enabling
  `tls_require_and_verify_client_cert` (commented in the values file) gives true
  mTLS, but every client — SPIRE, bao-agent, CLI, injector — must then present a
  cert from the transport CA. Until then, client authenticity comes from the k8s
  SA token / JWT-SVID, not from TLS.
