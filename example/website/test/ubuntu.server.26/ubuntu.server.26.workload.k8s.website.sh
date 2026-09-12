#!/bin/bash
# Version: 2026.09.12
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

# --- REGION: Bounded command execution
# See https://yuruna.link/42e220c4-0009
run_bounded() {
    local stall="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --foreground --kill-after=30 "$stall" "$@"
    else
        "$@"
    fi
}

# --- REGION: Locate caching proxy
# See https://yuruna.link/42f6b05f-0019
# See https://yuruna.link/42e220c4-0009
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
if [ -z "$CACHE_HOST" ] && [ -r /etc/yuruna/host.env ]; then
    CACHE_HOST=$(sed -nE 's/^YURUNA_CACHING_PROXY_SERVICE_IP=([^[:space:]]+).*/\1/p' /etc/yuruna/host.env | head -n1)
fi
if [ -z "$CACHE_HOST" ] \
   && curl -fsS --max-time 10 -o /dev/null "http://yuruna-caching-proxy-service:5000/v2/" 2>/dev/null; then
    CACHE_HOST="yuruna-caching-proxy-service"
fi
if [ -n "$CACHE_HOST" ]; then
    echo "Caching proxy: ${CACHE_HOST} -- image pulls are mirrored through it."
else
    echo "Caching proxy: none in this lab -- image pulls go to the upstreams directly."
fi

# --- REGION: Bound image pulls
# See https://yuruna.link/42e220c4-0009
PULL_STALL="${YURUNA_PULL_STALL_TIMEOUT:-300}"

# Media types accepted from every manifest request below. Spelled out
# because a registry answers a manifest GET that states no preference with
# whatever it considers the default -- for a multi-arch tag that is not the
# index the pull needs.
ACCEPT_HDR='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# --- REGION: Local image lookup
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

# --- REGION: Warm a cold manifest
# See https://yuruna.link/42e220c4-0009
warm_manifest() {
    local repo="$1" tag="$2" probe code elapsed
    # The warm-up exists to hold a request open against a cache that is still
    # syncing. With no cache in this lab there is nothing to warm and no
    # address to address it by, and the pull behind this goes straight to the
    # upstream.
    [ -n "$CACHE_HOST" ] || return 0
    echo "Warming ${CACHE_HOST}:5000/${repo}:${tag} (up to ${PULL_STALL}s)"
    # --- REGION: https://yuruna.link/42e220c4-0009
    local probe_rc=0
    probe=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
            --max-time "$PULL_STALL" -H "$ACCEPT_HDR" \
            "http://${CACHE_HOST}:5000/v2/${repo}/manifests/${tag}") || probe_rc=$?
    code="${probe%% *}"
    elapsed="${probe##* }"
    elapsed="${elapsed%%.*}"
    case "$code" in
        200)
            echo "  -> cache holds ${repo}:${tag} (answered in ${elapsed}s)"
            ;;
        ''|000)
            # No HTTP status at all has several causes that send the operator to
            # different places, and curl's exit code is the only thing that
            # separates them. Reporting all of them as the timeout wording sends
            # every reader after a sync that is still running -- which is the
            # wrong place to look for a cache that refused the connection in
            # milliseconds because nothing is listening on the port yet.
            case "$probe_rc" in
                7)  echo "  -> cache refused the connection after ${elapsed}s -- nothing is listening on ${CACHE_HOST}:5000; pulling anyway" >&2 ;;
                6)  echo "  -> cache host ${CACHE_HOST} did not resolve; pulling anyway" >&2 ;;
                28) echo "  -> cache did not answer within ${PULL_STALL}s; pulling anyway" >&2 ;;
                *)  echo "  -> cache returned no HTTP status after ${elapsed}s (curl rc=${probe_rc}); pulling anyway" >&2 ;;
            esac
            ;;
        *)
            echo "  -> cache answered HTTP ${code} after ${elapsed}s; pulling anyway" >&2
            ;;
    esac
    return 0
}

