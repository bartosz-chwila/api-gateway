#!/usr/bin/env bash

#
##Description: This scripts installs and test api-gateway custom domain test using the CLI on a real Gardener GCP cluster.
## exit on error, and raise error when variable is not set when used

set -euo pipefail

function check_required_vars() {
  local requiredVarMissing=false
  for var in "$@"; do
    if [ -z "${var}" ]; then
      >&2 echo "Environment variable ${var} is required but not set"
      requiredVarMissing=true
    fi
  done
  if [ "${requiredVarMissing}" = true ] ; then
    exit 2
  fi
}

requiredVars=(
    GARDENER_KYMA_PROW_KUBECONFIG
    GARDENER_KYMA_PROW_PROJECT_NAME
)

check_required_vars "${requiredVars[@]}"

function cleanup() {
  kubectl annotate shoot "${CLUSTER_NAME}" confirmation.gardener.cloud/deletion=true \
      --overwrite \
      -n "garden-${GARDENER_KYMA_PROW_PROJECT_NAME}" \
      --kubeconfig "${GARDENER_KYMA_PROW_KUBECONFIG}"

  kubectl delete shoot "${CLUSTER_NAME}" \
    --wait="false" \
    --kubeconfig "${GARDENER_KYMA_PROW_KUBECONFIG}" \
    -n "garden-${GARDENER_KYMA_PROW_PROJECT_NAME}"
}

# Cleanup on exit, be it successful or on fail
trap cleanup EXIT INT

# Add pwd to path to be able to use binaries downloaded in scripts
export PATH="${PATH}:${PWD}"

# wait for build job
./tests/integration/scripts/jobguard.sh

CLUSTER_NAME=ag-$(echo $RANDOM | md5sum | head -c 7)
export CLUSTER_NAME
./tests/integration/scripts/provision-gardener.sh

echo "waiting for Gardener to finish shoot reconcile..."
kubectl wait --kubeconfig "${GARDENER_KYMA_PROW_KUBECONFIG}" --for=jsonpath='{.status.lastOperation.state}'=Succeeded --timeout=600s "shoots/${CLUSTER_NAME}"

cat <<EOF > patch.yaml
spec:
  extensions:
    - type: shoot-dns-service
      providerConfig:
        apiVersion: service.dns.extensions.gardener.cloud/v1alpha1
        dnsProviderReplication:
          enabled: true
        kind: DNSConfig
        syncProvidersFromShootSpecDNS: true
    - type: shoot-cert-service
      providerConfig:
        apiVersion: service.cert.extensions.gardener.cloud/v1alpha1
        kind: CertConfig
        shootIssuers:
          enabled: true
EOF

kubectl patch shoot "${CLUSTER_NAME}" --patch-file patch.yaml --kubeconfig "${GARDENER_KYMA_PROW_KUBECONFIG}"
make install-kyma

echo "waiting for Gardener to finish shoot reconcile..."
kubectl wait --kubeconfig "${GARDENER_KYMA_PROW_KUBECONFIG}" --for=jsonpath='{.status.lastOperation.state}'=Succeeded --timeout=600s "shoots/${CLUSTER_NAME}"

# KYMA_DOMAIN is required by the tests
export TEST_DOMAIN="${CLUSTER_NAME}.${GARDENER_KYMA_PROW_PROJECT_NAME}.shoot.live.k8s-hana.ondemand.com"
export TEST_CUSTOM_DOMAIN="a.build.kyma-project.io"

make test-custom-domain
