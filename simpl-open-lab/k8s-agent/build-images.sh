#!/usr/bin/env bash
# build-images.sh [name...] — build the authority-iaa agent's Simpl images from source at the release
# tags the official charts pin, with each project's own Dockerfile, and import them into the
# ../k8s-gvisor cluster's containerd. code.europa.eu:4567 (the official registry) is not reachable
# from this sandbox, so this replaces the pull. Images keep their official names.
#
# One image at a time, cleaning up behind it: in a ~40 GB sandbox the front-end builds alone need a
# 3–4 GB yarn cache plus ~1.4 GB of node_modules each.
#
# images.txt: "<gitlab project path> <version>" per line; sources are cloned into $B/src/<basename>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="${B:-/root/simpl-agent-build}"; C=k3s-gvisor
mkdir -p "$B/src" "$B/logs"

build_one() {
  local path=$1 tag=$2 n d L img t0
  n=$(basename "$path"); d="$B/src/$n"; L="$B/logs/$n.log"; img="code.europa.eu:4567/$path:$tag"; t0=$(date +%s)
  [ -d "$d" ] || git clone -q --depth 1 --branch "v$tag" "https://code.europa.eu/$path.git" "$d" >"$L" 2>&1 \
    || { echo "$n: clone FAILED"; return 1; }
  if [ -f "$d/pom.xml" ]; then
    # the compile step the projects' CI runs before `docker build`
    ( cd "$d" && env -u JAVA_TOOL_OPTIONS -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy PROJECT_RELEASE_VERSION="$tag" mvn -B -ntp -DskipTests \
        -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true -Dcheckstyle.skip=true \
        -Dmaven.javadoc.skip=true -Djacoco.skip=true clean package ) >"$L" 2>&1 || { echo "$n: maven FAILED ($L)"; return 1; }
  elif [ -f "$d/package.json" ]; then
    # CI uses yarn (pipeline.variables.sh: JS_PACKAGE_MANAGER=yarn); there is no lockfile, and npm's
    # strict peer-dependency resolution rejects the tree (ERESOLVE) where yarn 1 only warns.
    # registry.npmjs.org is reached directly; registry.yarnpkg.com (yarn's default) goes through the
    # sandbox egress proxy, which drops long transfers
    ( cd "$d" && export YARN_REGISTRY=https://registry.npmjs.org && yarn cache clean && rm -rf node_modules && yarn install --non-interactive --network-timeout 600000 && yarn build ) >"$L" 2>&1 \
      || { echo "$n: yarn FAILED ($L)"; return 1; }
  fi
  local df=Dockerfile
  if [ "$n" = ejbca-preconfig ]; then
    # the kubectl the Dockerfile downloads (the *latest* stable release): dl.k8s.io is not reliably reachable through the sandbox
    # proxy, so take the binary from the ejbca-preconfig image already in the cluster when there is one
    if [ -n "${EJBCA_BASE:-}" ] && docker exec $C ctr -n k8s.io run --rm "$img" kcopy cat /bin/kubectl > "$d/kubectl" 2>/dev/null \
        && [ -s "$d/kubectl" ]; then :
    else
      curl -fsSL -o "$d/kubectl" "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
        || { echo "$n: kubectl download FAILED"; return 1; }
    fi
    sed -e 's#^RUN curl -LO .*#COPY kubectl kubectl#' "$d/Dockerfile" > "$d/Dockerfile.lab"; df=Dockerfile.lab
    # EJBCA_BASE=<keyfactor/ejbca-ce tag>: the same set-up on another EJBCA release (EJBCA.md),
    # tagged <version>-ejbca<release> so the official pair stays in the cluster
    if [ -n "${EJBCA_BASE:-}" ]; then
      sed -i "s#^FROM keyfactor/ejbca-ce:.*#FROM keyfactor/ejbca-ce:${EJBCA_BASE}#" "$d/Dockerfile.lab"
      docker image inspect "keyfactor/ejbca-ce:${EJBCA_BASE}" >/dev/null 2>&1 || {
        docker pull -q "mirror.gcr.io/keyfactor/ejbca-ce:${EJBCA_BASE}" >/dev/null &&
        docker tag "mirror.gcr.io/keyfactor/ejbca-ce:${EJBCA_BASE}" "keyfactor/ejbca-ce:${EJBCA_BASE}"; }
      img="$img-ejbca${EJBCA_BASE}"
    fi
  fi
  if [ "${LEAN:-0}" = 1 ] && [ -f "$d/pom.xml" ]; then
    # FOOTPRINT.md: the same vendor and Java version as a runtime-only image, and the jar copied with
    # its owner instead of `COPY` + `RUN chown` (which stores it twice). Corretto publishes no JRE
    # image, so tier2-proxy keeps its base and only gets the chown fix.
    sed -E -e 's#^FROM eclipse-temurin:([0-9]+)-jdk-alpine#FROM eclipse-temurin:\1-jre-alpine#' \
           -e 's#^COPY (target/[^ ]+) app.jar#COPY --chown=1001 \1 app.jar#' \
           -e '/^RUN chown 1001 \/app.jar$/d' "$d/$df" > "$d/Dockerfile.lean"; df=Dockerfile.lean
  fi
  docker build --network host --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}" -f "$d/$df" -t "$img" "$d" >>"$L" 2>&1 \
    || { echo "$n: docker build FAILED ($L)"; return 1; }
  local size; size=$(docker image inspect -f '{{.Size}}' "$img" | awk '{printf "%d MB", $1/1048576}')
  docker save --platform linux/amd64 "$img" | docker exec -i $C ctr -n k8s.io images import --platform linux/amd64 - >>"$L" 2>&1 \
    || { echo "$n: import FAILED ($L)"; return 1; }
  docker rmi "$img" >/dev/null
  rm -rf "${d:?}/node_modules" "${d:?}/target" "${d:?}/dist"
  [ -f "$d/package.json" ] && yarn cache clean >/dev/null 2>&1
  docker builder prune -af >/dev/null   # BuildKit keeps every layer it built (10 GB after a full run)
  echo "$n:$tag OK in $(( $(date +%s) - t0 ))s ($size)"
}

if [ $# -gt 0 ]; then pat=$(printf '/%s |' "$@"); grep -E "${pat%|}" "$HERE/images.txt"; else cat "$HERE/images.txt"; fi |
  while read -r p t; do build_one "$p" "$t"; done
