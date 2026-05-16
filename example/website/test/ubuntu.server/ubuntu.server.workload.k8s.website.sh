#!/bin/bash
# Version: 2026.05.15
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Fix kube permissions
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

# Install mkcert CA
mkcert -install 2>/dev/null || true

# Start Docker registry if not running. Pulls `registry:2` (Docker Hub
# canonical, i.e. docker.io/library/registry:2). Dockerd's registry-
# mirrors in /etc/docker/daemon.json (set by guest/ubuntu.server/
# ubuntu.server.k8s.sh at provision time) routes this through the
# yuruna-caching-proxy's zot pull-through cache -- zot serves the
# manifest from cache with stale-on-error semantics, so upstream rate-
# limit blips no longer break the test. A prior workaround pinned
# `public.ecr.aws/docker/library/registry:2` to dodge Docker Hub's
# anonymous limit, but that mirror has itself returned 400 across
# multiple test hosts simultaneously; the zot pull-through is the
# durable fix.
REGISTRY_IMAGE="registry:2"
if ! docker start registry 2>/dev/null; then
    if ! docker_out=$(docker run -d -p 5000:5000 --restart=always --name registry "$REGISTRY_IMAGE" 2>&1); then
        echo "docker run registry failed:" >&2
        echo "$docker_out" >&2
        # AWS ECR Public returns 400 (not 429) when its anonymous-pull
        # quota is exhausted, so match both shapes. Match Docker Hub's
        # documented strings AND the upstream-host substrings that
        # indicate a rate-limit response masquerading as 400.
        if echo "$docker_out" | grep -qiE 'pull rate limit|toomanyrequests|429 Too Many Requests|400 Bad Request.*public\.ecr\.aws|public\.ecr\.aws.*400 Bad Request'; then
            echo "" >&2
            echo "ERROR: Registry image pull hit a rate limit (or upstream throttle disguised as 400)." >&2
            echo "       Image: $REGISTRY_IMAGE" >&2
            echo "       The upstream is throttling pulls from the cache VM's egress IP." >&2
            echo "       Options: (1) wait and retry, (2) authenticate the zot proxy to upstream," >&2
            echo "                (3) bake the registry image into the guest base via cloud-init," >&2
            echo "                (4) check that the caching proxy's zot is up:" >&2
            echo "                    curl -fsS http://yuruna-caching-proxy:5000/v2/" >&2
            echo "" >&2
        fi
        exit 1
    fi
fi

# Run Set-Resource
echo "==== Set-Resource ===="
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 website localhost

# Rename kubectl context to match runId
CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# Build and push Docker image
cd "$REAL_HOME/yuruna/project/example/website/components/frontend/website"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .
docker build --progress=plain --rm --build-arg DEV=1 --no-cache -f Dockerfile -t "website/website:latest" .
docker tag website/website:latest localhost:5000/website/website:latest
docker push localhost:5000/website/website:latest

# Run Set-Component and Set-Workload
cd "$REAL_HOME/yuruna/project/example"
echo "==== Set-Component ===="
pwsh ../../automation/Set-Component.ps1 website localhost
echo "==== Set-Workload ===="
pwsh ../../automation/Set-Workload.ps1 website localhost
