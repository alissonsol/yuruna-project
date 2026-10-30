#!/bin/bash
# Version: 2026.10.30
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42752a6e-f3b2-4518-b629-f8d9487a7bb7
# --- REGION: Initialize environment
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: Resolve guest user
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ -z "$REAL_HOME" ]; then
    echo "ERROR: no home directory found for guest user ${REAL_USER}." >&2
    exit 1
fi

# --- REGION: Prepare Kubernetes configuration
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

mkcert -install 2>/dev/null || true

# --- REGION: Prepare container registry
# The project archive is extracted here even when this entry point is fetched.
. "$REAL_HOME/yuruna/project/tools/example-workload.sh"
example_registry_prepare
# The component pipeline builds and publishes the image; deployment creates its certificate.
export YURUNA_EXAMPLE_SELF_SIGNED_CERT=1

# --- REGION: Set resource
echo ""
echo -e "\e[1;36m==== Set-Resource ====\e[0m"
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 website localhost

CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# --- REGION: Set component
echo ""
echo -e "\e[1;36m==== Set-Component ====\e[0m"
pwsh ../../automation/Set-Component.ps1 website localhost
example_prune_build_cache
# --- REGION: Set workload
echo ""
echo -e "\e[1;36m==== Set-Workload ====\e[0m"
pwsh ../../automation/Set-Workload.ps1 website localhost

# --- REGION: Wait for readiness
# See https://yuruna.link/42a76c30-000b
# See https://yuruna.link/42e220c4-0009
echo ""
echo -e "\e[1;36m==== Wait for readiness ====\e[0m"
kubectl wait --for=condition=available deployment/website -n website --timeout=240s
kubectl wait --for=condition=available deployment/nginx-ingress-ingress-nginx-controller -n ingress-ns --timeout=240s
