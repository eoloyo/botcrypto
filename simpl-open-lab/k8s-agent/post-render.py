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
  * CPU *requests* are scaled by CPU_REQUEST_SCALE (default 0.5): the agent requests 6.3 cores and
    the lab node has 4; limits and memory are left as the charts set them;
  * containers with a livenessProbe get a startupProbe (same check, up to STARTUP_GRACE seconds,
    default 900) so the official liveness/readiness probes only start once the container is up:
    under gVisor on 4 cores Keycloak and the Spring services take longer than the charts' fixed
    initialDelaySeconds, and the liveness probe kills them mid-start;
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

CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding", "StorageClass", "PriorityClass"}
STARTUP_GRACE = int(os.environ.get("STARTUP_GRACE", "900"))
CPU_SCALE = float(os.environ.get("CPU_REQUEST_SCALE", "0.5"))
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

    out = []
    for path in sys.argv[2:]:
        for doc in yaml.safe_load_all(open(path)):
            if not doc or doc.get("kind") == "Application":
                continue
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
            if spec is not None:
                spec["runtimeClassName"] = "runsc"
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
                        req["cpu"] = f"{max(1, round(milli * CPU_SCALE))}m"
                    if isinstance(c.get("image"), str):
                        c["image"] = c["image"].strip()
                for c in spec.get("initContainers", []):
                    if c["name"] == "init-spi":
                        c["command"] = ["/bin/sh", "-c"]
                        c["args"] = ["cp /spi-src/*.jar /custom-spi/ && ls -l /custom-spi"]
                        c["volumeMounts"].append({"name": "spi-src", "mountPath": "/spi-src", "readOnly": True})
                        spec["volumes"].append({"name": "spi-src", "hostPath": {"path": "/var/lib/simpl-spi"}})
            text = VAULT.sub(vault, yaml.safe_dump(doc, sort_keys=False, width=1 << 20))
            out.append(text)
    out.append(yaml.safe_dump({"apiVersion": "v1", "kind": "Secret",
                               "metadata": {"name": "redis-secrets", "namespace": "authority01"},
                               "stringData": {"redis": secrets["lab#redis"]}}, sort_keys=False))
    sys.stdout.write("---\n".join(out))


if __name__ == "__main__":
    main()
