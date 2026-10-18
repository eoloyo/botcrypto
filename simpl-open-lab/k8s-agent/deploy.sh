#!/usr/bin/env bash
# deploy.sh — deploy the official Governance Authority identity agent (authority-iaa) on the
# ../k8s-gvisor cluster and record how long each pod takes to become Ready.
#
#   RENDERED=<dir with out-*.yaml from ../k8s-sizing/render_apps.py> ./deploy.sh
#
# The Simpl images must be in the local Docker daemon, tagged as the charts reference them
# (code.europa.eu:4567/<project>:<version>), see build-images.sh. Lab secrets are generated once into
# $WORK/secrets.json (outside the repository).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/root/simpl-agent-build/deploy}"
RENDERED="${RENDERED:?set RENDERED to the directory holding the rendered out-*.yaml}"
SPI_DIR="${SPI_DIR:-/root/simpl-agent-build/spi}"   # keycloak-authenticator.jar, keycloak-eidas-demo-authenticator.jar
C=k3s-gvisor
K() { docker exec -i $C kubectl "$@"; }
log() { echo "[$(date +%T)] $*"; }
mkdir -p "$WORK"
AGENT=("$RENDERED"/out-authority-iaa.yaml
  "$RENDERED"/out-{redis,keycloak,ejbca-community-helm,authentication-provider,identity-provider,onboarding,security-attributes-provider,users-roles,tier1-gateway,tier2-gateway,tier2-proxy}.yaml
  "$RENDERED"/out-fe-{authentication-provider,identity-provider,onboarding,security-attribute-provider,users-and-roles}.yaml)

# --- 1. lab secrets (what OpenBao holds in the official set-up) -------------------------------
if [ ! -f "$WORK/secrets.json" ]; then
  python3 - "$WORK/secrets.json" <<'EOF'
import json, secrets, sys
v = lambda: secrets.token_hex(16)
s = {}
for db in "authenticationprovider ejbca identityprovider keycloak onboarding securityattributesprovider usersroles".split():
    s[f"authority01-postgres-passwords#authority01-{db}"] = v()
for u in "authprovider onboarding tier2gw usersroles".split():
    s[f"common01-kafka-credentials#authority01_{u}"] = v()
s["authority01-ejbca#keystorepass"] = v()
s["authority01-keycloak#admin"] = v()
s["authority01-keycloak#onboarding_sa"] = v()
s["authority-client#cli"] = v(); s["authority-client#test-client"] = v()
s["onboarding-client#onboarding-sa"] = s["authority01-keycloak#onboarding_sa"]; s["onboarding-client#test-client"] = v()
s["lab#postgres"] = v(); s["lab#kafka-admin"] = v()
json.dump(s, open(sys.argv[1], "w"), indent=1)
EOF
  chmod 600 "$WORK/secrets.json"
fi

