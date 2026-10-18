# EJBCA in the authority-iaa agent: what it is, why it is slow, whether it is needed

## What it is

| | |
|---|---|
| Server image | `keyfactor/ejbca-ce:8.2.0.1`: Keyfactor's prebuilt EJBCA Community Edition image from Docker Hub (built Dec 2023) |
| Inside | EJBCA 8.2.0.1 as an exploded EAR (42 MB, 66 jars, 12 web apps) on **WildFly 26.1.3** (a full Jakarta EE application server, 184 MB), **OpenJDK 11.0.21**, AlmaLinux 8.8. Compressed image: 355 MiB |
| Set-up image | `ejbca-preconfig:1.0.3` (Simpl): `FROM keyfactor/ejbca-ce:8.2.0.1` plus Simpl's certificate profiles, `kubectl` and an `entrypoint.sh`, run as the init container |
| Chart | `ejbca-community-helm` (Simpl): one Deployment; the init container is `ejbca-preconfig` |

## Is it needed?

Yes: it is the dataspace's PKI. The governance authority is the CA that issues every participant's
certificate (tier2 mTLS between agents), and revocation goes through it. What Simpl uses of it:

| Caller | What it uses |
|---|---|
| identity-provider (`EjbcaClientImpl`) | REST v1 `certificate/pkcs10enroll` (issue a participant credential from its CSR), `.../revoke`, `.../revocationstatus`, `ca/{dn}/certificate/download`; REST v2 `certificate/search` |
| tier1-gateway (routes) | public OCSP (`/ocsp` → `publicweb/status/ocsp`), CA certificate and CRL download (`/ca/…`, `/crl/…` → `publicweb/webdist`) |
| ejbca-preconfig | CA hierarchy `SimplCA` → `OnBoardingCA`, 3 certificate profiles + 1 end-entity profile, REST API enabled, identity-provider's mTLS client certificate, written to the `ejbca-rest-api-secret` Secret |

Of the 12 web apps in the EAR, Simpl uses 3 (`ejbca-rest-api`, `status`, `webdist`) plus the health check.
Unused: admin GUI, RA GUI, CMP, SCEP, SOAP web services, Swagger UI, cert/CRL store, clear-cache
(the admin GUI is still useful to an operator).

Replacing EJBCA with a lighter CA would mean changing identity-provider (its EJBCA client, 5 calls),
the tier1 routes and the set-up: no longer the official deployment.

## Why it is slow

Measured in this lab (k3s on gVisor, 4 cores).

**Every start, even with its CAs already in the database** (EJBCA alone restarted on an idle node, 259 s):

| Step | Time | Why |
|---|---|---|
| init container: boot the whole server to ask "already bootstrapped?", then exit | 83 s | `ejbca-preconfig` starts `start.sh` and waits for the deployment and the super admin before it can check |
| main container: WildFly boot and EAR deployment | 55 s | WildFly itself reports "started in 43 s" |
| main container: **reissue its own TLS server certificate** | **107 s** | Keyfactor's `after-deployed.sh` reuses a certificate "from previous runs" stored in `/opt/keyfactor/secrets/persistent`, but **the chart mounts no volume there**, so every start issues a new one from the ManagementCA: ~10 `ejbca.sh` CLI calls, each a new JVM (~7 s each) |
| enable HTTPS on 8443 → startup probe passes | ~10 s | |

**A first install also** (run 3, under full start-up contention, 11.8 min in total):

- creates the ManagementCA (RSA 3072) and super admin (2.75 min),
- runs `ejbca-preconfig`'s ~37 CLI calls, each a new JVM (3.4 min),
- and does all of the above twice, because the init container's server is thrown away.

**Root causes, most important first**

1. **One JVM per CLI call.** `ejbca.sh` starts a new JVM for each command: ~50 calls on a first install,
   ~10 on every start. At 7–12 s each under gVisor, that is most of the time.
2. **The TLS certificate is not persisted** (above): 1¾ min on every start, for a mechanism Keyfactor
   built to be skipped.
