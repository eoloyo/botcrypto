# Results of the last ./run_all.sh (clean slate, 2026-11-06)

Excerpt of the log: every check line plus the measurements. Warnings and per-host repetitions trimmed.

```
################ ./acme_test.sh teardown
=== EXIT 0: ./acme_test.sh teardown
################ ./ingress_nginx.sh uninstall
=== EXIT 0: ./ingress_nginx.sh uninstall
################ ./cert_manager.sh uninstall
=== EXIT 0: ./cert_manager.sh uninstall
################ ./cert_manager.sh install
=== EXIT 0: ./cert_manager.sh install
################ ./ingress_nginx.sh install
=== EXIT 0: ./ingress_nginx.sh install
################ ./render_check.sh $W/orig $W/patched
  [PASS] original renders a real Ingress
  [PASS] default mode renders byte-identical to the original
  [PASS] old values.yaml without the new key renders identically
  [PASS] wildcard mode: no cert-manager annotations
  [PASS] wildcard mode: uses the shared secret
  [PASS] wildcard mode: hostnames unchanged
  [PASS] original renders a real Ingress
  [PASS] default mode renders byte-identical to the original
  [PASS] old values.yaml without the new key renders identically
  [PASS] wildcard mode: no cert-manager annotations
  [PASS] wildcard mode: uses the shared secret
  [PASS] wildcard mode: hostnames unchanged
  [PASS] original renders a real Ingress
  [PASS] default mode renders byte-identical to the original
  [PASS] old values.yaml without the new key renders identically
  [PASS] wildcard mode: no cert-manager annotations
  [PASS] wildcard mode: uses the shared secret
  [PASS] wildcard mode: hostnames unchanged
  [PASS] original renders a real Ingress
  [PASS] default mode renders byte-identical to the original
  [PASS] old values.yaml without the new key renders identically
  [PASS] wildcard mode: no cert-manager annotations
  [PASS] wildcard mode: uses the shared secret
  [PASS] wildcard mode: hostnames unchanged
  [PASS] original renders a real Ingress
  [PASS] default mode renders byte-identical to the original
  [PASS] old values.yaml without the new key renders identically
  [PASS] wildcard mode: no cert-manager annotations
  [PASS] wildcard mode: uses the shared secret
  [PASS] wildcard mode: hostnames unchanged
  [PASS] original renders a real Ingress
  [PASS] default mode renders byte-identical to the original
  [PASS] old values.yaml without the new key renders identically
  [PASS] wildcard mode: no cert-manager annotations
  [PASS] wildcard mode: uses the shared secret
  [PASS] wildcard mode: hostnames unchanged
ALL RENDER CHECKS PASSED
=== EXIT 0: ./render_check.sh $W/orig $W/patched
  [PASS] original umbrella renders a real Application
  [PASS] default (perHost): patched output is byte-identical to the original
  [PASS] wildcard mode: all 6 bundles receive tls.mode=wildcard and secret consumer1-wildcard-tls
  [PASS] original bundle renders (incl. its own Ingress)
  [PASS] default (perHost): patched output is byte-identical to the original
  [PASS] patched templates + OLD values.yaml (no tls key, i.e. an old umbrella) render identically
  [PASS] wildcard mode renders
  [PASS] the bundle's own Ingress: no cert-manager annotation, uses the shared secret
  [PASS] consumer bundle, wildcard mode: 4/4 rendered component apps get the shared secret (fe-authentication-provider, tier1-gateway, users-roles-be, users-roles-fe)
  [PASS] data-provider bundle, wildcard mode: 5/5 rendered component apps get the shared secret (adds consent-management-fe)
  [PASS] data-provider bundle, default (perHost): patched output is byte-identical to the original
  [PASS] bundle source tier1-gateway -> chart tier1-gateway: the rendered values make it use the shared secret and drop the issuer annotation
  [PASS] bundle source fe-authentication-provider -> chart authentication-provider-fe: the rendered values make it use the shared secret and drop the issuer annotation
  [PASS] bundle source users-roles-fe -> chart users-roles-fe: the rendered values make it use the shared secret and drop the issuer annotation
  [PASS] all three component charts were exercised
PLUMBING: ALL CHECKS PASSED
=== EXIT 0: python3 plumbing.py check
################ ./cluster_test.sh
### 0. lab issuer (selfSigned -> CA) and namespaces
  [PASS] ClusterIssuer lab-ca is Ready
### A. TODAY (original charts): 11 consumer hosts, one Ingress each
  cert-manager created 11 Certificate(s), 11 Ready
  [PASS] per-host mode: 11 hosts -> 11 certificates (one ACME order each on a real issuer)
  [PASS] all 11 issued
### A2. TODAY, the six real charts together (5 frontends share one host + the gateway) in poc-real
  ingresses: 6   certificates: 2 (2 Ready)   distinct secrets: 2
### B. WILDCARD MODE (patched charts + agent-tls)
  [PASS] wildcard mode: 11 hosts -> exactly 1 certificate (no per-host certificates were requested)
  [PASS] the wildcard certificate is issued
  [PASS] all 11 Ingresses reference the one shared secret
  certificate SANs: DNS:*.consumer1.dataspace.example.eu,DNS:*.fe.consumer1.dataspace.example.eu,DNS:*.be.consumer1.dataspace.example.eu
  [PASS] covered:     participant.fe.consumer1.dataspace.example.eu
  [PASS] covered:     participant.be.consumer1.dataspace.example.eu
  [PASS] covered:     catalogue-ui.consumer1.dataspace.example.eu
  [PASS] covered:     contract-consumption-be.consumer1.dataspace.example.eu
  [PASS] covered:     xsfc-advsearch-be.consumer1.dataspace.example.eu
  [PASS] covered:     infrastructure-fe.consumer1.dataspace.example.eu
  [PASS] covered:     contract.consumer1.dataspace.example.eu
  [PASS] covered:     contract-ui.consumer1.dataspace.example.eu
  [PASS] covered:     wallet.consumer1.dataspace.example.eu
  [PASS] covered:     simpl.consumer1.dataspace.example.eu
  [PASS] covered:     reporting.consumer1.dataspace.example.eu
  [PASS] not covered: tls.participant.consumer1.dataspace.example.eu
  [PASS] not covered: gitea.crossplane.consumer1.dataspace.example.eu
  [PASS] not covered: consumer1.dataspace.example.eu
  [PASS] not covered: catalogue-ui.consumer2.dataspace.example.eu
  [PASS] not covered: a.b.fe.consumer1.dataspace.example.eu
### B2. WILDCARD MODE, the six real charts in poc-real
  [PASS] 6 real Ingresses on 2 hosts -> 1 certificate
CLUSTER TEST: ALL CHECKS PASSED
=== EXIT 0: ./cluster_test.sh
################ ./cluster_test.sh migrate
  [PASS] ClusterIssuer lab-ca is Ready
### C. MIGRATION: an existing per-host deployment is switched to wildcard mode in place (same Ingress names)
  before: 11 per-host Certificates, 11 TLS secrets
  a per-host Certificate is owned by: Ingress/ing-3
  [PASS] all Ingresses now reference the wildcard secret
  [PASS] wildcard certificate issued
  after:  12 Certificate(s) = 1 wildcard + 11 old per-host (orphaned: no Ingress asks for them any more)
  [PASS] after cleanup: 1 Certificate left (the wildcard)
  [PASS] cert-manager did NOT recreate the per-host Certificates (annotation is gone)
MIGRATION TEST: ALL CHECKS PASSED
=== EXIT 0: ./cluster_test.sh migrate
################ ./serve_test.sh
ingress-nginx: ingress-nginx-controller-64bc687b45-nqxq4 restarts=0 at 172.17.0.2:30443
### 0. lab issuer
  [PASS] ClusterIssuer lab-ca is Ready
### S0. CONTROL: an Ingress whose TLS secret does not exist must be seen as the fake certificate
  [PASS] the test sees nginx's fake certificate and rejects it (it can detect a wrong certificate)
### S1. TODAY (per-host): each of the 11 hosts must be served its OWN certificate (the one in its Secret)
  [PASS] 11/11 hosts served the certificate in their Secret, valid and matching the hostname (slowest: 1s after issue)
  [PASS] 11 distinct certificates (distinct serials)
### S2. WILDCARD: every host must be served the ONE wildcard certificate (the one in its Secret)
  [PASS] 11/11 hosts served the one wildcard certificate (serial 5275611F8A1775F0F1C4095A49A2E8DA5B966D2D), valid and matching each hostname (slowest: 4s after issue)
  [PASS] not served the wildcard / does not verify: tls.participant.consumer1.dataspace.example.eu
  [PASS] not served the wildcard / does not verify: gitea.crossplane.consumer1.dataspace.example.eu
  [PASS] not served the wildcard / does not verify: consumer1.dataspace.example.eu
  [PASS] not served the wildcard / does not verify: catalogue-ui.consumer2.dataspace.example.eu
  [PASS] not served the wildcard / does not verify: a.b.fe.consumer1.dataspace.example.eu
### S3. RENEWAL: duration=1h, renewBefore=58m -> cert-manager renews after ~2 min; nginx must then serve the NEW certificate without a restart
  [PASS] before renewal nginx serves the issued certificate (serial 56F91DB5CB3943795F12A476497187F441CDE78C, revision 1)
  [PASS] cert-manager renewed it after 120s: revision 1 -> 2, serial 56F91DB5CB3943795F12A476497187F441CDE78C -> 1DBDCAA7D72837C824A9E6827CD71EB2EAA98FB8
  [PASS] nginx served the renewed certificate 0s after the Secret changed, still valid for the host
  [PASS] the renewed certificate chains to the CA and matches the host
  [PASS] all 11 hosts serve the renewed certificate
  [PASS] nginx was not restarted (ingress-nginx-controller-64bc687b45-nqxq4 restarts=0)
### S4. ROLLBACK: switch the same 11 Ingresses back to per-host mode
  [PASS] after rollback 11/11 hosts are served their own valid certificate again
  [PASS] no Ingress references the wildcard secret any more
SERVE TEST: ALL CHECKS PASSED
=== EXIT 0: ./serve_test.sh
################ ./acme_test.sh
### 0. images, namespace, TSIG key
  [PASS] images imported; TSIG key created
### 1. BIND: authoritative for dataspace.example.eu, accepts TSIG-signed dynamic updates
  [PASS] BIND is running
### 2. Pebble (ACME test server) that validates DNS-01 against BIND
  [PASS] Pebble is running
  ACME directory: https://10.43.134.141:14000/dir
### 3. cert-manager: resolve DNS-01 propagation against BIND, and two ClusterIssuers (DNS-01 and the guide's default HTTP-01)
  [PASS] cert-manager restarted with its DNS-01 resolver pointed at BIND
  [PASS] ClusterIssuer pebble-dns01 registered an ACME account with Pebble
  [PASS] ClusterIssuer pebble-http01 registered an ACME account with Pebble
### T1. DNS-01: one ACME order for the three wildcard names
  [PASS] wildcard certificate issued by Pebble over DNS-01 in 67s
  [PASS] issuer is Pebble: issuer=CN = Pebble Intermediate CA 6e6c4c
  [PASS] SANs are exactly the three wildcard names
  order state=valid, 3 authorizations: *.be.consumer1.dataspace.example.eu via dns-01; *.consumer1.dataspace.example.eu via dns-01; *.fe.consumer1.dataspace.example.eu via dns-01
  [PASS] the order had 3 wildcard authorizations, each validated through a dns-01 challenge
  BIND saw the challenge records: 6 log line(s) mentioning _acme-challenge
### T2. The guide's DEFAULT issuer (HTTP-01 only) asked for the same wildcard certificate
  [PASS] NOT issued: an HTTP-01-only issuer cannot satisfy a wildcard order
  order state: pending (it never becomes 'failed': it stays pending)
  the only signal is a Warning event: Failed to determine a valid solver configuration for the set of domains on the Order: no configured challenge solvers can be used for this challenge
  certificate condition meanwhile: Issuing certificate as Secret does not exist
  [PASS] the order stays pending (not failed, not valid)
  [PASS] cert-manager's Warning event says it has no solver that can satisfy the challenge (what an operator would have to find)
### T3. Serve the Pebble-issued wildcard through ingress-nginx for the 11 hosts
  chain in the secret: leaf + 1 CA certificate(s)
  [PASS] 11/11 hosts served the ACME-issued wildcard; it verifies for each hostname against the Pebble CA (partial chain: Pebble's CA is the trust anchor)
ACME TEST: ALL CHECKS PASSED
=== EXIT 0: ./acme_test.sh
################ ./browser_test.sh
### 0. lab issuer, a tiny backend, and the lab CA in the browser's trust store
  [PASS] ClusterIssuer lab-ca is Ready
  [PASS] backend is running
  [PASS] lab CA imported into the browser trust store (removed again at the end)
### 1. wildcard certificate and Ingresses
### 2. Chromium
  [PASS] 11/11 covered hosts loaded a real page over HTTPS with normal certificate verification (TLS TLS 1.3)
  [PASS] tls.participant.consumer1.dataspace.example.eu: browser refuses it with ERR_CERT_AUTHORITY_INVALID
  [PASS] gitea.crossplane.consumer1.dataspace.example.eu: browser refuses it with ERR_CERT_AUTHORITY_INVALID
  [PASS] noingress.consumer1.dataspace.example.eu: browser refuses it with ERR_CERT_AUTHORITY_INVALID
  [PASS] ingress-nginx refused the wildcard for tls.participant.consumer1.dataspace.example.eu, logged why, and fell back to its fake certificate
  [PASS] ingress-nginx refused the wildcard for gitea.crossplane.consumer1.dataspace.example.eu, logged why, and fell back to its fake certificate
BROWSER TEST: ALL CHECKS PASSED
=== EXIT 0: ./browser_test.sh
  [PASS] namespaces unchanged: authority01 common01 default kube-node-lease kube-public kube-system
  [PASS] authority01 Ingresses unchanged (7)
  [PASS] no cert-manager CRDs left
  [PASS] all authority01 pods 1/1
  [PASS] lab CA not left in the browser trust store
RUN ALL: EVERYTHING PASSED
```

