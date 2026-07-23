#!/bin/bash
# Version: 2026.07.22
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

# Bound a command with timeout(1) so a stall surfaces as a retriable
# failure (rc 124) inside this script's own retry loops instead of
# wedging the script until the console session around it is abandoned.
# --foreground guards against the background-process-group tty stop
# class: without it a tty-touching child freezes on SIGTTIN/SIGTTOU
# until the expiry signal. Degrades to an unbounded run when timeout
# is unavailable.
run_bounded() {
    local stall="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --foreground --kill-after=30 "$stall" "$@"
    else
        "$@"
    fi
}

# Start Docker registry if not running.
# --- REGION: https://yuruna.link/caching#workload-registry-pull-through
# The pull routes through the zot pull-through cache (stale-on-error);
# transient egress blips are retried with backoff (mirroring the
# `docker build` retry below) instead of aborting under `set -euo
# pipefail`, and each attempt is stall-bounded so a wedged pull becomes
# a retry rather than a hang.
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
    if docker_out=$(run_bounded 180 docker run -d -p 5000:5000 --restart=always --name registry "$REGISTRY_IMAGE" 2>&1); then
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

echo "==== Base images ===="
# --- REGION: https://yuruna.link/caching#workload-registry-local-first
# The build must not resolve FROM metadata over the network: buildkit's
# `load metadata` runs inside a single `docker build` invocation, so a
# stalled remote registry wedges the build where no retry loop can
# reach it. Base images are taken from the local docker store first
# (pulled into it only when missing), seeded into the localhost:5000
# registry container started above, and the build then pulls FROM the
# loopback registry only.
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
[ -z "$CACHE_HOST" ] && CACHE_HOST="yuruna-caching-proxy"
cd "$REAL_HOME/yuruna/project/example/website/components/frontend/website"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .

BASE_IMAGES=("dotnet/sdk:10.0" "dotnet/aspnet:10.0")
LOCAL_REGISTRY="localhost:5000"
ACCEPT_HDR='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# Print a local-docker-store reference whose repo:tag matches $1 under
# any registry prefix; status 1 when absent.
find_local_image() {
    local want="$1" line
    while IFS= read -r line; do
        case "$line" in
            "$want"|*/"$want")
                printf '%s\n' "$line"
                return 0
                ;;
        esac
    done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
    return 1
}

# probe_registry <base-url>: fast health gate -- 0 iff every base image
# still missing from the local store resolves a manifest there. A few-KB
# GET with a hard 30s cap, so a wedged endpoint is skipped in seconds
# instead of consuming a full bounded-pull window; on zot the GET also
# triggers the onDemand sync ahead of the pull.
probe_registry() {
    local base="$1" ref repo ver
    for ref in "${BASE_IMAGES[@]}"; do
        find_local_image "$ref" >/dev/null && continue
        repo="${ref%:*}"; ver="${ref#*:}"
        if ! curl -sf -o /dev/null --max-time 30 -H "$ACCEPT_HDR" \
                "${base}/v2/${repo}/manifests/${ver}"; then
            return 1
        fi
    done
    return 0
}

# Acquire images missing from the local store. Candidates in priority
# order: the zot pull-through cache (LAN, absorbs upstream TLS jitter),
# then mcr.microsoft.com as the survival path when the cache VM is
# absent or cannot serve the tag. Each candidate is probe-gated first;
# the pull itself is stall-bounded as a backstop for mid-stream wedges.
# The bound is a hard elapsed-time cap, not a progress check -- raise
# YURUNA_PULL_STALL_TIMEOUT on links slower than ~1 MB/s.
# All BASE_IMAGES present in the local store?
all_base_images_local() {
    local ref
    for ref in "${BASE_IMAGES[@]}"; do
        find_local_image "$ref" >/dev/null || return 1
    done
    return 0
}

PULL_STALL="${YURUNA_PULL_STALL_TIMEOUT:-300}"
acquire_rounds=2
acquire_delay=10
stalled_candidates=""
for round in $(seq 1 "$acquire_rounds"); do
    if all_base_images_local; then
        break
    fi
    for candidate in "http://${CACHE_HOST}:5000|${CACHE_HOST}:5000/" \
                     "https://mcr.microsoft.com|mcr.microsoft.com/"; do
        base="${candidate%|*}"
        prefix="${candidate#*|}"
        # A candidate that already ate a full pull bound is wedged
        # mid-stream, not blipping; retrying it costs another full
        # bound with no better odds, so it is out for this run.
        case " ${stalled_candidates} " in
            *" ${prefix} "*)
                echo "Skipping ${prefix} (stalled earlier in this run)"
                continue
                ;;
        esac
        echo "Probing registry: ${base} (round ${round}/${acquire_rounds})"
        if ! probe_registry "$base"; then
            echo "  -> not usable, trying next"
            continue
        fi
        for ref in "${BASE_IMAGES[@]}"; do
            find_local_image "$ref" >/dev/null && continue
            echo "Pulling ${prefix}${ref}"
            pull_rc=0
            run_bounded "$PULL_STALL" docker pull "${prefix}${ref}" || pull_rc=$?
            if [ "$pull_rc" -ne 0 ]; then
                if [ "$pull_rc" -eq 124 ] || [ "$pull_rc" -eq 137 ]; then
                    stalled_candidates="${stalled_candidates} ${prefix}"
                fi
                echo "  -> pull of ${prefix}${ref} failed (rc ${pull_rc}); trying next registry" >&2
                break
            fi
        done
        if all_base_images_local; then
            break
        fi
    done
    if all_base_images_local; then
        break
    fi
    if [ "$round" -lt "$acquire_rounds" ]; then
        sleep "$acquire_delay"
    fi
done

for ref in "${BASE_IMAGES[@]}"; do
    if ! local_ref=$(find_local_image "$ref"); then
        echo "ERROR: base image ${ref} is neither in the local docker store" >&2
        echo "       nor acquirable from the cache (${CACHE_HOST}:5000) or" >&2
        echo "       mcr.microsoft.com. Check network egress and the cache" >&2
        echo "       VM's /etc/zot/config.json." >&2
        exit 1
    fi
    echo "Base image ${ref} available as ${local_ref}"
    docker tag "$local_ref" "${LOCAL_REGISTRY}/${ref}"
    if ! run_bounded 300 docker push "${LOCAL_REGISTRY}/${ref}"; then
        echo "ERROR: pushing ${ref} into ${LOCAL_REGISTRY} failed -- the local" >&2
        echo "       registry container is down or wedged (docker ps; docker logs registry)." >&2
        exit 1
    fi
done
REGISTRY="${LOCAL_REGISTRY}/"
echo "Using REGISTRY=${REGISTRY}"

echo "==== Build .NET app ===="
# FROM metadata and base layers resolve from the loopback registry; the
# retry covers residual local flakes and RUN-step network (package
# restores), with the stall bound turning a wedge into a retriable
# failure.
build_attempts=3
build_delay=10
for attempt in $(seq 1 "$build_attempts"); do
    if run_bounded 600 docker build --progress=plain --rm \
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
docker tag website/website:latest "${LOCAL_REGISTRY}/website/website:latest"
if ! run_bounded 300 docker push "${LOCAL_REGISTRY}/website/website:latest"; then
    echo "ERROR: pushing website/website into ${LOCAL_REGISTRY} failed -- the local" >&2
    echo "       registry container is down or wedged (docker ps; docker logs registry)." >&2
    exit 1
fi

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
