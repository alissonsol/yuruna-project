#!/bin/bash
# Version: 2026.07.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Fix kube permissions
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

# Install mkcert CA
mkcert -install 2>/dev/null || true

# Start Docker registry if not running.
# --- REGION: https://yuruna.link/caching#workload-registry-pull-through
# The pull routes through the zot pull-through cache (stale-on-error);
# transient egress blips are retried with backoff (mirroring the
# `docker build` retry below) instead of aborting under `set -euo pipefail`.
REGISTRY_IMAGE="registry:2"
registry_attempts=3
registry_delay=10
for attempt in $(seq 1 "$registry_attempts"); do
    # Fast path / idempotent restart of an already-created container.
    if docker start registry 2>/dev/null; then
        break
    fi
    # A failed prior `docker run` can leave a created/exited container
    # holding the name; clear it so `docker run --name registry` is clean.
    docker rm -f registry >/dev/null 2>&1 || true
    if docker_out=$(docker run -d -p 5000:5000 --restart=always --name registry "$REGISTRY_IMAGE" 2>&1); then
        break
    fi
    echo "docker run registry failed (attempt ${attempt}/${registry_attempts}):" >&2
    echo "$docker_out" >&2
    # ECR Public reports an exhausted anonymous-pull quota as 400 (not 429);
    # a throttle will not clear on a quick retry, so stop with guidance now.
    # --- REGION: https://yuruna.link/network#defining-registry-rate-limit-400
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
        exit 1
    fi
    if [ "$attempt" -ge "$registry_attempts" ]; then
        echo "ERROR: could not start the registry container after ${registry_attempts} attempts" >&2
        exit 1
    fi
    echo "retrying registry start in ${registry_delay}s" >&2
    sleep "$registry_delay"
    registry_delay=$((registry_delay * 2))
done

echo "==== Set-Resource ===="
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 website localhost

# Rename kubectl context to match runId
CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

echo "==== Registry probe ===="
# Build and push Docker image.
# --- REGION: https://yuruna.link/caching#workload-registry-probe
# Probe candidates in priority order (zot cache first, mcr.microsoft.com
# as the survival path); on zot the probe also triggers the onDemand sync.
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
[ -z "$CACHE_HOST" ] && CACHE_HOST="yuruna-caching-proxy"
cd "$REAL_HOME/yuruna/project/example/website/components/frontend/website"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .

BASE_IMAGES=("dotnet/sdk:10.0" "dotnet/aspnet:10.0")
ACCEPT_HDR='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

probe_registry() {
    # $1 = base URL (no trailing slash). Returns 0 iff every BASE_IMAGES
    # manifest resolves on that registry within the timeout.
    local base="$1" ref repo ver
    for ref in "${BASE_IMAGES[@]}"; do
        repo="${ref%:*}"; ver="${ref#*:}"
        if ! curl -sf -o /dev/null --max-time 30 -H "$ACCEPT_HDR" \
                "${base}/v2/${repo}/manifests/${ver}"; then
            return 1
        fi
    done
    return 0
}

REGISTRY=""
for candidate in "http://${CACHE_HOST}:5000|${CACHE_HOST}:5000/" \
                 "https://mcr.microsoft.com|mcr.microsoft.com/"; do
    base="${candidate%|*}"
    prefix="${candidate#*|}"
    echo "Probing registry: ${base}" >&2
    if probe_registry "$base"; then
        REGISTRY="$prefix"
        echo "Using REGISTRY=${REGISTRY}" >&2
        break
    fi
    echo "  -> not usable, trying next" >&2
done
if [ -z "$REGISTRY" ]; then
    echo "ERROR: neither the cache (${CACHE_HOST}:5000) nor mcr.microsoft.com" >&2
    echo "       could serve the base-image manifests. Check network egress" >&2
    echo "       and the cache VM's /etc/zot/config.json." >&2
    exit 1
fi

echo "==== Build .NET app ===="
# Retry the build itself for residual TLS jitter even after the probe
# succeeded; manifests can resolve and a layer pull still stutter.
build_attempts=3
build_delay=10
for attempt in $(seq 1 "$build_attempts"); do
    if docker build --progress=plain --rm \
            --build-arg DEV=1 \
            --build-arg "REGISTRY=${REGISTRY}" \
            -f Dockerfile -t "website/website:latest" .; then
        break
    fi
    if [ "$attempt" -ge "$build_attempts" ]; then
        echo "ERROR: docker build failed after ${build_attempts} attempts" >&2
        exit 1
    fi
    echo "docker build attempt ${attempt}/${build_attempts} failed; retrying in ${build_delay}s" >&2
    sleep "$build_delay"
    build_delay=$((build_delay * 2))
done

echo "==== Push to docker registry ===="
docker tag website/website:latest localhost:5000/website/website:latest
docker push localhost:5000/website/website:latest

# --- REGION: https://yuruna.link/kubernetes#reclaim-build-cache-disk-before-deploy
# Prune build caches before the cluster deploys so kubelet's ephemeral-
# storage watermark is not tripped.
# Failure here is non-fatal: we only care about the side effect.
docker buildx prune --all --force >/dev/null 2>&1 || true
docker builder prune --all --force >/dev/null 2>&1 || true
docker image prune --force >/dev/null 2>&1 || true

cd "$REAL_HOME/yuruna/project/example"
echo "==== Set-Component ===="
pwsh ../../automation/Set-Component.ps1 website localhost
echo "==== Set-Workload ===="
pwsh ../../automation/Set-Workload.ps1 website localhost
