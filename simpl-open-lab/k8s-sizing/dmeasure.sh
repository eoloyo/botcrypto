#!/usr/bin/env bash
# dmeasure.sh <label> <image> [docker run resource flags...]
# Same image + official application.yml/env as the Kubernetes pod, on plain Docker (runc enforces
# --cpus/--memory). Reports wall time to "Started", container CPU-seconds and memory (cgroup v1).
S="$(cd "$(dirname "$0")" && pwd)"   # application.yml, ks.p12, ts.jks are generated next to this script
LABEL=$1; IMG=$2; shift 2
docker rm -f ipm >/dev/null 2>&1
t0=$(date +%s.%N)
docker run -d --name ipm --network simpl-lab -p 127.0.0.1:18103:8080 "$@" \
  -v $S/application.yml:/config/application.yml:ro -v $S/ks.p12:/etc/certs/keystore.p12:ro -v $S/ts.jks:/etc/certs/truststore.jks:ro \
  -e SPRING_DATASOURCE_PASSWORD=identityprovider -e SPRING_DATA_REDIS_PASSWORD=admin \
  -e SPRING_SSL_BUNDLE_JKS_EJBCA_KEYSTORE_PASSWORD=labpass -e LOGGING_LEVEL_EU_EUROPA_EC_SIMPL=INFO \
  "$IMG" >/dev/null
ready=""
for _ in $(seq 1 1200); do
  # the official readiness probe's endpoint (upstream logs "Started ..." also for its nested Liquibase apps)
  [ "$(curl -s -m1 -o /dev/null -w '%{http_code}' http://127.0.0.1:18103/actuator/health/readiness)" = 200 ] && { ready=$(date +%s.%N); break; }
  [ "$(docker inspect -f '{{.State.Running}}' ipm 2>/dev/null)" = true ] || { echo "[$LABEL] container exited"; docker logs ipm 2>&1 | grep -E "Caused by|run failed" | head -3 | cut -c1-200; break; }
  sleep 0.25
done
sleep 5   # let start-up settle before reading memory
id=$(docker inspect -f '{{.Id}}' ipm)
cg=$(ls -d /sys/fs/cgroup/cpuacct/docker/$id 2>/dev/null || ls -d /sys/fs/cgroup/cpu,cpuacct/docker/$id 2>/dev/null)
cpu=$(cat $cg/cpuacct.usage 2>/dev/null)
mg=/sys/fs/cgroup/memory/docker/$id
use=$(cat $mg/memory.usage_in_bytes 2>/dev/null); inact=$(awk '/^total_inactive_file /{print $2}' $mg/memory.stat 2>/dev/null)
app="nested Spring apps started: $(( $(docker logs ipm 2>&1 | grep -c 'Started IdentityProviderApplication') - 1 ))"
python3 - "$LABEL" "$t0" "${ready:-0}" "${cpu:-0}" "${use:-0}" "${inact:-0}" "$app" <<'EOF'
import sys
l, t0, r, cpu, use, ina, app = sys.argv[1:8]
print(f"[{l}] ready {float(r)-float(t0):.1f}s after docker run | CPU {int(cpu)/1e9:.1f}s | working set {(int(use)-int(ina))//2**20} MB | {app}")
EOF
