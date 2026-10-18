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
        -Dmaven.javadoc.skip=true -Djacoco.skip=true package ) >"$L" 2>&1 || { echo "$n: maven FAILED ($L)"; return 1; }
  elif [ -f "$d/package.json" ]; then
    # CI uses yarn (pipeline.variables.sh: JS_PACKAGE_MANAGER=yarn); there is no lockfile, and npm's
    # strict peer-dependency resolution rejects the tree (ERESOLVE) where yarn 1 only warns.
    ( cd "$d" && yarn install --non-interactive --network-timeout 600000 && yarn build ) >"$L" 2>&1 \
      || { echo "$n: yarn FAILED ($L)"; return 1; }
  fi
  local df=Dockerfile
  if [ "$n" = ejbca-preconfig ]; then
    # its Dockerfile downloads kubectl (the *latest* stable release) during the build: give that curl
    # the sandbox proxy and its CA
    cp /root/.ccr/ca-bundle.crt "$d/lab-ca.crt"
    sed -e 's#^RUN curl -LO .*#COPY lab-ca.crt /tmp/lab-ca.crt\nRUN curl --cacert /tmp/lab-ca.crt -fLO "https://dl.k8s.io/release/$(curl --cacert /tmp/lab-ca.crt -fsL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"#' \
      "$d/Dockerfile" > "$d/Dockerfile.lab"; df=Dockerfile.lab
  fi
  docker build --network host --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}" -f "$d/$df" -t "$img" "$d" >>"$L" 2>&1 \
    || { echo "$n: docker build FAILED ($L)"; return 1; }
  local size; size=$(docker image inspect -f '{{.Size}}' "$img" | awk '{printf "%d MB", $1/1048576}')
  docker save --platform linux/amd64 "$img" | docker exec -i $C ctr -n k8s.io images import --platform linux/amd64 - >>"$L" 2>&1 \
    || { echo "$n: import FAILED ($L)"; return 1; }
  docker rmi "$img" >/dev/null
  rm -rf "${d:?}/node_modules" "${d:?}/target" "${d:?}/dist"
  [ -f "$d/package.json" ] && yarn cache clean >/dev/null 2>&1
  echo "$n:$tag OK in $(( $(date +%s) - t0 ))s ($size)"
}

if [ $# -gt 0 ]; then pat=$(printf '/%s |' "$@"); grep -E "${pat%|}" "$HERE/images.txt"; else cat "$HERE/images.txt"; fi |
  while read -r p t; do build_one "$p" "$t"; done
