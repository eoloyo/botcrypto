#!/usr/bin/env bash
# Build GraalVM native executables for the mesh services, for SIMPL_RUNTIME=native.
#
#   ./15-native-build.sh [name...]     default: all of them; output in $NATIVE_DIR/bin/<name>
#
# Prerequisite: a tracing-agent pass, so native-image knows what the services reach by reflection
# (Liquibase, Hibernate, Jackson models, Spring Cloud Gateway, ...). Collect it with
#   ./99-stop.sh --wipe && SIMPL_RUNTIME=agent ./07-tier2-provider-publish.sh && ./12-perimeter.sh
# (add the broker / 13 pass to cover the Kafka paths). The result accumulates in $NATIVE_DIR/agent.
#
# Spring AOT fixes the active profiles and the @Profile / @Conditional bean set at build time, so
# each image is built for the profile the lab runs it with; the authentication provider runs as
# the authority (GA) and as a participant, which have different beans, so it gets two images.
# One build peaks at ~8-9 GB RSS and ~4 CPU-minutes x 4 cores: images are built one at a time.
source "$(dirname "$0")/env.sh"; set +e
SRC="$LAB_ROOT/src"; LOGS="$NATIVE_DIR/logs"; mkdir -p "$NATIVE_DIR/bin" "$LOGS"
GRAAL_URL=https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-21.0.2/graalvm-community-jdk-21.0.2_linux-x64_bin.tar.gz
if [ ! -x "$GRAALVM_HOME/bin/native-image" ]; then
  log "downloading GraalVM CE 21.0.2 to $GRAALVM_HOME"
  mkdir -p "$GRAALVM_HOME" && curl -fsSL "$GRAAL_URL" | tar -xz --strip-components=1 -C "$GRAALVM_HOME" || exit 1
fi
# name | repo dir | AOT profiles
SPECS=(
  "identity-provider|identity-provider|local"
  "auth-provider-local-authority|authentication_provider|local-authority"
  "auth-provider-local-consumer|authentication_provider|local-consumer"
  "security-attributes-provider|security-attributes-provider|local"
  "tier2-gateway|tier2-gateway|local-authority"
  "sd-tooling-be|sd-tooling-be|default"
  "fc-service|catalogue-be|default"
)
want=("$@")
gmvn(){ env -u JAVA_TOOL_OPTIONS -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
  JAVA_HOME="$GRAALVM_HOME" GRAALVM_HOME="$GRAALVM_HOME" PATH="$GRAALVM_HOME/bin:$PATH" \
  mvn -B -ntp -DskipTests -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true \
  -Dcheckstyle.skip=true -Dmaven.javadoc.skip=true -Djacoco.skip=true "$@"; }
for spec in "${SPECS[@]}"; do
  IFS='|' read -r name repo profiles <<<"$spec"
  [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " == *" $name "* ]] && continue
  d="$SRC/$repo"; L="$LOGS/$name.log"; : > "$L"; t0=$(date +%s)
  log "native: $name ($repo, AOT profiles '$profiles') — log $L"
  # 1. Spring AOT for this profile (compiled into target/classes) + the reachability metadata
  #    repository (target/graalvm-reachability-metadata) for the third-party libraries
  aot=(); [ "$profiles" != default ] && aot=(-Dspring-boot.aot.profiles="$profiles")
  ( cd "$d" && gmvn -Pnative "${aot[@]}" package >>"$L" 2>&1 ) || { log "  AOT/package failed — see $L"; continue; }
  # The image gets exactly what the executable jar runs on the JVM: its BOOT-INF/classes (now with
  # the AOT classes) and BOOT-INF/lib, plus the jar root, where Boot moves META-INF/native-image
  # (main class + Spring's image flags). dependency:build-classpath returned test-only jars too.
  jar=$(ls "$d"/target/*.jar | grep -v -- '-plain\|\.original' | head -1); x="$d/target/native-x"
  rm -rf "$x" && mkdir -p "$x" && ( cd "$x" && unzip -q "$jar" ) || { log "  cannot unpack $jar"; continue; }
  # 2. configuration: reachability metadata + what the tracing agent recorded for this service.
  #    Hibernate on native must not find the ByteBuddy bytecode provider (Spring's own hints exclude
  #    it); the agent records its service file, which would bring it back, so drop that entry.
  agent="$NATIVE_DIR/agent/$name"
  [ -d "$agent" ] || log "  WARN: no tracing-agent config in $agent — the image will likely fail at runtime"
  [ -f "$agent/resource-config.json" ] && python3 -I - "$agent/resource-config.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); r = d.get("resources", {})
if isinstance(r, dict) and "includes" in r:
    r["includes"] = [i for i in r["includes"] if "org.hibernate.bytecode.spi.BytecodeProvider" not in i.get("pattern", "")]
json.dump(d, open(p, "w"), indent=2)
EOF
  cfg=$(find "$d/target/graalvm-reachability-metadata" -name '*.json' -printf '%h\n' 2>/dev/null | sort -u | paste -sd,)
  [ -d "$agent" ] && cfg="${cfg:+$cfg,}$agent"
  # 3. native-image. Spring AOT's native-image.properties supplies the main class and its flags.
  rm -f "$NATIVE_DIR/bin/$name"
  env -u JAVA_TOOL_OPTIONS JAVA_HOME="$GRAALVM_HOME" "$GRAALVM_HOME/bin/native-image" \
    -cp "$x:$x/BOOT-INF/classes:$(ls "$x"/BOOT-INF/lib/*.jar | paste -sd:)" --no-fallback -o "$NATIVE_DIR/bin/$name" \
    ${cfg:+-H:ConfigurationFileDirectories=$cfg} \
    --initialize-at-build-time=org.apache.commons.logging.LogFactory,org.apache.commons.logging.LogFactoryService \
    -H:+ReportExceptionStackTraces >>"$L" 2>&1
  if [ -x "$NATIVE_DIR/bin/$name" ]; then
    log "  OK $name: $(du -m "$NATIVE_DIR/bin/$name" | cut -f1) MB in $(( $(date +%s)-t0 ))s ($(grep -ao 'Peak RSS: [0-9.]*GB' "$L" | tail -1))"
  else
    log "  FAILED $name after $(( $(date +%s)-t0 ))s:"; grep -a "^Error" "$L" | head -3
  fi
done