3. **Two server boots per pod start:** the init container's check needs a running server.
4. **A full Jakarta EE server for 3 web apps,** on Java 11 without application class-data sharing.
5. **The chart's CPU limit of 500m.** It isn't enforced in this lab; on a cluster that enforces it,
   it throttles all of the above.
6. **gVisor** makes JVM start-up and file-heavy WildFly boots slower than on a plain container runtime.

## Can we build it from source?

Partly, and it would not fix the slowness on its own:

- EJBCA CE's source is public (`github.com/Keyfactor/ejbca-ce`, LGPL), but **only 9.x releases are
  tagged there** (r9.0.0 … r9.6.3). The 8.2.0.1 that Simpl pins cannot be rebuilt from the public tree.
- The repository is the application only (Ant build, 33 modules). The **container layer is not public**:
  `start.sh`, `after-deployed*.sh`, the first-start ManagementCA/super-admin creation and the WildFly
  datasource and TLS set-up. `ejbca-preconfig` depends on exactly those scripts, so a from-source image
  would need that layer re-written too.
- Building from source gives control over the JDK, unused web apps (some have build switches, e.g.
  `crlstore.enabled`) and class-data sharing. But the time goes to JVM launches and TLS reissue, not to
  the size of the EAR.

## What would help, closest to the official deployment first

| Change | Saves | Fidelity |
|---|---|---|
| Persistent volume at `/opt/keyfactor/secrets/persistent` (main and init container) | ~1¾ min on every start after the first | uses Keyfactor's intended mechanism; a chart change |
| CPU limit for EJBCA that matches its start-up work | depends on the cluster | a values change |
| `ejbca-preconfig`: check "already bootstrapped" without booting the server (e.g. a marker on the persistent volume, or the database) | ~1½ min on every start | a change to Simpl's set-up image |
| `ejbca-preconfig`: run the set-up as a Job against the running EJBCA (REST / one CLI session) instead of a second server in an init container | one server boot on first install | a change to Simpl's set-up design |
| EJBCA 9.x on a newer JDK with class-data sharing, unused web apps left out | faster boot; needs measuring | a different EJBCA version; the container layer must be rebuilt |

## Tried: EJBCA 9.6.3 (`keyfactor/ejbca-ce:9.6.3`)

The latest Keyfactor image (Sep 2026): OpenJDK 21, WildFly 39.0.1, AlmaLinux 9.7, the same 12 web apps,
and the same container scripts and paths. Simpl's `ejbca-preconfig` was rebuilt on it
(`build-images.sh EJBCA_BASE=9.6.3`, deployed with `EJBCA_RELEASE=9.6.3`; the official 8.2.0.1
pair stays in the cluster). Docker Hub rate-limits this sandbox; `mirror.gcr.io` serves the image.

**One incompatibility in Simpl's set-up.** EJBCA 9's `ca init` asks for the crypto token's password
even for the existing, auto-activated token the script creates first; EJBCA 8 did not. In a container
it throws (`System.console()` is null), so SimplCA and OnBoardingCA were never created and every later
`ca editca` failed. Passing `--tokenPass` with the PIN the script already gives the tokens fixes it.
Nothing else in the set-up, nor the REST API identity-provider uses, needed changing: the authority's
initialization (keypair, CSR, participant, credential issued by EJBCA 9, credential installed) and
tier2 all worked.

| | 8.2.0.1 | 9.6.3 |
|---|---|---|
| Fresh install, whole agent (runs 3 / 4) | 912 s | 910 s |
| EJBCA set-up done (secret written) | 546 s | 577 s |
| EJBCA alone restarted on an idle node | 259 s | **232 s** |
| … of which TLS certificate reissue | 107 s | 82 s |
| CPU to install (fresh) | 1118 CPU-s | 985 CPU-s |
| Working set | 692 MiB | **877 MiB** |

**Verdict:** a newer EJBCA is not the fix. It is ~10% faster to restart (its CLI JVMs start faster on
Java 21), no faster to install, and uses ~27% more memory. Its time goes to the same places: one JVM
per CLI call, the TLS reissue on every start, and two server boots per pod start. Those are fixed by the
persistent TLS volume and the `ejbca-preconfig` changes above, on either version.
