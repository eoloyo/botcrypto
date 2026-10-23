#!/usr/bin/env python3
"""eosc_aai.py — the researcher's login for the EOSC → DestinE pilot, on the lab Keycloak.

  eosc_aai.py setup <kc-url>               two realms:
      eosc-aai        stand-in for the EOSC federated AAI (MS4): a researcher from a university,
                      with an eduPersonEntitlement for a climate research group
      consumer-agent  the Simpl consumer agent's Tier-1 Keycloak, which brokers logins to eosc-aai
                      (OIDC identity provider) and copies the entitlement into its own token
  eosc_aai.py login <kc-url> <token-file> [user]
                      log a user in (default a.researcher) through the broker, headless
                      (the browser's redirects and the login form, done with a cookie jar), and
                      write the consumer agent's access token

Credentials are lab-only constants.
"""
import base64
import http.cookiejar
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ENTITLEMENT = "urn:geant:eosc-federation.eu:group:climate-adaptation-research#aai.eosc.eu"
# a.researcher is in the climate research group; b.student, same university, is not
USERS = {
    "a.researcher": {"password": "researcher", "email": "a.researcher@uni.example.eu",
                     "firstName": "Alex", "lastName": "Researcher", "entitlement": [ENTITLEMENT]},
    "b.student": {"password": "student", "email": "b.student@uni.example.eu",
                  "firstName": "Bo", "lastName": "Student", "entitlement": []},
}
BROKER_SECRET = "eosc-broker-secret"
CALLBACK = "http://localhost:8799/callback"
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(method, url, token=None, body=None, form=None):
    headers = {}
    data = None
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    if form is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        data = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with local.open(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw and raw[:1] in b"{[" else raw)
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def admin_token(kc):
    _, t = call("POST", f"{kc}/realms/master/protocol/openid-connect/token",
                form={"grant_type": "password", "client_id": "admin-cli", "username": "admin", "password": "admin"})
    return t["access_token"]


def ensure(code, what):
    ok = code in (200, 201, 204, 409)
    print(f"  {what}: {'ok' if code != 409 else 'exists'}" if ok else f"  {what}: HTTP {code}")
    if not ok:
        sys.exit(1)


def attribute_mapper(name, attribute, claim):
    return {"name": name, "protocol": "openid-connect", "protocolMapper": "oidc-usermodel-attribute-mapper",
            "config": {"user.attribute": attribute, "claim.name": claim, "multivalued": "true",
                       "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true",
                       "jsonType.label": "String"}}


def setup(kc):
    t = admin_token(kc)
    a = f"{kc}/admin/realms"
    for realm in ("eosc-aai", "consumer-agent"):
        ensure(call("POST", a, t, {"realm": realm, "enabled": True})[0], f"realm {realm}")
        # Keycloak 26 drops attributes that are not in the user profile unless this is enabled
        _, profile = call("GET", f"{a}/{realm}/users/profile", t)
        profile["unmanagedAttributePolicy"] = "ENABLED"
        ensure(call("PUT", f"{a}/{realm}/users/profile", t, profile)[0], f"{realm} user profile")

    # eosc-aai: the users and the client the consumer agent's broker uses
    for name, p in USERS.items():
        attributes = {"schac_home_organization": ["uni.example.eu"]}
        if p["entitlement"]:
            attributes["eduperson_entitlement"] = p["entitlement"]
        ensure(call("POST", f"{a}/eosc-aai/users", t, {
            "username": name, "email": p["email"], "firstName": p["firstName"], "lastName": p["lastName"],
            "enabled": True, "emailVerified": True, "attributes": attributes,
            "credentials": [{"type": "password", "value": p["password"], "temporary": False}]})[0], f"eosc-aai user {name}")
    ensure(call("POST", f"{a}/eosc-aai/clients", t, {
        "clientId": "simpl-consumer-agent", "secret": BROKER_SECRET, "publicClient": False,
        "standardFlowEnabled": True, "redirectUris": [f"{kc}/realms/consumer-agent/broker/eosc-aai/endpoint"],
        "protocolMappers": [attribute_mapper("entitlement", "eduperson_entitlement", "eduperson_entitlement"),
                            attribute_mapper("home org", "schac_home_organization", "schac_home_organization")]})[0],
        "eosc-aai client for the consumer agent")

    # consumer-agent: broker to eosc-aai, copy the claims into user attributes, expose them again
    base = f"{kc}/realms/eosc-aai/protocol/openid-connect"
    ensure(call("POST", f"{a}/consumer-agent/identity-provider/instances", t, {
        "alias": "eosc-aai", "displayName": "EOSC AAI", "providerId": "oidc", "enabled": True,
        "trustEmail": True, "config": {
            "authorizationUrl": f"{base}/auth", "tokenUrl": f"{base}/token", "userInfoUrl": f"{base}/userinfo",
            "jwksUrl": f"{base}/certs", "issuer": f"{kc}/realms/eosc-aai", "validateSignature": "true",
            "useJwksUrl": "true", "clientId": "simpl-consumer-agent", "clientSecret": BROKER_SECRET,
            "clientAuthMethod": "client_secret_post", "defaultScope": "openid email profile", "syncMode": "FORCE"}})[0],
        "consumer-agent identity provider eosc-aai")
    mappers = f"{a}/consumer-agent/identity-provider/instances/eosc-aai/mappers"
    existing = {m["name"] for m in call("GET", mappers, t)[1]}
    for claim in ("eduperson_entitlement", "schac_home_organization"):
        if claim in existing:  # Keycloak answers 400, not 409, for a duplicate mapper
            print(f"  broker mapper {claim}: exists")
            continue
        ensure(call("POST", mappers, t, {
            "name": claim, "identityProviderAlias": "eosc-aai", "identityProviderMapper": "oidc-user-attribute-idp-mapper",
            "config": {"claim": claim, "user.attribute": claim, "syncMode": "FORCE"}})[0], f"broker mapper {claim}")
    ensure(call("POST", f"{a}/consumer-agent/clients", t, {
        "clientId": "eu-node-notebook", "publicClient": True, "standardFlowEnabled": True,
        "redirectUris": [CALLBACK],
        "protocolMappers": [attribute_mapper("entitlement", "eduperson_entitlement", "eduperson_entitlement"),
                            attribute_mapper("home org", "schac_home_organization", "schac_home_organization")]})[0],
        "consumer-agent client eu-node-notebook")


