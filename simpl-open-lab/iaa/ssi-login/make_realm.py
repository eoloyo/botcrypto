#!/usr/bin/env python3
"""make_realm.py <shipped-realm.json> <out.json> <verifier-url> <users-roles-url>

Takes the realm export shipped with ssi-verifier-keycloak-extension (local/keycloak/import/
realm-authority.json, realm `authority`, identity provider `oid4vp`) and points the identity provider
at the lab's walt.id verifier and Users and Roles stand-in, instead of the public walt.id demo
verifier and microcks. Adds a public test client `lab-app` (authorization-code flow) to log in with."""
import json
import sys

src, out, verifier, users_roles = sys.argv[1:5]
realm = json.load(open(src))

for idp in realm["identityProviders"]:
    if idp["providerId"] == "oid4vp":
        idp["displayName"] = "Verifiable Credentials"
        idp["config"].update({
            "credentialVerifierServiceEndpoint": verifier,
            "usersAndRolesServiceEndpoint": users_roles,
            "clientId": "lab", "clientSecret": "lab",
            "checkAcceptedCredentialsConfigurationOnSave": "false",
        })

realm["clients"] = [c for c in realm.get("clients", []) if c.get("clientId") != "lab-app"]
realm["clients"].append({
    "clientId": "lab-app", "name": "Lab test application", "enabled": True,
    "publicClient": True, "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
    "redirectUris": ["http://localhost:9999/*"], "webOrigins": ["+"],
    "attributes": {"pkce.code.challenge.method": "S256"},
})
json.dump(realm, open(out, "w"), indent=1)
print(f"realm {realm['realm']}: idp oid4vp -> verifier {verifier}, users-roles {users_roles}; client lab-app")
