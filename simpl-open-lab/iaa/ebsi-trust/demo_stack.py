#!/usr/bin/env python3
"""demo_stack.py <out.json> — a runnable Tier-2 world: stub EBSI + a did:web host + the real sidecar.

Serves three authorities as did:web verification methods and writes them to <out.json>:
  vm_ok        links an EBSI-accredited Trusted Issuer and proves control of it       -> trusted
  vm_unlinked  has no EBSI identity link                                             -> rejected (403)
  vm_thief     claims the accredited TI's public did:ebsi but cannot sign as it      -> rejected (403)
and the sidecar's URL. Used to run authp-be's Java EbsiTrustAdapterImpl against the real sidecar."""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer

import test_link as tl  # sets EBSI_API to the stub on :18095 and allows localhost did:web (lab only)

tc, e = tl.tc, tl.e


def main():
    r, t, ti = tl.fresh()
    thief = tl.tc.Actor(tl.tc.ec.SECP256R1(), "ES256")
    thief.kid = ti.kid
    ok = tl.publish("auth", ti.did, tl.proof(ti, tl.web_did("auth")), also=[ti.did])
    unlinked = tl.publish("plain", ti.did, "x", extra_service=False)
    stolen = tl.publish("thief", ti.did, tl.proof(ti, tl.web_did("thief"), signer=thief), also=[ti.did])
    for srv in (ThreadingHTTPServer(("127.0.0.1", tc.PORT), tc.Stub), ThreadingHTTPServer(("127.0.0.1", tl.WEB_PORT), tl.WebStub),
                ThreadingHTTPServer(("127.0.0.1", 18097), e.Handler)):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    json.dump({"sidecar": "http://127.0.0.1:18097", "vm_ok": ok, "vm_unlinked": unlinked, "vm_thief": stolen,
               "ebsi_did": ti.did}, open(sys.argv[1], "w"))
    print("demo stack up; vms written to", sys.argv[1], flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