# --- 2. images into the cluster's containerd (one stream, shared layers sent once) -------------
mapfile -t IMAGES < <(grep -ohE '^\s+image:\s*"?[^" ]+' "${AGENT[@]}" | sed -E 's/.*image:\s*"?//' | sort -u)
IMAGES+=(postgres:16-alpine apache/kafka:3.8.1 alpine/kubectl:latest rancher/mirrored-library-busybox:1.36.1)   # lab: alpine:3.20 retagged (ECR quota)   # the Job puts its image on the next line
have=$(docker exec $C ctr -n k8s.io images ls -q)
missing=(); for i in "${IMAGES[@]}"; do
  ref=${i#docker.io/}; [[ ${ref##*/} == *:* ]] || ref=$ref:latest      # containerd's normalised name
  if [[ $ref != */* ]]; then ref=docker.io/library/$ref; elif [[ ${ref%%/*} != *[.:]* ]]; then ref=docker.io/$ref; fi
  grep -qxF "$ref" <<<"$have" && continue
  if docker image inspect "$i" >/dev/null 2>&1; then missing+=("$i"); else log "WARNING: $i is neither in the cluster nor in Docker"; fi
done
if [ ${#missing[@]} -gt 0 ]; then
  log "importing ${#missing[@]} images"
  docker save --platform linux/amd64 "${missing[@]}" | docker exec -i $C ctr -n k8s.io images import --platform linux/amd64 - | tail -1
fi

# --- 3. cluster plumbing --------------------------------------------------------------------
for d in coredns local-path-provisioner metrics-server; do   # runc cannot run pods in this sandbox
  K -n kube-system patch deploy $d --type merge -p '{"spec":{"template":{"spec":{"runtimeClassName":"runsc"}}}}' >/dev/null 2>&1 || true
done
# local-path's PVC helper pods are bare Pods from a ConfigMap template: give them gVisor too
K -n kube-system get cm local-path-config -o json | python3 -c '
import json, sys, yaml
cm = json.load(sys.stdin); pod = yaml.safe_load(cm["data"]["helperPod.yaml"])
pod["spec"]["runtimeClassName"] = "runsc"; cm["data"]["helperPod.yaml"] = yaml.safe_dump(pod)
json.dump(cm, sys.stdout)' | K apply -f - >/dev/null
docker exec $C mkdir -p /var/lib/simpl-spi
docker cp "$SPI_DIR/keycloak-authenticator.jar" $C:/var/lib/simpl-spi/
docker cp "$SPI_DIR/keycloak-eidas-demo-authenticator.jar" $C:/var/lib/simpl-spi/

# --- 4. common components -------------------------------------------------------------------
python3 - "$WORK/secrets.json" "$WORK/lab-secrets.env" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1])); out = open(sys.argv[2], "w")
for k, v in s.items():
    if k.startswith("authority01-postgres-passwords#"): out.write(f"{k.split('#')[1]}={v}\n")
    elif k.startswith("common01-kafka-credentials#authority01_"): out.write(f"kafka-{k.split('_', 1)[1]}={v}\n")
out.write(f"postgres={s['lab#postgres']}\nkafka-admin={s['lab#kafka-admin']}\n")
EOF
if [ "${FRESH:-1}" = 1 ]; then
  log "removing any previous agent and resetting Postgres/Kafka"
  K delete ns authority01 --ignore-not-found --wait=true --timeout=300s >/dev/null || true
  K -n common01 delete pod --all --wait=true >/dev/null 2>&1 || true
fi
K apply -f - < "$HERE/common.yaml" >/dev/null
docker cp "$WORK/lab-secrets.env" $C:/tmp/lab-secrets.env
K -n common01 create secret generic lab-secrets --from-env-file=/tmp/lab-secrets.env --dry-run=client -o yaml | K apply -f - >/dev/null
docker exec $C rm -f /tmp/lab-secrets.env
K -n common01 rollout status deploy/pg-cluster --timeout=300s
K -n common01 rollout status deploy/kafka --timeout=300s

[ "${COMMON_ONLY:-0}" = 1 ] && exit 0

# --- 5. the agent ---------------------------------------------------------------------------
python3 "$HERE/post-render.py" "$WORK/secrets.json" "${AGENT[@]}" > "$WORK/agent.yaml"
log "applying $(grep -c '^kind:' "$WORK/agent.yaml") objects"
t0=$(date +%s)
K apply -f - < "$WORK/agent.yaml" 2>&1 | grep -vE 'created|configured|unchanged' || true

# --- 6. timeline: seconds from apply until each pod is Ready ----------------------------------
: > "$WORK/timeline.tsv"
declare -A seen
deadline=$(( t0 + ${TIMEOUT:-2400} ))
while [ "$(date +%s)" -lt $deadline ]; do
  while read -r name ready status restarts; do
    [ -n "${seen[$name]:-}" ] && continue
    if [ "${ready%/*}" = "${ready#*/}" ] && [ "$status" = Running ]; then
      seen[$name]=1; printf '%s\t%d\t%s\n' "$name" $(( $(date +%s) - t0 )) "$restarts" | tee -a "$WORK/timeline.tsv"
    fi
  done < <(K -n authority01 get pods --no-headers 2>/dev/null | awk '$3!="Completed"{print $1, $2, $3, $4}')
  notready=$(K -n authority01 get pods --no-headers 2>/dev/null | awk '$3!="Completed"{split($2,a,"/"); if(a[1]!=a[2]||$3!="Running") n++} END{print n+0}')
  [ "$notready" = 0 ] && [ ${#seen[@]} -gt 0 ] && break
  sleep 5
done
log "done after $(( $(date +%s) - t0 ))s; not ready:"
K -n authority01 get pods --no-headers | awk '{split($2,a,"/"); if(a[1]!=a[2]&&$3!="Completed") print}'
