#!/usr/bin/env python3
"""post-render.py <secrets.json> <rendered.yaml>... > agent.yaml

Turns the official, ArgoCD-rendered authority-iaa manifests (../k8s-sizing/render_apps.py) into
something this single-node k3s-on-gVisor lab can apply without ArgoCD, OpenBao or the bank-vaults
webhook. Every change is listed here; nothing else in the official manifests is touched:

  * drops the ArgoCD Application objects (their children are passed in already rendered);
  * substitutes the `vault:${SECRETENGINE}/data/<secret>#<key>` env values - what the bank-vaults
    webhook does at pod start - with the lab values from secrets.json;
  * replaces the client secrets hard-coded in the keycloak-realms ConfigMap with lab values
    (onboarding-sa gets the same value the onboarding service receives);
  * runtimeClassName: runsc (runc cannot run pods in this sandbox) and imagePullPolicy: IfNotPresent
    (the images are imported into containerd; code.europa.eu:4567 is unreachable from here);
  * Keycloak's init-spi container copies the two SPI jars from a hostPath instead of downloading
    them from code.europa.eu (pods have no route to the internet here);
  * CPU *requests* are scaled by CPU_REQUEST_SCALE (default 0.3): the agent requests 6.3 cores and
    the lab node has 4; limits and memory are left as the charts set them. EJBCA, the start-up
    critical path (CA set-up, then everything that needs its certificates), gets CRITICAL_CPU
    (default 1500m) instead, capped at the chart's CPU limit (500m), so it wins the CPU while all
    the JVMs start at once;
  * EJBCA's set-up container runs ~37 short `ejbca.sh` CLI JVMs: JAVA_OPTS_EJB_CLI (EJBCA's own knob)
    keeps their defaults and adds C1-only JIT and class-data sharing (12.2 s -> 8.5 s per call);
  * containers with a livenessProbe get a startupProbe (same check, up to STARTUP_GRACE seconds,
    default 900) so the official liveness/readiness probes only start once the container is up:
    under gVisor on 4 cores Keycloak and the Spring services take longer than the charts' fixed
    initialDelaySeconds, and the liveness probe kills them mid-start;
  * authentication-provider's create-secret Job builds its AES key with `openssl rand` inside the
    unpinned alpine/kubectl:latest image, which no longer ships openssl: the secret is created with
    an empty key and the service fails (CRYPTO_SECRETKEYBASE64 must not be blank). The key is made
    with /dev/urandom and base64 instead (upstream defect);
  * with LAB_PKI set (deploy.sh), adds the lab edge that stands in for the ingress controller and
    gives the Simpl Java services a truststore with the lab CA; see edge.py;
  * EJBCA_RELEASE (e.g. 9.6.3) swaps EJBCA for another keyfactor/ejbca-ce release, with Simpl's
    ejbca-preconfig rebuilt on it (build-images.sh EJBCA_BASE); unset = the chart's 8.2.0.1;
  * EJBCA_PERSIST (default 1) gives EJBCA a PersistentVolume at /opt/keyfactor/secrets/persistent,
    where Keyfactor's start-up keeps "a server TLS certificate from previous runs" (the chart mounts
    nothing there, so every start issued a new one: ~1.5 min of CLI JVMs), and points ejbca-preconfig's
    bootstrap marker at it (patch-preconfig.py) so a restart skips the set-up server boot. EJBCA.md;
  * adds the `redis-secrets` Secret (key `redis`) that the redis chart and the services read but no
    chart creates (in the official set-up it is provisioned alongside the OpenBao secrets);
  * puts namespaced objects without a namespace into authority01 (ArgoCD's destination namespace).
"""
import copy
import json
import os
import re
import sys

import yaml

import edge

PKI = os.environ.get("LAB_PKI")
SIMPL = "code.europa.eu:4567/simpl/"
is_java = lambda image: image.strip().startswith(SIMPL) and not image.strip().rsplit(":", 1)[0].endswith(("-fe", "ejbca-preconfig"))
CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding", "StorageClass", "PriorityClass"}
STARTUP_GRACE = int(os.environ.get("STARTUP_GRACE", "900"))
EJBCA_RELEASE = os.environ.get("EJBCA_RELEASE")
EJBCA_PERSIST = os.environ.get("EJBCA_PERSIST", "1") == "1"
EJBCA_PERSISTENT_DIR = "/opt/keyfactor/secrets/persistent"
CPU_SCALE = float(os.environ.get("CPU_REQUEST_SCALE", "0.3"))
CRITICAL = {"ejbca-community-helm": os.environ.get("CRITICAL_CPU", "1500m")}
EJBCA_CLI_OPTS = ("-Xms32m -Xmx32m -XX:MetaspaceSize=32M -XX:MaxMetaspaceSize=48m -XX:MaxRAM=80m "
                  "-XX:ParallelGCThreads=1 -XX:ConcGCThreads=1 -Djava.util.concurrent.ForkJoinPool.common.parallelism=1 "
                  "-XX:CICompilerCount=2 -Djava.security.egd=file:/dev/random "   # ejbca.sh's defaults
                  "-XX:TieredStopAtLevel=1 -Xshare:auto")
VAULT = re.compile(r"vault:\$\{SECRETENGINE\}/data/([^#\s\"]+)#([^\s\"]+)")


def pod_spec(doc):
    kind = doc.get("kind")
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        return doc["spec"]["template"]["spec"]
    if kind == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None


