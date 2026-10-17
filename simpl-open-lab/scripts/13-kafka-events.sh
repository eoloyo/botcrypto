#!/usr/bin/env bash
# 13-kafka-events.sh — verify Simpl's IAA event flows when a broker is running.
#
# Without a broker the lab works but compensates: the credential-installed event is lost
# (the install API then answers 500 even though the credential was saved), and the
# gateway only learns about a new identity because 07 restarts it. With a broker
# (SIMPL_BROKER=kafka ./07-tier2-provider-publish.sh) the events flow as in production.
# This test proves that:
#   A. a participant credential install succeeds (2xx — the post-commit Kafka publish works)
#   B. the event is on the participant agent's own topic (iaa.iaa-local-consumer. prefix)
#   C. the participant's identity-attributes event is published too
#   D. a new Governance-Authority credential reaches the RUNNING gateway as an event: the
#      gateway logs the cache invalidation and keeps serving — no restart (same PID)
# Exits non-zero on any FAIL.
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; HERE="$(cd "$(dirname "$0")" && pwd)"
K="$LAB_ROOT/kafka/bin"; MESH="$RUN/mesh.log"
PASS=0; FAIL=0
ok(){  printf '  \033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
CRED_T="eu.europa.ec.simpl.authenticationprovider.events.credential.updated"
ATTR_T="eu.europa.ec.simpl.authenticationprovider.events.identity-attributes.updated"
# count the messages currently on a topic (from the beginning)
count(){ env -u JAVA_TOOL_OPTIONS "$K/kafka-console-consumer.sh" --bootstrap-server localhost:9092 \
           --topic "$1" --from-beginning --timeout-ms 6000 2>/dev/null | grep -c . || true; }

(exec 3<>/dev/tcp/127.0.0.1/9092) 2>/dev/null && exec 3>&- \
  || { log "no broker on :9092 — run: ./99-stop.sh && SIMPL_BROKER=kafka ./07-tier2-provider-publish.sh"; exit 1; }
curl -s -m 5 -o /dev/null http://localhost:8104/actuator/health \
  || { log "mesh not up — run SIMPL_BROKER=kafka ./07-tier2-provider-publish.sh first"; exit 1; }
[ -x "$K/kafka-console-consumer.sh" ] || { log "Kafka CLI not found under $K"; exit 1; }

echo
log "══ A. participant credential install succeeds (2xx; was 500 without a broker) ══"
C0=$(count "iaa.iaa-local-consumer.$CRED_T")
OUT=$(bash "$HERE/../iaa/enroll.sh" 8104 "Kafka Probe $$" false | tail -1)
case "$OUT" in
  *"install 2"[0-9][0-9]*) ok "credential install returned $(grep -oE 'install [0-9]+' <<<"$OUT" | cut -d' ' -f2)" ;;
  *)               bad "credential install did not succeed: $(grep -oE 'install [0-9]+' <<<"$OUT")" ;;
esac

echo
log "══ B. the event landed on the participant agent's own topic ══"
C1=$(count "iaa.iaa-local-consumer.$CRED_T")
if [ "$C1" -gt "$C0" ]; then ok "iaa.iaa-local-consumer.…credential.updated: $C0 -> $C1 event(s)"
else bad "no new event on iaa.iaa-local-consumer.…credential.updated ($C0 -> $C1)"; fi

echo
log "══ C. identity-attributes events are published ══"
A=$(count "iaa.iaa-local-consumer.$ATTR_T")
if [ "$A" -gt 0 ]; then ok "iaa.iaa-local-consumer.…identity-attributes.updated has $A event(s)"
else bad "no identity-attributes event on the participant topic"; fi

echo
log "══ D. a new GA credential reaches the running gateway as an event (no restart) ══"
GWPID=$(pgrep -f "tier2-gateway.*local\.jar|$NATIVE_DIR/bin/tier2-gateway" | head -1 || true)
[ -n "$GWPID" ] || { bad "gateway not running"; GWPID=none; }
MARK=$(wc -l < "$MESH")
bash "$HERE/../iaa/enroll.sh" 8105 "Local Authority" true | tail -1 | grep -oE "install [0-9]+" | sed 's/^/   GA /'
GOT=0
for _ in $(seq 1 20); do
  tail -n +"$((MARK+1))" "$MESH" | grep -q "Received credential updated event, invalidating credential cache" && { GOT=1; break; }
  sleep 1
done
NOWPID=$(pgrep -f "tier2-gateway.*local\.jar|$NATIVE_DIR/bin/tier2-gateway" | head -1 || true)
[ "$GOT" = 1 ] && ok "gateway logged 'Received credential updated event, invalidating credential cache'" \
               || bad "gateway did not receive the credential-updated event within 20s"
[ "$GWPID" = "$NOWPID" ] && ok "gateway kept running through the identity change (PID $GWPID, no restart)" \
                         || bad "gateway PID changed ($GWPID -> $NOWPID)"

echo
log "══ kafka event flows: $PASS passed, $FAIL failed ══"
[ "$FAIL" -eq 0 ]