# --- REGION: Start local registry
# See https://yuruna.link/42f6b05f-0019
# See https://yuruna.link/42e220c4-0009
REGISTRY_IMAGE="registry:2"
# --- REGION: https://yuruna.link/42e220c4-0009
if [ -n "$CACHE_HOST" ]; then
    REGISTRY_PULL_REF="${CACHE_HOST}:5000/library/registry:2"
else
    REGISTRY_PULL_REF="$REGISTRY_IMAGE"
fi
# --- REGION: https://yuruna.link/42f6b05f-0019
# The ladder is sized to outlast a caching-proxy REBUILD, not just a blip: the
# replacement VM refuses connections on :5000 for as long as it takes to boot
# and start zot, which is minutes rather than seconds. 10+20+40+80 spends about
# two and a half minutes before giving up, so a rebuild that overlaps this step
# costs a pause instead of the whole run.
registry_attempts=5
registry_delay=10
for attempt in $(seq 1 "$registry_attempts"); do
    # Fast path / idempotent restart of an already-created container.
    if docker start registry 2>/dev/null; then
        break
    fi
    # A failed prior `docker run` can leave a created/exited container
    # holding the name; clear it so `docker run --name registry` is clean.
    docker rm -f registry >/dev/null 2>&1 || true
    registry_local=""
    docker_out=""
    if ! registry_local=$(find_local_image "$REGISTRY_IMAGE"); then
        # Every attempt warms before it pulls. The warm-up is what holds the
        # request open past dockerd's fixed response-header patience while the
        # cache completes its sync, so an attempt that skips it cannot build
        # on progress made by the preceding attempt's background sync: it is
        # bounded by that patience alone, which a cache still syncing cannot
        # answer inside.
        warm_manifest "library/registry" "2"
        if docker_out=$(run_bounded "$PULL_STALL" docker pull "$REGISTRY_PULL_REF" 2>&1); then
            registry_local="$REGISTRY_PULL_REF"
        fi
    fi
    if [ -n "$registry_local" ]; then
        # `docker run` below names the bare tag, so whatever the store holds
        # has to answer to it -- and answer FROM the store, resolving
        # nothing over the network.
        [ "$registry_local" = "$REGISTRY_IMAGE" ] || docker tag "$registry_local" "$REGISTRY_IMAGE"
        if docker_out=$(run_bounded 180 docker run -d -p 5000:5000 --restart=always --name registry "$REGISTRY_IMAGE" 2>&1); then
            break
        fi
    fi
    echo "registry start failed (attempt ${attempt}/${registry_attempts}):" >&2
    echo "$docker_out" >&2
    # --- REGION: https://yuruna.link/42e220c4-0009
    if echo "$docker_out" | grep -qiE 'connection refused|no such host|could not resolve|server misbehaving|i/o timeout|dial tcp'; then
        if [ "$attempt" -lt "$registry_attempts" ]; then
            if [ -n "$CACHE_HOST" ]; then
                echo "the caching proxy's registry is not answering at ${CACHE_HOST}:5000 yet; it may be restarting" >&2
            else
                echo "docker.io did not answer; retrying" >&2
            fi
        elif [ -n "$CACHE_HOST" ]; then
            echo "" >&2
            echo "ERROR: the caching proxy's registry is unreachable at ${CACHE_HOST}:5000" >&2
            echo "       and stayed unreachable across ${registry_attempts} attempts." >&2
            echo "       This pull has no upstream fallback on purpose: reaching docker.io" >&2
            echo "       directly from a guest behind a cache is rate limited and fails" >&2
            echo "       anyway." >&2
            echo "       Check that the caching proxy's zot is up:" >&2
            echo "           curl -fsS http://${CACHE_HOST}:5000/v2/" >&2
            echo "" >&2
            exit 1
        else
            # Naming the cache here would invent one. This lab has none, so the
            # upstream was the only source and the guest's own egress is what
            # to look at.
            echo "" >&2
            echo "ERROR: ${REGISTRY_PULL_REF} could not be pulled across" >&2
            echo "       ${registry_attempts} attempts, and this lab has no caching proxy," >&2
            echo "       so docker.io was the only source." >&2
            echo "       Check the guest's egress to docker.io:" >&2
            echo "           curl -fsS https://registry-1.docker.io/v2/" >&2
            echo "" >&2
            exit 1
        fi
    fi
    # --- REGION: https://yuruna.link/42e220c4-0009
    if [ -n "$CACHE_HOST" ] && echo "$docker_out" | grep -qiE 'timeout awaiting response headers|context deadline exceeded|TLS handshake timeout|Client\.Timeout exceeded'; then
        echo "" >&2
        echo "NOTE: the cache at ${CACHE_HOST}:5000 accepted the connection but did not" >&2
        echo "      return response headers in time. That is a SLOW cache, not a down" >&2
        echo "      one -- a liveness check against it will pass while pulls fail." >&2
        echo "      What it is doing while you wait is revalidating this tag against" >&2
        echo "      its upstream; the runtime's patience is shorter than that can take." >&2
        echo "      Its own reading of that latency, and of the shared upstream pull" >&2
        echo "      budget behind it:" >&2
        echo "           curl -fsS http://${CACHE_HOST}/cache-health" >&2
        echo "" >&2
    fi
    # --- REGION: https://yuruna.link/4220a755-001d
    # ECR Public reports an exhausted anonymous-pull quota as 400 (not 429);
    # a throttle will not clear on a quick retry, so stop with guidance now.
    if echo "$docker_out" | grep -qiE 'pull rate limit|toomanyrequests|429 Too Many Requests|400 Bad Request.*public\.ecr\.aws|public\.ecr\.aws.*400 Bad Request'; then
        echo "" >&2
        echo "ERROR: Registry image pull hit a rate limit (or upstream throttle disguised as 400)." >&2
        echo "       Image: $REGISTRY_PULL_REF" >&2
        if [ -n "$CACHE_HOST" ]; then
            echo "       The cache holds no copy yet and its upstream is throttling the" >&2
            echo "       lab's shared egress IP." >&2
            echo "       Options: (1) wait and retry, (2) authenticate the zot proxy to upstream," >&2
            echo "                (3) bake the registry image into the guest base via cloud-init," >&2
            echo "                (4) check that the caching proxy's zot is up:" >&2
            echo "                    curl -fsS http://${CACHE_HOST}:5000/v2/" >&2
        else
            echo "       This lab has no caching proxy, so every guest pulls on its own" >&2
            echo "       and the upstream is throttling this host's egress IP directly." >&2
            echo "       Options: (1) wait and retry, (2) bring a caching proxy up so the" >&2
            echo "                lab shares one warmed copy, (3) bake the registry image" >&2
            echo "                into the guest base via cloud-init." >&2
        fi
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

