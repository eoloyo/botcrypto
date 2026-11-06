#!/usr/bin/env python3
"""components_wildcard.py — the component charts that hard-wire a per-host certificate get `existingTlsSecret`.

From the inventory (INVENTORY.md) three families of charts request a certificate from their own Ingress template with no way to say
"use this Secret instead". Everything else either has no Ingress or already takes `ingress.tls[].secretName` from values (values-only:
the bundle change in wildcard_all.py is enough).

  family  charts                                                                                   value
  iaa     tier1-gateway, fe-authentication-provider, fe-identity-provider, fe-onboarding,           ingress.existingTlsSecret
          fe-security-attribute-provider, users-roles-fe, consent-management-fe, gateway-oauth2-client
  adapter contract-consumption-be, edc-connector-adapter, schema-sync-adapter, sd-creation-wizard,  ingress.existingTlsSecret
          xfsc-advsearch, simpl-files
  monitor monitoring-proxy, eck-monitoring (its Kibana Ingress)                                     existingTlsSecret (top level)

When the value is set the cert-manager annotations are dropped and it is used as the TLS secretName; unset = byte-identical output.
Works on the exact chart versions the bundles pin (pulled by fullchain.py) and writes components-wildcard.patch.
"""
import os
import re
import shutil
import subprocess
import sys

BASE = os.environ.get("INV", "/root/simpl-open-lab-work/wildcard-poc/inv")
HERE = os.path.dirname(os.path.abspath(__file__))
FAMILY = {c: "ingress" for c in ("tier1-gateway fe-authentication-provider fe-identity-provider fe-onboarding fe-security-attribute-provider "
                                 "users-roles-fe consent-management-fe gateway-oauth2-client contract-consumption-be edc-connector-adapter "
                                 "schema-sync-adapter sd-creation-wizard xfsc-advsearch simpl-files").split()}
FAMILY.update({"monitoring-proxy": "top", "eck-monitoring": "top"})
ANN = re.compile(r"^(\s+)(cert-manager\.io/(?:cluster-issuer|renew-before)|acme\.cert-manager\.io/http01-edit-in-place):.*$")
indent = lambda l: len(l) - len(l.lstrip(" "))
STATS = {"charts": 0, "templates": 0, "annotations_gated": 0, "secretnames": 0}


def patch_doc(doc, key):
    out = []; in_tls = False; tls_ind = -1; secret_done = False
    for l in doc.split("\n"):
        m = ANN.match(l)
        if m:
            out += [f"{m.group(1)}{{{{- if not {key} }}}}", l, f"{m.group(1)}{{{{- end }}}}"]; STATS["annotations_gated"] += 1; continue
        if re.fullmatch(r"\s*tls:\s*", l): in_tls = True; tls_ind = indent(l)
        elif l.strip() and in_tls and indent(l) <= tls_ind and not l.lstrip().startswith("-"): in_tls = False
        sm = re.match(r"^(\s*-?\s*secretName:\s*)(.+)$", l)
        if in_tls and sm and not secret_done and "{{ if " not in l:
            out.append(f"{sm.group(1)}{{{{ if {key} }}}}{{{{ {key} }}}}{{{{ else }}}}{sm.group(2)}{{{{ end }}}}"); secret_done = True; STATS["secretnames"] += 1; continue
        out.append(l)
    return "\n".join(out)


def patch_chart(cdir, name):
    fam = FAMILY[name]; key = ".Values.ingress.existingTlsSecret" if fam == "ingress" else ".Values.existingTlsSecret"
    done = False
    for root, _, files in os.walk(f"{cdir}/templates"):
        for f in files:
            p = os.path.join(root, f)
            if not f.endswith((".yaml", ".yml", ".tpl")): continue
            t = open(p, errors="ignore").read()
            if not re.search(r"kind:\s*Ingress\b", t) or not re.search(r"cert-manager\.io/cluster-issuer", t): continue
            docs = re.split(r"(\n---[^\n]*\n)", t)
            new = "".join(patch_doc(d, key) if re.search(r"kind:\s*Ingress\b", d) and "cert-manager.io/cluster-issuer" in d else d for d in docs)
            if new != t: open(p, "w").write(new); STATS["templates"] += 1; done = True
    if not done:
        STATS["no_ingress"] = STATS.get("no_ingress", 0) + 1; print(f"  {cdir.split('/')[-2]}: no cert-manager Ingress template, left alone"); return
    v = f"{cdir}/values.yaml"; vt = open(v).read()
    if fam == "ingress":
        m = re.search(r"^ingress:[^\n]*\n", vt, re.M); assert m, f"{name}: no top-level ingress: in values.yaml"
        vt = vt[:m.end()] + '  # Name of an existing TLS Secret in this namespace (e.g. a wildcard certificate). When set, the cert-manager\n  # annotations are dropped, no per-host certificate is requested and this Secret is used.\n  existingTlsSecret: ""\n' + vt[m.end():]
    else:
        vt = vt.rstrip("\n") + '\n\n# Name of an existing TLS Secret (e.g. a wildcard certificate) for the Ingress. When set, the cert-manager annotation\n# is dropped and this Secret is used.\nexistingTlsSecret: ""\n'
    open(v, "w").write(vt); STATS["charts"] += 1


if __name__ == "__main__":
    src = f"{BASE}/pulled"; dst = f"{BASE}/pulled-patched"
    shutil.rmtree(dst, ignore_errors=True); shutil.copytree(src, dst)
    for d in sorted(os.listdir(dst)):
        for name in FAMILY:
            if re.fullmatch(re.escape(name) + r"-\d.*", d) and os.path.isdir(f"{dst}/{d}/{name}"):
                patch_chart(f"{dst}/{d}/{name}", name)
    diff = subprocess.run(["diff", "-ruN", "pulled", "pulled-patched"], cwd=BASE, capture_output=True, text=True).stdout
    open(f"{HERE}/components-wildcard.patch", "w").write(diff)
    print(STATS, f"patch: {diff.count(chr(10))} lines")
