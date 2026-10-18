#!/usr/bin/env python3
"""Take the officially rendered identity-provider objects and patch only what this lab cluster needs.
usage: mkip.py <official-render.yaml> <image> <variant> > manifest.yaml
variant: official   -> official resources/probes untouched
         nolimit    -> official, but no CPU limit (calibration)
"""
import sys, yaml
src, image, variant = sys.argv[1:4]
out = []
for d in yaml.safe_load_all(open(src)):
    if not d or d["kind"] in ("HorizontalPodAutoscaler",): continue
    d["metadata"]["namespace"] = "authority01"
    if d["kind"] == "Deployment":
        t = d["spec"]["template"]
        ann = t["metadata"].get("annotations") or {}
        for k in [k for k in ann if k.startswith("vault.security")]: del ann[k]   # no vault webhook here
        t["spec"]["runtimeClassName"] = "runsc"                                    # this sandbox only runs gVisor pods
        c = t["spec"]["containers"][0]
        c["image"], c["imagePullPolicy"] = image, "IfNotPresent"
        vals = {"SPRING_DATASOURCE_PASSWORD": "identityprovider", "SPRING_DATA_REDIS_PASSWORD": "admin",
                "SPRING_SSL_BUNDLE_JKS_EJBCA_KEYSTORE_PASSWORD": "labpass"}
        for e in c.get("env") or []:
            if e["name"] in vals: e.pop("valueFrom", None); e["value"] = vals[e["name"]]
        if variant == "nolimit":
            c["resources"].get("limits", {}).pop("cpu", None)
        if variant.startswith("cpu"):            # e.g. cpu400m: the CPU limit other Simpl backends get
            c["resources"]["limits"]["cpu"] = variant[3:]
    out.append(d)
print(yaml.safe_dump_all(out, sort_keys=False))
