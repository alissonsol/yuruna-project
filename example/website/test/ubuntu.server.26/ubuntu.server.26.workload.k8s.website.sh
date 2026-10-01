#!/bin/bash
# Version: 2026.09.30
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# Determine the real user (even when running with sudo)
# --- REGION: Resolve guest user
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

mkcert -install 2>/dev/null || true

# The project archive is extracted here even when this entry point is fetched.
. "$REAL_HOME/yuruna/project/tools/example-workload.sh"
example_registry_prepare

# --- REGION: Set resource
echo ""
echo -e "\e[1;36m==== Set-Resource ====\e[0m"
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 website localhost

CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

example_build_and_push website website

cd "$REAL_HOME/yuruna/project/example"
# --- REGION: Set component
echo ""
echo -e "\e[1;36m==== Set-Component ====\e[0m"
pwsh ../../automation/Set-Component.ps1 website localhost
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
