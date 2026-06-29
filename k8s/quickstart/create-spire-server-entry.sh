#!/bin/bash
# SPIRE workload entry for spire-server ServiceAccount (JWT-SVID aud=openbao).
# Run AFTER spire-server-0 is Ready and spire-agent is running on the server node.
set -euo pipefail

kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -parentID spiffe://example.org/ns/spire/sa/spire-agent \
  -spiffeID spiffe://example.org/ns/spire/sa/spire-server \
  -selector k8s:ns:spire \
  -selector k8s:sa:spire-server \
  -jwtSVIDTTL 300 \
  -x509SVIDTTL 3600

echo "Done. Watch bao-agent switch to JWT: kubectl -n spire logs spire-server-0 -c bao-agent -f"