## Let's Encrypt staging probe (separate run, 2026-11-06)

```
### 0. zone simpl-lab-282f7e2b.eu (random, not registered), local BIND for it
  [PASS] local BIND is running, authoritative for simpl-lab-282f7e2b.eu
  [PASS] cert-manager's DNS-01 self-check resolver is the local BIND
### 1. real Let's Encrypt STAGING: account + wildcard order, DNS-01 solved through the local BIND
  [PASS] registered an account with Let's Encrypt staging: https://acme-staging-v02.api.letsencrypt.org/acme/acct/366594573
  waiting for Let's Encrypt to try to validate (up to 4 minutes)...
  order state=invalid; 3 authorizations; wildcard=3; challenge types offered by Let's Encrypt: ['dns-01', 'dns-persist-01']
  challenge fe.consumer1.simpl-lab-282f7e2b.eu         type=DNS-01 presented=False state=invalid
     Let's Encrypt/cert-manager reason: Error accepting authorization: acme: authorization error for fe.consumer1.simpl-lab-282f7e2b.eu: 400 urn:ietf:params:acme:error:dns: DNS problem: NXDOMAIN looking up TXT for _acme-challenge.fe.consumer1.simpl-lab-282f7e2b.eu - check that a DNS record exists for this domain
  challenge be.consumer1.simpl-lab-282f7e2b.eu         type=DNS-01 presented=False state=pending
  challenge consumer1.simpl-lab-282f7e2b.eu            type=DNS-01 presented=False state=invalid
     Let's Encrypt/cert-manager reason: Error accepting authorization: acme: authorization error for consumer1.simpl-lab-282f7e2b.eu: 400 urn:ietf:params:acme:error:dns: DNS problem: NXDOMAIN looking up TXT for _acme-challenge.consumer1.simpl-lab-282f7e2b.eu - check that a DNS record exists for this domain
  [PASS] Let's Encrypt accepted an order with 3 wildcard names
  [PASS] for wildcard names Let's Encrypt offered no http-01 (offered: ['dns-01', 'dns-persist-01']): a default HTTP-01 issuer can never get one
  [PASS] cert-manager published all 3 challenge TXT records in the local BIND, TSIG-signed (3 added, 3 removed again after the failure)
  [PASS] Let's Encrypt REJECTED the validation with a DNS error: it looked in the public DNS, not in our local BIND
  [PASS] no certificate was issued
LET'S ENCRYPT PROBE: ALL CHECKS PASSED
=== EXIT 0
=== DONE
```


## Whole-agent chart level (`fullchain.sh`, helm only)

```
components_check.py   52/52   (16 component charts, 17 versions; default identical, wildcard covers every cert-requesting Ingress, control fails)
bundles_check.py      48/48   (18 umbrella/bundle charts)
leaves_check.py       26 covered, 60 no Ingress, 1 no TLS block, 0 gaps; CONTROL=1 on the unpatched charts: 26 gaps
```