# --- REGION: Set resource
echo ""
echo -e "\e[1;36m==== Set-Resource ====\e[0m"
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 website localhost

CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# --- REGION: Seed base images
# See https://yuruna.link/42f6b05f-001a
# See https://yuruna.link/42e220c4-0009
echo ""
echo -e "\e[1;36m==== Base images ====\e[0m"
cd "$REAL_HOME/yuruna/project/example/website/components/frontend/website"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .

# The list mirrors the Dockerfile's FROM lines.
BASE_IMAGES=("dotnet/sdk:10.0" "dotnet/aspnet:10.0")
# The upstream that serves them, named to the cache by the probe below.
BASE_IMAGES_UPSTREAM="mcr.microsoft.com"
LOCAL_REGISTRY="localhost:5000"

# probe_registry <base-url>: fast health gate -- 0 iff every base image
# still missing from the local store resolves a manifest there. A few-KB
# GET with a hard 30s cap, so a wedged endpoint is skipped in seconds
# instead of consuming a full bounded-pull window; on zot the GET also
# triggers the onDemand sync ahead of the pull.
# --- REGION: Probe base image sources
probe_registry() {
    local base="$1" ref repo ver ns=""
    # --- REGION: https://yuruna.link/42e220c4-0009
    if [ -n "$CACHE_HOST" ]; then
        case "$base" in
            *"${CACHE_HOST}:5000") ns="?ns=${BASE_IMAGES_UPSTREAM}" ;;
        esac
    fi
    for ref in "${BASE_IMAGES[@]}"; do
        find_local_image "$ref" >/dev/null && continue
        repo="${ref%:*}"; ver="${ref#*:}"
        if ! curl -sf -o /dev/null --max-time 30 -H "$ACCEPT_HDR" \
                "${base}/v2/${repo}/manifests/${ver}${ns}"; then
            return 1
        fi
    done
    return 0
}