def main():
    secrets = json.load(open(sys.argv[1]))

    def vault(m):
        key = f"{m.group(1)}#{m.group(2)}"
        if key not in secrets:
            sys.exit(f"no lab value for {key}")
        return secrets[key]

    out, docs = [], []
    for path in sys.argv[2:]:
        for doc in yaml.safe_load_all(open(path)):
            if not doc or doc.get("kind") == "Application":
                continue
            docs.append(doc)
            meta = doc.setdefault("metadata", {})
            if doc["kind"] not in CLUSTER_SCOPED and not meta.get("namespace"):
                meta["namespace"] = "authority01"
            if doc["kind"] == "ConfigMap" and meta["name"] == "keycloak-realms":
                for name, realm_json in doc["data"].items():
                    realm = json.loads(realm_json)
                    for client in realm.get("clients", []):
                        if "secret" in client:
                            client["secret"] = secrets[f"{realm['realm']}-client#{client['clientId']}"]
                    doc["data"][name] = json.dumps(realm, indent=2)
            spec = pod_spec(doc)
            if spec is not None and EJBCA_PERSIST and meta["name"] == "ejbca-community-helm":
                # the chart renders empty lists as null
                spec["volumes"] = (spec.get("volumes") or []) + [
                    {"name": "ejbca-persistent", "persistentVolumeClaim": {"claimName": "ejbca-persistent"}}]
                for c in (spec.get("initContainers") or []) + spec["containers"]:
                    c["volumeMounts"] = (c.get("volumeMounts") or []) + [
                        {"name": "ejbca-persistent", "mountPath": EJBCA_PERSISTENT_DIR}]
                for c in spec.get("initContainers") or []:
                    c["env"] = (c.get("env") or []) + [
                        {"name": "EJBCA_BOOTSTRAP_MARKER", "value": f"{EJBCA_PERSISTENT_DIR}/simpl-bootstrapped"}]
                doc["spec"]["strategy"] = {"type": "Recreate"}   # one pod at a time on the RWO volume
            if spec is not None:
                spec["runtimeClassName"] = "runsc"
                if PKI:
                    edge.trust(spec, is_java)
                for c in spec.get("containers", []):
                    for field in ("command", "args"):
                        if c.get(field):
                            c[field] = [x.replace("$(openssl rand -base64 32)", "$(head -c 32 /dev/urandom | base64)")
                                        for x in c[field]]
                for c in spec.get("initContainers", []) + spec.get("containers", []):
                    c["imagePullPolicy"] = "IfNotPresent"
                    live = c.get("livenessProbe")
                    if live and "startupProbe" not in c and c in spec.get("containers", []):
                        probe = {k: copy.deepcopy(v) for k, v in live.items() if k in ("httpGet", "tcpSocket", "exec", "grpc")}
                        c["startupProbe"] = {**probe, "periodSeconds": 5, "timeoutSeconds": 5,
                                             "failureThreshold": STARTUP_GRACE // 5}
                    req = (c.get("resources") or {}).get("requests") or {}
                    if "cpu" in req:
                        v = str(req["cpu"])
                        milli = float(v[:-1]) if v.endswith("m") else float(v) * 1000
                        lim = str(((c.get("resources") or {}).get("limits") or {}).get("cpu", ""))
                        lim_m = (float(lim[:-1]) if lim.endswith("m") else float(lim) * 1000) if lim else None
                        if meta["name"] in CRITICAL:
                            crit = float(CRITICAL[meta["name"]].rstrip("m"))
                            req["cpu"] = f"{round(min(crit, lim_m) if lim_m else crit)}m"
                        else:
                            req["cpu"] = f"{max(1, round(milli * CPU_SCALE))}m"
                    if isinstance(c.get("image"), str):
                        c["image"] = c["image"].strip()
                        if EJBCA_RELEASE and meta["name"] == "ejbca-community-helm":
                            if c["image"].startswith("keyfactor/ejbca-ce:"):
                                c["image"] = f"keyfactor/ejbca-ce:{EJBCA_RELEASE}"
                            elif "/ejbca-preconfig:" in c["image"]:
                                c["image"] += f"-ejbca{EJBCA_RELEASE}"
                for c in spec.get("initContainers", []):
                    if meta["name"] == "ejbca-community-helm":
                        c.setdefault("env", []).append({"name": "JAVA_OPTS_EJB_CLI", "value": EJBCA_CLI_OPTS})
                    if c["name"] == "init-spi":
                        c["command"] = ["/bin/sh", "-c"]
                        c["args"] = ["cp /spi-src/*.jar /custom-spi/ && ls -l /custom-spi"]
                        c["volumeMounts"].append({"name": "spi-src", "mountPath": "/spi-src", "readOnly": True})
                        spec["volumes"].append({"name": "spi-src", "hostPath": {"path": "/var/lib/simpl-spi"}})
            text = VAULT.sub(vault, yaml.safe_dump(doc, sort_keys=False, width=1 << 20))
            out.append(text)
    if EJBCA_PERSIST:
        out.append(yaml.safe_dump({"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                                   "metadata": {"name": "ejbca-persistent", "namespace": "authority01"},
                                   "spec": {"accessModes": ["ReadWriteOnce"],
                                            "resources": {"requests": {"storage": "100Mi"}}}}, sort_keys=False))
    out.append(yaml.safe_dump({"apiVersion": "v1", "kind": "Secret",
                               "metadata": {"name": "redis-secrets", "namespace": "authority01"},
                               "stringData": {"redis": secrets["lab#redis"]}}, sort_keys=False))
    if PKI:
        out += [yaml.safe_dump(o, sort_keys=False, width=1 << 20) for o in edge.objects(docs, PKI)]
    sys.stdout.write("---\n".join(out))


if __name__ == "__main__":
    main()