class StopAtCallback(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if newurl.startswith(CALLBACK):
            raise LookupError(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class LabCookies(http.cookiejar.DefaultCookiePolicy):
    """Keycloak marks its session cookies Secure; a browser on http://localhost still sends them
    (localhost counts as a secure context), Python's cookie jar does not."""
    def return_ok_secure(self, cookie, request):
        return True


def login(kc, out, user="a.researcher"):
    jar = http.cookiejar.CookieJar(policy=LabCookies())
    browser = urllib.request.build_opener(urllib.request.ProxyHandler({}), StopAtCallback(),
                                          urllib.request.HTTPCookieProcessor(jar))
    auth = f"{kc}/realms/consumer-agent/protocol/openid-connect"
    start = auth + "/auth?" + urllib.parse.urlencode({
        "client_id": "eu-node-notebook", "redirect_uri": CALLBACK, "response_type": "code",
        "scope": "openid", "kc_idp_hint": "eosc-aai"})
    page = browser.open(start, timeout=30)
    print("  1) consumer agent sent the browser to:", urllib.parse.urlparse(page.url).path)
    action = re.search(r'id="kc-form-login"[^>]*action="([^"]+)"', page.read().decode()).group(1).replace("&amp;", "&")
    try:
        browser.open(action, urllib.parse.urlencode(
            {"username": user, "password": USERS[user]["password"]}).encode(), timeout=30)
        sys.exit("login did not reach the callback (first-login form shown?)")
    except LookupError as done:
        code = urllib.parse.parse_qs(urllib.parse.urlparse(str(done.args[0])).query)["code"][0]
    print(f"  2) {user} authenticated at eosc-aai; broker returned an authorization code")
    _, tok = call("POST", auth + "/token", form={"grant_type": "authorization_code", "client_id": "eu-node-notebook",
                                                  "code": code, "redirect_uri": CALLBACK})
    claims = json.loads(base64.urlsafe_b64decode(tok["access_token"].split(".")[1] + "=="))
    print("  3) consumer-agent token: iss=%s user=%s" % (claims["iss"], claims.get("preferred_username")))
    print("     eduperson_entitlement =", claims.get("eduperson_entitlement"))
    print("     schac_home_organization =", claims.get("schac_home_organization"))
    open(out, "w").write(tok["access_token"])


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "setup":
        setup(sys.argv[2].rstrip("/"))
    elif len(sys.argv) in (4, 5) and sys.argv[1] == "login":
        login(sys.argv[2].rstrip("/"), *sys.argv[3:])
    else:
        sys.exit(__doc__)
