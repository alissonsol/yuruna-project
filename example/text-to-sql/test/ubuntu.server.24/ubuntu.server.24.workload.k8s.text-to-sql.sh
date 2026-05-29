#!/bin/bash
# Version: 2026.05.29
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
# mirrors in /etc/docker/daemon.json (set by guest/ubuntu.server.24/
# ubuntu.server.24.k8s.sh at provision time) routes this through the
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

echo "==== Set-Resource ===="
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 text-to-sql localhost

# Rename kubectl context to match runId
CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/text-to-sql/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# Build and push Docker image.
#
# Registry selection: probe candidates in priority order, pick the first
# that can serve every base-image manifest the Dockerfile needs.
#   1. ${CACHE_HOST}:5000/   -- zot pull-through cache (fastest, also
#                               absorbs MCR TLS jitter)
#   2. mcr.microsoft.com/    -- direct upstream; the survival path when
#                               the cache VM is absent, unreachable, has
#                               an old config that doesn't know mcr, or
#                               is otherwise unable to serve the tag
# The probe is a Docker Registry v2 manifest GET. On zot it also triggers
# the onDemand sync, so a cache that simply hasn't pulled the image yet
# warms up here -- not mid-`docker build` where a failure is harder to
# diagnose.
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
[ -z "$CACHE_HOST" ] && CACHE_HOST="yuruna-caching-proxy"
cd "$REAL_HOME/yuruna/project/example/text-to-sql/components/frontend/text-to-sql-ui"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .

BASE_IMAGES=("dotnet/sdk:10.0" "dotnet/aspnet:10.0")
ACCEPT_HDR='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

probe_registry() {
    # $1 = base URL (no trailing slash). Returns 0 iff every BASE_IMAGES
    # manifest resolves on that registry within the timeout.
    #
    # --max-time 60 (not 30): zot's onDemand sync for a cold multi-arch
    # manifest can take 14-30s end-to-end (skopeo walks the index, fetches
    # per-arch manifests + config blobs, writes to disk). A 30s cap can
    # time out on dotnet/sdk:10.0 -- zot returns 200 immediately after,
    # but the probe has already declared the cache "not usable" and
    # fallen back to direct upstream MCR (which itself can TLS-jitter).
    # 60s accommodates zot's worst-case cold sync while still bounding
    # the probe.
    local base="$1" ref repo ver
    for ref in "${BASE_IMAGES[@]}"; do
        repo="${ref%:*}"; ver="${ref#*:}"
        if ! curl -sf -o /dev/null --max-time 60 -H "$ACCEPT_HDR" \
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

# Retry the build itself for residual TLS jitter even after the probe
# succeeded; manifests can resolve and a layer pull still stutter.
build_attempts=3
build_delay=10
for attempt in $(seq 1 "$build_attempts"); do
    if docker build --progress=plain --rm \
            --build-arg DEV=1 \
            --build-arg "REGISTRY=${REGISTRY}" \
            -f Dockerfile -t "text-to-sql/text-to-sql-ui:latest" .; then
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
docker tag text-to-sql/text-to-sql-ui:latest localhost:5000/text-to-sql/text-to-sql-ui:latest
docker push localhost:5000/text-to-sql/text-to-sql-ui:latest

# Reclaim build-cache disk before the cluster deploys. The dotnet SDK
# build leaves ~1.3 GiB in `docker buildx prune` territory and another
# ~0.5 GiB of dangling intermediate images. On a 14 GiB node disk that
# was enough to trip kubelet's 85% ephemeral-storage watermark, get
# the text-to-sql-ui + nginx-ingress pods Evicted, and leave their
# replacements stuck on the disk-pressure taint.
# Failure here is non-fatal: we only care about the side effect.
docker buildx prune --all --force >/dev/null 2>&1 || true
docker builder prune --all --force >/dev/null 2>&1 || true
docker image prune --force >/dev/null 2>&1 || true

cd "$REAL_HOME/yuruna/project/example"
echo "==== Set-Component ===="
pwsh ../../automation/Set-Component.ps1 text-to-sql localhost
echo "==== Set-Workload ===="
pwsh ../../automation/Set-Workload.ps1 text-to-sql localhost
