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
# STATUS (2026-10-17): all 7 images build. With SIMPL_RUNTIME=native the six IAA/publisher
# services boot (0.6-2.7 s each vs 4.8-11.5 s on the JVM; ~half the anonymous memory) and both
# enrolments succeed. Two open issues, so the default stays SIMPL_RUNTIME=jvm:
#   - sd-tooling-be: the gated publish returns 500 — NPE in OkHttpAuthenticationProviderAdapter.
#     getPrivateKey building the Tier-2 mTLS client (likely reflection/serialization of the
#     key exchange with the participant auth-provider; not yet diagnosed).
#   - fc-service: starts with SLF4J's NOP provider ("LoggerFactory is not a Logback
#     LoggerContext"); move its binary aside to run it on the JVM fallback.
#
# Spring AOT fixes the active profiles and the @Profile / @Conditional bean set at build time, so
# each image is built for the profile the lab runs it with; the authentication provider runs as
# the authority (GA) and as a participant, which have different beans, so it gets two images.
# The IAA services register BouncyCastle in main(). A native image only accepts provider instances
# it verified at build time, so BouncyCastle is listed in the build-time security configuration
# (security.provider.13): the image then contains that instance, main()'s addProvider is a no-op
# ("BC" already installed) and Security.getProvider("BC") returns the verified provider. Its classes
# are initialized at build time, except the two DRBG holders, whose SecureRandom must be seeded at run
# time (native-image refuses to build when a seeded Random ends up in the image).
# One build peaks at ~8-9 GB RSS and ~4 CPU-minutes x 4 cores: images are built one at a time.
source "$(dirname "$0")/env.sh"; set +e
SRC="$LAB_ROOT/src"; LOGS="$NATIVE_DIR/logs"; mkdir -p "$NATIVE_DIR/bin" "$LOGS"
GRAAL_URL=https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-21.0.2/graalvm-community-jdk-21.0.2_linux-x64_bin.tar.gz
if [ ! -x "$GRAALVM_HOME/bin/native-image" ]; then
  log "downloading GraalVM CE 21.0.2 to $GRAALVM_HOME"
  mkdir -p "$GRAALVM_HOME" && curl -fsSL "$GRAAL_URL" | tar -xz --strip-components=1 -C "$GRAALVM_HOME" || exit 1
fi
# name | repo dir | AOT profiles | system properties for the AOT run | extra native-image options
# AOT instantiates a few beans at build time (configuration that feeds bean post-processors), so
# properties those beans need must exist then. They only satisfy that build-time instantiation:
# at runtime the values come from the launch command, as on the JVM.
SPECS=(
  "identity-provider|identity-provider|local||-Djava.security.properties=$NATIVE_DIR/bouncycastle.security --initialize-at-build-time=org.bouncycastle --initialize-at-run-time=org.bouncycastle.jcajce.provider.drbg.DRBG\$Default,org.bouncycastle.jcajce.provider.drbg.DRBG\$NonceAndIV"
  "auth-provider-local-authority|authentication_provider|local-authority||-Djava.security.properties=$NATIVE_DIR/bouncycastle.security --initialize-at-build-time=org.bouncycastle --initialize-at-run-time=org.bouncycastle.jcajce.provider.drbg.DRBG\$Default,org.bouncycastle.jcajce.provider.drbg.DRBG\$NonceAndIV"
  "auth-provider-local-consumer|authentication_provider|local-consumer||-Djava.security.properties=$NATIVE_DIR/bouncycastle.security --initialize-at-build-time=org.bouncycastle --initialize-at-run-time=org.bouncycastle.jcajce.provider.drbg.DRBG\$Default,org.bouncycastle.jcajce.provider.drbg.DRBG\$NonceAndIV"
  "security-attributes-provider|security-attributes-provider|local||-Djava.security.properties=$NATIVE_DIR/bouncycastle.security --initialize-at-build-time=org.bouncycastle --initialize-at-run-time=org.bouncycastle.jcajce.provider.drbg.DRBG\$Default,org.bouncycastle.jcajce.provider.drbg.DRBG\$NonceAndIV"
  "tier2-gateway|tier2-gateway|local-authority|-Dkeypair.algorithm=EC -Dsap.url=http://localhost:8102 -Didentity-provider.url=http://localhost:8103 -Dauthentication-provider.url=http://localhost:8105 -Dusers-roles.url=http://localhost:8106 -Dfederated-catalogue.url=http://localhost:8081|--initialize-at-run-time=io.netty -Djava.security.properties=$NATIVE_DIR/bouncycastle.security --initialize-at-build-time=org.bouncycastle --initialize-at-run-time=org.bouncycastle.jcajce.provider.drbg.DRBG\$Default,org.bouncycastle.jcajce.provider.drbg.DRBG\$NonceAndIV"
  "sd-tooling-be|sd-tooling-be|default|"
  "fc-service|catalogue-be|default||--initialize-at-run-time=io.netty"
)
printf 'security.provider.13=org.bouncycastle.jce.provider.BouncyCastleProvider\n' > "$NATIVE_DIR/bouncycastle.security"
want=("$@")
gmvn(){ env -u JAVA_TOOL_OPTIONS -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
  JAVA_HOME="$GRAALVM_HOME" GRAALVM_HOME="$GRAALVM_HOME" PATH="$GRAALVM_HOME/bin:$PATH" \
  mvn -B -ntp -DskipTests -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true \
  -Dcheckstyle.skip=true -Dmaven.javadoc.skip=true -Djacoco.skip=true "$@"; }
