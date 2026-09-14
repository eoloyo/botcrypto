#!/usr/bin/env bash
# Seed a SAP-governed identity attribute assignment so the provider agent's ephemeral proof
# carries a REAL (SAP-issued) attribute instead of an empty set — the authenticity upgrade the
# gateway ABAC on /fc reads decides on (see scripts/10-gated-discovery.sh).
#
# Why "all participants": the reference SAP maps a credential -> participant with a stub,
# ParticipantClientAdapterImpl.findParticipant(CredentialId), which ignores the credential and
# returns the FIRST participant from the identity-provider's listParticipants(0,1). So the proof's
# synced attributes are whichever participant is first. Assigning the attribute to EVERY
# identity-provider participant (there are ~2: the authority and the provider) is robust to that
# ordering and idempotent.
#
# DBs (both on $PG_PORT):
#   authority_identityprovider          (identity-provider participants; user authority_identityprovider)
#   authority_securityattributesprovider (SAP identity_attribute + participant_identity_attribute; user postgres)
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh" 2>/dev/null || true
PGP="${PG_PORT:-5433}"
CODE="${1:-CATALOGUE_SEARCHER}"   # the attribute code to assign (default: the catalogue-searcher right)
log(){ printf '\033[1;34m[seed-sap]\033[0m %s\n' "$*"; }

# 1) participant ids known to the identity-provider (what SAP's listParticipants sees)
PIDS=$(PGPASSWORD=authority_identityprovider psql -h 127.0.0.1 -p "$PGP" \
  -U authority_identityprovider -d authority_identityprovider -tAc "SELECT id FROM participant;" 2>/dev/null || true)
[ -n "$PIDS" ] || { log "no participants found in the identity-provider DB (run enrollment first)"; exit 1; }
log "identity-provider participants: $(echo "$PIDS" | tr '\n' ' ')"

# 2) ensure the CATALOGUE_SEARCHER attribute exists in SAP, capture its id, then assign it to each
#    participant. All in the SAP DB as user postgres.
export PGPASSWORD=postgres
psql -h 127.0.0.1 -p "$PGP" -U postgres -d authority_securityattributesprovider -v ON_ERROR_STOP=1 <<SQL
-- the default changelog seeds CATALOGUE_SEARCHER; insert defensively if a stripped schema lacks it
INSERT INTO identity_attribute (id, code, "name", description, assignable_to_roles, enabled,
                                creation_timestamp, update_timestamp, is_right, built_in, public, federable)
SELECT gen_random_uuid(), '$CODE', initcap(replace('$CODE','_',' ')),
       'act only as a searcher in the catalogue, cannot start a contract negotiation or transfer',
       TRUE, TRUE, now(), now(), TRUE, TRUE, TRUE, TRUE
WHERE NOT EXISTS (SELECT 1 FROM identity_attribute WHERE code='$CODE');
SQL

IAID=$(psql -h 127.0.0.1 -p "$PGP" -U postgres -d authority_securityattributesprovider -tAc \
  "SELECT id FROM identity_attribute WHERE code='$CODE' LIMIT 1;")
[ -n "$IAID" ] || { log "could not resolve identity_attribute id for $CODE"; exit 1; }
log "$CODE identity_attribute id = $IAID"

for pid in $PIDS; do
  psql -h 127.0.0.1 -p "$PGP" -U postgres -d authority_securityattributesprovider -v ON_ERROR_STOP=1 <<SQL >/dev/null
INSERT INTO participant_identity_attribute (participant_id, identity_attribute_id)
VALUES ('$pid', '$IAID') ON CONFLICT DO NOTHING;
SQL
done
log "assigned $CODE to $(echo "$PIDS" | grep -c .) participant(s) in SAP"
psql -h 127.0.0.1 -p "$PGP" -U postgres -d authority_securityattributesprovider -tAc \
  "SELECT p.participant_id, a.code FROM participant_identity_attribute p JOIN identity_attribute a ON a.id=p.identity_attribute_id;" \
  | sed 's/^/  assignment: /'