# All BASE_IMAGES present in the local store?
all_base_images_local() {
    local ref
    for ref in "${BASE_IMAGES[@]}"; do
        find_local_image "$ref" >/dev/null || return 1
    done
    return 0
}

# Acquire images missing from the local store. Candidates in priority
# order: the zot pull-through cache (LAN, absorbs upstream TLS jitter),
# then mcr.microsoft.com as the survival path when the cache VM is
# absent or cannot serve the tag. Each candidate is probe-gated first;
# the pull itself is stall-bounded (PULL_STALL, set above) as a backstop
# for mid-stream wedges.
# --- REGION: Acquire base images
acquire_rounds=2
acquire_delay=10
stalled_candidates=""
# The cache joins the candidate list only when this lab has one. Left in
# unconditionally it expands to http://:5000, an address that belongs to no
# host: every round would spend a probe on it and report it as unusable, which
# reads as a cache that is down rather than a lab that never had one.
base_image_candidates=()
if [ -n "$CACHE_HOST" ]; then
    base_image_candidates+=("http://${CACHE_HOST}:5000|${CACHE_HOST}:5000/")
fi
base_image_candidates+=("https://${BASE_IMAGES_UPSTREAM}|${BASE_IMAGES_UPSTREAM}/")
for round in $(seq 1 "$acquire_rounds"); do
    if all_base_images_local; then
        break
    fi
    for candidate in "${base_image_candidates[@]}"; do
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
        if [ -n "$CACHE_HOST" ]; then
            echo "       nor acquirable from the cache (${CACHE_HOST}:5000) or" >&2
            echo "       ${BASE_IMAGES_UPSTREAM}. Check network egress and the cache" >&2
            echo "       VM's /etc/zot/config.json." >&2
        else
            echo "       nor acquirable from ${BASE_IMAGES_UPSTREAM}, which is the only" >&2
            echo "       source in a lab with no caching proxy. Check the guest's" >&2
            echo "       network egress." >&2
        fi
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

# --- REGION: Build application
echo ""
echo -e "\e[1;36m==== Build .NET app ====\e[0m"
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

# --- REGION: Push application image
echo ""
echo -e "\e[1;36m==== Push to docker registry ====\e[0m"
docker tag website/website:latest "${LOCAL_REGISTRY}/website/website:latest"
if ! run_bounded 300 docker push "${LOCAL_REGISTRY}/website/website:latest"; then
    echo "ERROR: pushing website/website into ${LOCAL_REGISTRY} failed -- the local" >&2
    echo "       registry container is down or wedged (docker ps; docker logs registry)." >&2
    exit 1
fi

# --- REGION: https://yuruna.link/42a76c30-000c
# Prune build caches before the cluster deploys so kubelet's ephemeral-
# storage watermark is not tripped.
# Failure here is non-fatal: we only care about the side effect.
docker buildx prune --all --force >/dev/null 2>&1 || true
docker builder prune --all --force >/dev/null 2>&1 || true
docker image prune --force >/dev/null 2>&1 || true

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
