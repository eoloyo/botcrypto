"""The lab's stand-in for the ingress controller in front of authority-iaa.

In the official set-up an ingress controller terminates TLS for the agent's public names
(authority.be/fe.authority01.example.com), and the services reach Keycloak and each other through
those names (Keycloak's KC_HOSTNAME is https://authority.be.../auth, so tokens carry that issuer).
This lab has no ingress controller and no DNS for example.com, so:

  * an nginx pod (`edge`) serves the routes of the charts' own Ingress objects, with TLS from a lab CA;
  * CoreDNS answers *.authority01.example.com with the edge Service (deploy.sh, coredns-custom);
  * the Java services get a truststore with the JDK's CAs plus the lab CA (JAVA_TOOL_OPTIONS).

The Ingress objects are still applied unchanged; nothing serves them.
"""
import base64
import os

NS = "authority01"
TRUST_ENV = ("-Djavax.net.ssl.trustStore=/lab-trust/truststore.jks "
             "-Djavax.net.ssl.trustStorePassword=changeit")


def routes(docs):
    """[(host, path, service, port number)] from the Ingress objects, longest path first."""
    ports = {}
    for d in docs:
        if d.get("kind") == "Service":
            for p in d["spec"].get("ports", []):
                ports[(d["metadata"]["name"], p.get("name"))] = p["port"]
                ports[(d["metadata"]["name"], p["port"])] = p["port"]
    out = []
    for d in docs:
        if d.get("kind") != "Ingress":
            continue
        for rule in d["spec"].get("rules", []):
            for p in rule.get("http", {}).get("paths", []):
                svc = p["backend"]["service"]
                port = svc["port"].get("number", svc["port"].get("name"))
                out.append((rule["host"], p.get("path", "/"), svc["name"], ports.get((svc["name"], port), port)))
    return sorted(set(out), key=lambda r: (r[0], -len(r[1])))


def nginx_conf(rts):
    servers = []
    for host in sorted({r[0] for r in rts}):
        locs = "".join(
            f"    location {path} {{ set $u http://{svc}.{NS}.svc.cluster.local:{port}; proxy_pass $u; }}\n"
            for h, path, svc, port in rts if h == host)
        servers.append(f"""server {{
    listen 8443 ssl;
    server_name {host};
    ssl_certificate /tls/tls.crt;
    ssl_certificate_key /tls/tls.key;
{locs}}}
""")
    return f"""resolver kube-dns.kube-system.svc.cluster.local valid=10s;
client_max_body_size 50m;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_http_version 1.1;
proxy_read_timeout 300s;
""" + "".join(servers)


def objects(docs, pki):
    """The edge Deployment/Service/ConfigMap and the TLS + truststore Secrets."""
    rd = lambda f: open(os.path.join(pki, f), "rb").read()
    b64 = lambda f: base64.b64encode(rd(f)).decode()
    meta = lambda name: {"name": name, "namespace": NS}
    labels = {"app.kubernetes.io/name": "lab-edge"}
    return [
        {"apiVersion": "v1", "kind": "Secret", "metadata": meta("lab-edge-tls"), "type": "kubernetes.io/tls",
         "data": {"tls.crt": b64("edge.crt"), "tls.key": b64("edge.key")}},
        {"apiVersion": "v1", "kind": "Secret", "metadata": meta("lab-truststore"),
         "data": {"truststore.jks": b64("truststore.jks")}},
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("lab-edge"),
         "data": {"edge.conf": nginx_conf(routes(docs))}},
        {"apiVersion": "v1", "kind": "Service", "metadata": meta("edge"),
         "spec": {"selector": labels, "ports": [{"name": "https", "port": 443, "targetPort": 8443}]}},
        {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta("lab-edge"),
         "spec": {"replicas": 1, "selector": {"matchLabels": labels},
                  "template": {"metadata": {"labels": labels}, "spec": {
                      "runtimeClassName": "runsc",
                      "containers": [{
                          "name": "nginx", "image": "nginxinc/nginx-unprivileged:alpine3.22-perl",
                          "imagePullPolicy": "IfNotPresent",
                          "ports": [{"containerPort": 8443}],
                          "readinessProbe": {"tcpSocket": {"port": 8443}, "periodSeconds": 3},
                          "resources": {"requests": {"cpu": "20m", "memory": "32Mi"}},
                          "volumeMounts": [{"name": "conf", "mountPath": "/etc/nginx/conf.d"},
                                           {"name": "tls", "mountPath": "/tls", "readOnly": True}]}],
                      "volumes": [{"name": "conf", "configMap": {"name": "lab-edge"}},
                                  {"name": "tls", "secret": {"secretName": "lab-edge-tls"}}]}}}},
    ]


def trust(spec, is_java):
    """Mount the lab truststore into the Java containers and point the JVM at it."""
    added = False
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        if not is_java(c.get("image", "")):
            continue
        env = c.setdefault("env", [])
        cur = next((e for e in env if e["name"] == "JAVA_TOOL_OPTIONS"), None)
        if cur:
            cur["value"] = f"{cur.get('value', '')} {TRUST_ENV}".strip()
        else:
            env.append({"name": "JAVA_TOOL_OPTIONS", "value": TRUST_ENV})
        c.setdefault("volumeMounts", []).append({"name": "lab-trust", "mountPath": "/lab-trust", "readOnly": True})
        added = True
    if added:
        spec.setdefault("volumes", []).append({"name": "lab-trust", "secret": {"secretName": "lab-truststore"}})
