#!/usr/bin/env bash
# Bring up a Kafka-API message broker on localhost:9092 for the Simpl event flows
# (credential-lifecycle events + catalogue score-requests) and create the Simpl topics.
#
# PREFERS REDPANDA (small footprint: single binary, no JVM, no ZooKeeper/KRaft coordinator
# process) and falls back to a single-node Apache Kafka KRaft broker. The Simpl services
# speak the plain Kafka wire protocol (spring-kafka producers + @KafkaListener consumers),
# so either broker serves them identically — Redpanda is a drop-in.
#
# Usage:  bash iaa/broker.sh            # auto: Redpanda if runnable, else Kafka KRaft
#         SIMPL_BROKER=redpanda bash iaa/broker.sh
#         SIMPL_BROKER=kafka    bash iaa/broker.sh
#
# Then point the services at it:
#   --spring.kafka.bootstrap-servers=localhost:9092  --simpl.kafka.topic.prefix=
# (see iaa/KAFKA-REDPANDA.md for what each flow does and the exact per-service flags).
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
PORT=9092
up(){ (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; }
waitport(){ for _ in $(seq 1 40); do up && return 0; sleep 2; done; return 1; }

# Redpanda topics == the Simpl topic constants (eu.europa.ec.simpl.common.constants.Topics),
# with the default (empty) simpl.kafka.topic.prefix.
TOPICS=(
  "eu.europa.ec.simpl.authenticationprovider.events.credential.updated"
  "eu.europa.ec.simpl.authenticationprovider.events.identity-attributes.updated"
  "score-request"
)

if up; then log "broker already up on :$PORT"; exit 0; fi

MODE="${SIMPL_BROKER:-auto}"

start_redpanda(){
  # Needs the `redpanda` broker binary (rpk is only the CLI). rpk finds it via --install-dir
  # or a standard install (/opt/redpanda). On a normal box: `rpk` package + redpanda, or a
  # container. Returns non-zero if the broker binary isn't available so we can fall back.
  local RPK; RPK="$(command -v rpk || true)"
  [ -n "$RPK" ] || { log "rpk not on PATH — cannot start Redpanda"; return 1; }
  local args=(redpanda start --overprovisioned --smp 1 --memory 1G --reserve-memory 0M
              --node-id 0 --check=false
              --kafka-addr PLAINTEXT://0.0.0.0:$PORT
              --advertise-kafka-addr PLAINTEXT://localhost:$PORT)
  [ -n "${REDPANDA_INSTALL_DIR:-}" ] && args+=(--install-dir "$REDPANDA_INSTALL_DIR")
  log "starting Redpanda (rpk $RPK)"
  setsid env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
    "$RPK" "${args[@]}" </dev/null >"$RUN/redpanda.log" 2>&1 & disown
  waitport && { log "Redpanda up on :$PORT"; return 0; }
  log "Redpanda did not come up (see $RUN/redpanda.log)"; return 1
}

start_kafka(){
  local K="$LAB_ROOT/kafka" VER=3.9.1
  if [ ! -x "$K/bin/kafka-server-start.sh" ]; then
    log "downloading Apache Kafka $VER (KRaft)"
    curl -fsSL -o "$LAB_ROOT/kafka.tgz" "https://archive.apache.org/dist/kafka/$VER/kafka_2.13-$VER.tgz"
    tar xzf "$LAB_ROOT/kafka.tgz" -C "$LAB_ROOT" && mv "$LAB_ROOT/kafka_2.13-$VER" "$K" && rm -f "$LAB_ROOT/kafka.tgz"
  fi
  local CFG="$RUN/kraft-server.properties" LOGDIR="$LAB_ROOT/kafka-logs"
  cat > "$CFG" <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@localhost:9093
listeners=PLAINTEXT://localhost:$PORT,CONTROLLER://localhost:9093
inter.broker.listener.name=PLAINTEXT
advertised.listeners=PLAINTEXT://localhost:$PORT
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
log.dirs=$LOGDIR
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
num.partitions=1
EOF
  if [ ! -f "$LOGDIR/meta.properties" ]; then
    local UUID; UUID=$(JAVA_HOME="$JAVA_HOME" "$K/bin/kafka-storage.sh" random-uuid)
    JAVA_HOME="$JAVA_HOME" "$K/bin/kafka-storage.sh" format -t "$UUID" -c "$CFG" >/dev/null
  fi
  log "starting Apache Kafka KRaft (single node)"
  setsid env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy JAVA_HOME="$JAVA_HOME" \
    "$K/bin/kafka-server-start.sh" "$CFG" </dev/null >"$RUN/kafka.log" 2>&1 & disown
  waitport && { log "Kafka up on :$PORT"; return 0; }
  log "Kafka did not come up (see $RUN/kafka.log)"; return 1
}

case "$MODE" in
  redpanda) start_redpanda ;;
  kafka)    start_kafka ;;
  auto)     start_redpanda || { log "falling back to Apache Kafka KRaft"; start_kafka; } ;;
  *) log "unknown SIMPL_BROKER=$MODE (use redpanda|kafka|auto)"; exit 2 ;;
esac

# create the Simpl topics (rpk works as a client against Redpanda OR Kafka)
if RPK="$(command -v rpk || true)"; [ -n "$RPK" ]; then
  for t in "${TOPICS[@]}"; do "$RPK" -X brokers=localhost:$PORT topic create "$t" -p 1 -r 1 >/dev/null 2>&1 || true; done
  log "topics: $("$RPK" -X brokers=localhost:$PORT topic list 2>/dev/null | wc -l) present"
elif [ -x "$LAB_ROOT/kafka/bin/kafka-topics.sh" ]; then
  for t in "${TOPICS[@]}"; do
    JAVA_HOME="$JAVA_HOME" "$LAB_ROOT/kafka/bin/kafka-topics.sh" --create --if-not-exists \
      --topic "$t" --bootstrap-server localhost:$PORT --partitions 1 --replication-factor 1 >/dev/null 2>&1 || true
  done
fi
log "broker ready on :$PORT — Simpl event flows can now go live (see iaa/KAFKA-REDPANDA.md)"
