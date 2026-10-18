#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Shared local registry and image build operations; callers own deployment.
# --- REGION: example_registry_prepare
example_registry_prepare() {
# --- REGION: run_bounded
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
CACHE_HOST=$(printf '%s\n' "${http_proxy:-}" | sed -nE 's|^[hH][tT][tT][pP][sS]?://([^:/]+).*|\1|p')
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

# Request both manifests and indexes so multi-architecture tags resolve correctly.
ACCEPT_HDR='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# --- REGION: find_local_image
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

# --- REGION: warm_manifest
# See https://yuruna.link/42e220c4-0009
warm_manifest() {
    local repo="$1" tag="$2" probe code elapsed
    # Direct labs have no cache to warm; the pull goes straight upstream.
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
            # See https://yuruna.link/42010605-0005
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
# Wait through a cache VM restart: 10+20+40+80 allows 150 seconds for zot to return.
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
        # See https://yuruna.link/42010605-0005
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
            # docker's error text reads the same for a guest that lost its own
            # address and for a cache that is down; the engine's network library,
            # where the guest image carries it, names which one this guest sees.
            if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
                # shellcheck disable=SC1091
                . /usr/local/lib/yuruna/yuruna-network.sh
            fi
            if command -v yuruna_net_tcp_verdict >/dev/null 2>&1; then
                echo "       This guest's view of the path: $(yuruna_net_tcp_verdict "$CACHE_HOST" 5000 2>/dev/null || true)" >&2
            fi
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

}

# --- REGION: example_build_and_push
example_build_and_push() {
    local example_name="$1" component_name="$2"
# --- REGION: Seed base images
# See https://yuruna.link/42f6b05f-001a
# See https://yuruna.link/42e220c4-0009
echo ""
echo -e "\e[1;36m==== Base images ====\e[0m"
cd "$REAL_HOME/yuruna/project/example/${example_name}/components/frontend/${component_name}" || return 1
# The deployment creates a throwaway certificate Secret without a developer PFX.
# See https://yuruna.link/42f64340-0004
export YURUNA_EXAMPLE_SELF_SIGNED_CERT=1

# The list mirrors the Dockerfile's FROM lines.
BASE_IMAGES=("dotnet/sdk:10.0" "dotnet/aspnet:10.0")
# The upstream that serves them, named to the cache by the probe below.
BASE_IMAGES_UPSTREAM="mcr.microsoft.com"
LOCAL_REGISTRY="localhost:5000"

# Probe missing manifests with a 30-second cap; on zot, the GET also starts sync.
# See https://yuruna.link/42e220c4-0010
# --- REGION: probe_registry
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

# --- REGION: all_base_images_local
all_base_images_local() {
    local ref
    for ref in "${BASE_IMAGES[@]}"; do
        find_local_image "$ref" >/dev/null || return 1
    done
    return 0
}

# --- REGION: Acquire base images
# See https://yuruna.link/42010605-0005
acquire_rounds=2
acquire_delay=10
stalled_candidates=""
# An unconfigured cache is not a failed endpoint: only probe real candidates.
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
# Local FROM resolution avoids remote metadata stalls; retries cover RUN package restores.
# See https://yuruna.link/42e220c4-0010
build_attempts=3
build_delay=10
for attempt in $(seq 1 "$build_attempts"); do
    if run_bounded 600 docker build --progress=plain --rm \
            --build-arg DEV=1 \
            --build-arg "REGISTRY=${REGISTRY}" \
            -f Dockerfile -t "${example_name}/${component_name}:latest" .; then
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
docker tag "${example_name}/${component_name}:latest" "${LOCAL_REGISTRY}/${example_name}/${component_name}:latest"
if ! run_bounded 300 docker push "${LOCAL_REGISTRY}/${example_name}/${component_name}:latest"; then
    echo "ERROR: pushing ${example_name}/${component_name} into ${LOCAL_REGISTRY} failed -- the local" >&2
    echo "       registry container is down or wedged (docker ps; docker logs registry)." >&2
    exit 1
fi

example_prune_build_cache

}

# --- REGION: example_prune_build_cache
# See https://yuruna.link/42a76c30-000c
# Prune only after the sole image publisher finishes, before kubelet checks its
# ephemeral-storage watermark. Cleanup is best effort and independently bounded.
example_prune_build_cache() {
    run_bounded 60 docker buildx prune --all --force >/dev/null 2>&1 || true
    run_bounded 60 docker builder prune --all --force >/dev/null 2>&1 || true
    run_bounded 60 docker image prune --force >/dev/null 2>&1 || true
}