for spec in "${SPECS[@]}"; do
  IFS='|' read -r name repo profiles aotprops nativeopts <<<"$spec"
  [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " == *" $name "* ]] && continue
  d="$SRC/$repo"; L="$LOGS/$name.log"; : > "$L"; t0=$(date +%s)
  # fc-service: its DatabaseConfig (a TransactionManagementConfigurer with an autowired DataSource)
  # is created with the transaction advisor during AOT, before properties are bound. The patch drops
  # the redundant configurer (hibernateTransactionManager is the only TransactionManager).
  # JPA services: Hibernate cannot generate lazy-loading proxy classes in a native image (bytecode
  # provider 'none'); build-time enhancement makes the entities their own proxies. Without it every
  # LAZY association / getReferenceById fails at runtime (e.g. the auth-provider cannot load its
  # private key, so the gateway falls back to its self-signed certificate).
  case "$name" in
    identity-provider) enh=identity-provider ;; security-attributes-provider) enh=sap ;;
    auth-provider-*) enh=authprovider ;; *) enh= ;;
  esac
  if [ -n "$enh" ]; then
    p="$REPO_LAB_DIR/iaa/patches/$enh-hibernate-enhance.patch"
    git -C "$d" apply --reverse --check "$p" 2>/dev/null || git -C "$d" apply "$p" || { log "  cannot apply $p"; continue; }
  fi
  if [ "$name" = fc-service ]; then
    p="$REPO_LAB_DIR/catalogue/patches/catalogue-native-aot.patch"
    git -C "$d" apply --reverse --check "$p" 2>/dev/null || git -C "$d" apply "$p" || { log "  cannot apply $p"; continue; }
  fi
  log "native: $name ($repo, AOT profiles '$profiles') — log $L"
  # 1. Spring AOT for this profile (compiled into target/classes) + the reachability metadata
  #    repository (target/graalvm-reachability-metadata) for the third-party libraries
  # process-aot has no user property for <profiles> (-Dspring-boot.aot.profiles is silently
  # ignored), so the profile goes in as a system property of the AOT JVM; that also expands the
  # profile groups (local-authority -> local + authority) as at runtime.
  [ "$profiles" != default ] && aotprops="-Dspring.profiles.active=$profiles $aotprops"
  aot=(); [ -n "$aotprops" ] && aot=(-Dspring-boot.aot.jvmArguments="$aotprops")
  ( cd "$d" && gmvn -Pnative "${aot[@]}" package >>"$L" 2>&1 ) || { log "  AOT/package failed — see $L"; continue; }
  # The image gets exactly what the executable jar runs on the JVM: its BOOT-INF/classes (now with
  # the AOT classes) and BOOT-INF/lib, plus the jar root, where Boot moves META-INF/native-image
  # (main class + Spring's image flags). dependency:build-classpath returned test-only jars too.
  jar=$(ls "$d"/target/*.jar | grep -v -- '-plain\|\.original' | head -1); x="$d/target/native-x"
  # 07 injects the /fc ABAC rule into the gateway jar after building it; the image needs it too
  [ "$name" = tier2-gateway ] && JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    bash "$REPO_LAB_DIR/iaa/inject-fc-abac-rule.sh" "$jar" CONSUMER >>"$L" 2>&1
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
  # Spring's commons-logging (spring-jcl) must be initialized at build time. With jcl-over-slf4j
  # (fc-service) LogFactory is SLF4J's bridge instead: initializing it in the builder freezes SLF4J's
  # NOP provider into the image ("LoggerFactory is not a Logback LoggerContext") — leave it to run time.
  # Library order as on the JVM (BOOT-INF/classpath.idx), not alphabetical: fc-service's neosemantics
  # fat jar bundles SLF4J 1.x and sorts before slf4j-api 2.x, which then loses (NOP logger at runtime).
  if [ -f "$x/BOOT-INF/classpath.idx" ]; then
    cplibs=$(sed -n 's|^- "\(BOOT-INF/lib/[^"]*\)"$|'"$x"'/\1|p' "$x/BOOT-INF/classpath.idx" | paste -sd:)
  else
    cplibs=$(ls "$x"/BOOT-INF/lib/*.jar | paste -sd:)
  fi
  jclinit="--initialize-at-build-time=org.apache.commons.logging.LogFactory,org.apache.commons.logging.LogFactoryService"
  compgen -G "$x/BOOT-INF/lib/jcl-over-slf4j-*.jar" >/dev/null && jclinit=
  # 3. native-image. Spring AOT's native-image.properties supplies the main class and its flags.
  rm -f "$NATIVE_DIR/bin/$name"
  env -u JAVA_TOOL_OPTIONS JAVA_HOME="$GRAALVM_HOME" "$GRAALVM_HOME/bin/native-image" \
    -cp "$x:$x/BOOT-INF/classes:$cplibs" --no-fallback -o "$NATIVE_DIR/bin/$name" \
    ${cfg:+-H:ConfigurationFileDirectories=$cfg} \
    $jclinit \
    -H:+ReportExceptionStackTraces ${NATIVE_EXTRA:-} $nativeopts >>"$L" 2>&1
  if [ -x "$NATIVE_DIR/bin/$name" ]; then
    log "  OK $name: $(du -m "$NATIVE_DIR/bin/$name" | cut -f1) MB in $(( $(date +%s)-t0 ))s ($(grep -ao 'Peak RSS: [0-9.]*GB' "$L" | tail -1))"
  else
    log "  FAILED $name after $(( $(date +%s)-t0 ))s:"; grep -a "^Error" "$L" | head -3
  fi
done
