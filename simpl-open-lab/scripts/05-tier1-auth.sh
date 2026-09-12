#!/usr/bin/env bash
# Demonstrate a REAL authenticated Tier-1 call to identity-provider.
#
# Finding: Tier-1 auth is CLAIMS-BASED and trusts the gateway. identity-provider's
# AuthServiceImpl (simpl-spring-boot-starter) reads the bearer token via
# TierOneAuthInfoJwtPersister.loadFromSignedJWT — which only PARSES claims; it does
# NOT verify the RS256 signature (the tier1-gateway is the OIDC validator upstream).
# So a token with the correct CLAIM SHAPE is accepted regardless of signature.
#
# The Tier-1 token contract (claim names the backend requires):
#   sub                 participant/user id
#   idp                 auth provider: "SIMPL_AUTH" or "EIDAS"
#   client-roles        JSON array of roles (Roles.*: APPLICANT, SIMPL_USER,
#                       ONBOARDING_MANAGER, TIER_1_AUTHORIZATION_MANAGER,
#                       TIER_1_USER_AND_ROLES_MANAGER, TIER_2_AUTHORIZATION_MANAGER,
#                       TIER_2_IDENTITY_ATTRIBUTES_MANAGER)
#   identity_attributes JSON array (ABAC attributes; [] is valid)
#   credential_id       the participant's active credential id (from the credential table)
#   email, given_name, family_name, preferred_username, sid
#
# In production, the tier1-gateway validates the real Keycloak OIDC token and forwards
# it (with these claims populated by Keycloak protocol mappers). This script mints an
# equivalently-shaped token to exercise the backend directly.
source "$(dirname "$0")/env.sh"

PID="${1:?usage: 05-tier1-auth.sh <participantId> [credentialId]}"
CREDID="${2:-}"
if [ -z "$CREDID" ]; then
  export PGPASSWORD=authority_identityprovider
  CREDID=$(psql -h 127.0.0.1 -p $PG_PORT -U authority_identityprovider -d authority_identityprovider -tA \
    -c "select credential_id from credential where participant_id='$PID' limit 1;" 2>/dev/null | tr -d ' ')
fi

TOK=$(python3 - "$PID" "$CREDID" <<'PY'
import json,base64,sys,time
pid,cid=sys.argv[1],sys.argv[2]
b64=lambda o:base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b'=').decode()
now=int(time.time())
hdr={"alg":"RS256","typ":"JWT","kid":"local"}
pl={"sub":pid,"idp":"SIMPL_AUTH",
    "client-roles":["APPLICANT","SIMPL_USER","ONBOARDING_MANAGER",
                    "TIER_1_AUTHORIZATION_MANAGER","TIER_1_USER_AND_ROLES_MANAGER",
                    "TIER_2_AUTHORIZATION_MANAGER","TIER_2_IDENTITY_ATTRIBUTES_MANAGER"],
    "email":"applicant@acme.example","preferred_username":"applicant",
    "given_name":"Ada","family_name":"Lovelace","sid":"sess-1","identity_attributes":[],
    "iat":now,"exp":now+3600}
if cid: pl["credential_id"]=cid
print(f"{b64(hdr)}.{b64(pl)}.{b64({'sig':'x'})}")
PY
)

log "authenticated GET /tier1/v2/participants/$PID/credentials"
curl -s -m10 -H "Authorization: Bearer $TOK" \
  "http://localhost:$IDENTITY_PROVIDER_PORT/tier1/v2/participants/$PID/credentials?page=0&size=5" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('HTTP OK — credentials total:',d.get('total'),'| status:',(d.get('_embedded') or d))" 2>/dev/null \
  || echo "(see raw response above)"
