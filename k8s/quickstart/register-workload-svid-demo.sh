#!/usr/bin/env bash
# Registration entries for workload-svid-demo.yaml pods.
# Parent must match your node agent join graph (same as create-node-registration-entry.sh).
set -euo pipefail

PARENT_ID="${PARENT_ID:-spiffe://example.org/ns/spire/sa/spire-agent}"

kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -parentID spiffe://example.org/ns/spire/sa/spire-agent \
  -spiffeID spiffe://example.org/workload/busybox-x509 \
  -selector k8s:ns:default \
  -selector k8s:sa:svid-x509 \
  -x509SVIDTTL 3600

kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
   -parentID spiffe://example.org/ns/spire/sa/spire-agent \
  -spiffeID spiffe://example.org/workload/busybox-jwt \
  -selector k8s:ns:default \
  -selector k8s:sa:svid-jwt \
  -x509SVIDTTL 3600 \
  -jwtSVIDTTL 300

echo "Entries created. Schedule busybox-1/2 on nodes that already run spire-agent (DaemonSet)."
