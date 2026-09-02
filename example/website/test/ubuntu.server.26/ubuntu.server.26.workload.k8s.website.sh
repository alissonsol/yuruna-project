#!/bin/bash
# Version: 2026.09.01
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

mkcert -install 2>/dev/null || true

# --- REGION: Bounded command execution
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

# --- REGION: https://yuruna.link/caching#workload-registry-pull-through
# A caching proxy is an optimization, not a prerequisite: a lab can run without
# one, and a lab that had one can lose it between cycles. An empty CACHE_HOST is
# therefore a supported topology rather than a fault, and every cache-addressed
# step below is gated on this one variable.
#
# The bare service name is adopted only once something answers on it. A lab
# whose resolver publishes that name and a lab with no cache at all are told
# apart by nothing else, so taking the name on faith converts "no cache here"
# into "could not resolve host" -- which reads as a broken proxy VM and sends
# the reader after a machine that was never meant to exist, after the step has
# spent its whole retry budget first.
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

# Hard elapsed-time cap on a single pull -- a backstop for mid-stream
# wedges, not a progress check. It has to out-wait the cache's slowest
# HONEST answer rather than a typical one: revalidating a mutable tag
# against a throttled upstream costs tens of seconds routinely and minutes
# at the tail, and with no upstream to fall back to, a cap set below that
# tail would only trade one failure mode for another. A capped attempt is
# still not wasted -- the cache finishes the sync in the background, so the
# retry behind it usually lands warm. Raise YURUNA_PULL_STALL_TIMEOUT on
# links slower than ~1 MB/s.
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
# warm_manifest <repo> <tag>: drive the cache's on-demand sync of one tag to
# completion so the pull that follows resolves a manifest already in hand.
#
# A cold tag cannot be pulled straight from the cache however patient the
# caller is. dockerd abandons a request whose RESPONSE HEADERS have not
# arrived within its own fixed patience, and the cache emits none until the
# sync it triggered finishes -- a cold multi-arch tag routinely costs
# several times that ceiling. The ceiling is dockerd's, not ours: bounding
# the pull more generously (PULL_STALL above) cannot raise it, so the pull
# can only ever time out. curl carries no such ceiling, so it can hold the
# same request open until the sync lands and leave the tag warm.
#
# Advisory by design. A cache that never warms fails exactly as it would
# have without this, through the pull below and with the pull's own message
# attached -- so this adds a way to succeed, never a new way to fail.
warm_manifest() {
    local repo="$1" tag="$2" probe code elapsed
    # The warm-up exists to hold a request open against a cache that is still
    # syncing. With no cache in this lab there is nothing to warm and no
    # address to address it by, and the pull behind this goes straight to the
    # upstream.
    [ -n "$CACHE_HOST" ] || return 0
    echo "Warming ${CACHE_HOST}:5000/${repo}:${tag} (up to ${PULL_STALL}s)"
    # The status code and the elapsed time are asked for explicitly because a
    # warm-up that did not land has two meanings, and they send the operator
    # to different places: a cache that ANSWERED and refused points at the
    # upstream it proxies, a cache that never answered inside the cap points
    # at a sync still running. `curl -f` collapses both into one silent
    # non-zero status, so the write-out carries them instead; the body stays
    # discarded, since the manifest is wanted in the cache and not here.
    # curl emits the write-out even when the transfer fails, and `|| true`
    # keeps that failure from aborting the script under `set -e`.
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

# --- REGION: https://yuruna.link/caching#workload-registry-pull-through
# Start Docker registry if not running.
# The image is taken from the local docker store first and otherwise from
# the zot pull-through cache ADDRESSED BY NAME -- never as a bare
# `registry:2`. A bare tag is a docker.io reference: dockerd consults its
# registry-mirrors entry, but abandons the mirror once it is slower than
# dockerd's own patience and finishes the pull against docker.io directly,
# where the lab's shared egress IP is rate limited -- so a healthy, fully
# warm cache still ends in a 429. Revalidating a mutable upstream tag on an
# anonymous pull-through routinely costs minutes, which makes that fallback
# the common path rather than a rare one. An explicit <cache>:5000/... pull
# has no upstream to fall back to, so a slow cache stays a slow pull instead
# of turning into a hard failure. Acquiring the image as its own step (not
# as an implicit `docker run` pull) keeps the registry's own message
# attached to the attempt that failed, and each attempt is stall-bounded so
# a wedged pull becomes a retry rather than a hang.
REGISTRY_IMAGE="registry:2"
# Docker Hub's official images live under the library/ namespace. Only the
# docker.io mirror protocol lets that prefix be elided, so a pull addressed
# straight at zot has to spell it out.
#
# Without a cache the pull uses the bare tag instead. The explicit form above
# exists to deny dockerd the mirror it would otherwise abandon mid-pull, and a
# lab with no cache has no mirror configured for it to abandon -- so the bare
# tag is a plain docker.io pull, which is the only source such a lab has.
if [ -n "$CACHE_HOST" ]; then
    REGISTRY_PULL_REF="${CACHE_HOST}:5000/library/registry:2"
else
    REGISTRY_PULL_REF="$REGISTRY_IMAGE"
fi
# --- REGION: https://yuruna.link/caching#workload-registry-pull-through
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
        # on the progress the sync behind the attempt before it made: it is
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
    # A source that cannot be reached is terminal once the ladder above has been
    # spent, and only then: an unreachable cache and a cache that is being
    # replaced are the same bytes on the wire, and the second one comes back on
    # its own, so failing out on the first attempt turns every rebuild that
    # overlaps a run into a dead run.
    #
    # Which source went missing decides the wording, and getting that wrong
    # costs the reader the whole diagnosis. With a cache, the pull had no
    # upstream to fall back to and the cache is what to check. Without one, the
    # upstream WAS the source, and naming a cache would send the reader after a
    # machine this lab never had.
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
    # A cache that ANSWERS but not in time fails with none of the words above:
    # the connection is established, the request is sent, and the runtime gives
    # up waiting for response headers. Left unnamed it reads as a generic pull
    # failure and sends the next reader to the guest's network stack, which is
    # working perfectly. Not terminal -- unlike an unreachable cache, this one
    # often lands on a retry, because the sync the timed-out attempt started
    # keeps running and the tag is warm by the time the next attempt arrives.
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
    # --- REGION: https://yuruna.link/network#defining-registry-rate-limit-400
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

echo ""
echo -e "\e[1;36m==== Set-Resource ====\e[0m"
cd "$REAL_HOME/yuruna/project/example"
pwsh ../../automation/Set-Resource.ps1 website localhost

CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/project/example/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

echo ""
echo -e "\e[1;36m==== Base images ====\e[0m"
# --- REGION: https://yuruna.link/caching#workload-registry-local-first
# The build must not resolve FROM metadata over the network: buildkit's
# `load metadata` runs inside a single `docker build` invocation, so a
# stalled remote registry wedges the build where no retry loop can
# reach it. Base images are taken from the local docker store first
# (pulled into it only when missing), seeded into the localhost:5000
# registry container started above, and the build then pulls FROM the
# loopback registry only.
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
probe_registry() {
    local base="$1" ref repo ver ns=""
    # ns= names the upstream this repository belongs to -- the same parameter
    # containerd's hosts.toml form sends on every pull, and how the cache picks
    # which upstream to sync from. Without it the cache walks its configured
    # registries in order, where Docker Hub is the catch-all, and spends one of
    # the metered lookups the whole lab shares on an image Docker Hub never
    # served. Only the cache reads it, so a probe addressed at the upstream
    # itself carries none.
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

echo ""
echo -e "\e[1;36m==== Push to docker registry ====\e[0m"
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
echo ""
echo -e "\e[1;36m==== Set-Component ====\e[0m"
pwsh ../../automation/Set-Component.ps1 website localhost
echo ""
echo -e "\e[1;36m==== Set-Workload ====\e[0m"
pwsh ../../automation/Set-Workload.ps1 website localhost

echo ""
echo -e "\e[1;36m==== Wait for readiness ====\e[0m"
# --- REGION: https://yuruna.link/kubernetes#why-the-website-readiness-check-waits-on-deployment-availability-not-endpoints
# These waits run HERE rather than in the sequence step that follows,
# because that step is TYPED into the guest console one RFB key event
# per character. Inlining them made the typed line 557 characters, and
# sends that long have corrupted mid-flight on macos.utm -- dropped
# characters, then a key left held down auto-repeating into the
# console. Keeping the typed command short keeps it well inside the
# length the console path handles reliably.
kubectl wait --for=condition=available deployment/website -n website --timeout=240s
kubectl wait --for=condition=available deployment/nginx-ingress-ingress-nginx-controller -n ingress-ns --timeout=240s
