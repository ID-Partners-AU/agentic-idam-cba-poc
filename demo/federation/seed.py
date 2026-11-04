#!/usr/bin/env python3
"""Registers the rig's own entities with the self-hosted Trust Controller, as they are registered in Raidiam: a software
statement each (ClientId = its Entity Identifier), its keys certified from CSRs (entity, and the sub-agents' bridge
keys), its roles, the sub-agents' SPIFFE bindings, and the resources' oauth_resource policy. Idempotent: an entity
already registered is brought up to date, and a key already certified is not certified again.

Environment (rig.sh exports poc.env): FED_API (default http://localhost:9444/api), RAIDIAM_ORGANISATION_ID,
PF_BASE_URL, RAIDIAM_PROVIDER_ID, RAIDIAM_RESOURCE_ID, RAIDIAM_PAYMENTS_RESOURCE_ID, TRUST_DOMAIN.
"""
import glob
import json
import os
import sys
import urllib.request

DEMO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.environ.get("FED_API", "http://localhost:9444/api").rstrip("/")
ORG = os.environ.get("RAIDIAM_ORGANISATION_ID", "CBA-123")
PF = os.environ["PF_BASE_URL"].rstrip("/")
PROVIDER = os.environ.get("RAIDIAM_PROVIDER_ID", "https://host.docker.internal:8443").rstrip("/")
TD = os.environ.get("TRUST_DOMAIN", "example.org")
SPIRE_KEYS = os.environ.get("SPIRE_BUNDLE_URL", "https://host.docker.internal:8445/keys")


def call(method, path, body=None, content_type="application/json"):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(API + path, data=data, method=method, headers={"content-type": content_type})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"seed: {method} {path} -> {e.code} {e.read().decode()[:400]}")


def csr(keyfile, ssid):
    """A CSR for the key in keyfile, as the rig's raidiam/*.sh csr makes it: CN = the statement id."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.x509.oid import NameOID
    key = serialization.load_pem_private_key(open(keyfile, "rb").read(), password=None)
    subject = x509.Name([x509.NameAttribute(NameOID.COUNTRY_NAME, "AU"),
                         x509.NameAttribute(NameOID.ORGANIZATION_NAME, "PoC Trust Framework"),
                         x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, ORG),
                         x509.NameAttribute(NameOID.COMMON_NAME, ssid)])
    return x509.CertificateSigningRequestBuilder().subject_name(subject).sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM)


def resource_policy(types, description, keywords):
    return {"oauth_resource": {
        "authorization_details_types_supported": {"essential": True, "subset_of": types},
        "authorization_servers": {"essential": True, "subset_of": [PF]},
        "bearer_methods_supported": {"subset_of": ["header"]},
        "description": {"default": description},
        "dpop_bound_access_tokens_required": {"value": True},
        "keywords": {"default": keywords},
        "resource": {"essential": True},
    }}


def spiffe(name):
    return {"spiffe_id": f"spiffe://{TD}/{name}", "spiffe_trust_domain": TD,
            "spiffe_bundle_endpoint": SPIRE_KEYS, "client_attesters": [PF]}


ENTITIES = [
    {"id": f"{PROVIDER}/agent/accounts-agent", "name": "POC Accounts Agent",
     "keys": f"keys/raidiam/agents/accounts-agent", "roles": ["cba.accounts.reader", "cba.oidc.participant"],
     "asm": spiffe("accounts-agent"),
     "policy": resource_policy(["accounts_read", "payment_initiation"], "Reads business accounts and balances for a Principal agent, on its behalf",
                               ["accounts", "balances", "agent"])},
    {"id": f"{PROVIDER}/agent/payments-agent", "name": "POC Payments Agent", "keys": f"keys/raidiam/agents/payments-agent",
     "roles": ["Payments-Execution", "cba.supplier.reader", "cba.accounts.reader", "cba.payments.initiator", "cba.oidc.participant"],
     "asm": spiffe("payments-agent"), "policy": None},
    {"id": os.environ.get("RAIDIAM_RESOURCE_ID", "https://host.docker.internal:8446").rstrip("/"), "name": "POC Business Banking Accounts",
     "keys": "keys/raidiam/rs-accounts", "roles": [], "asm": None,
     "policy": resource_policy(["accounts_read"], "Business accounts and balances.", ["accounts", "balances"])},
    {"id": os.environ.get("RAIDIAM_PAYMENTS_RESOURCE_ID", "https://host.docker.internal:8447").rstrip("/"), "name": "POC Business Banking Payments",
     "keys": "keys/raidiam/rs-payments", "roles": [], "asm": None,
     "policy": resource_policy(["payment_initiation"], "Initiates supplier payments from a business account within the policy's limits.",
                               ["supplier payment", "payment initiation"])},
]


def main():
    existing = {s["ClientId"]: s for s in call("GET", f"/organisations/{ORG}/softwarestatements")}
    for e in ENTITIES:
        body = {
            "ClientName": e["name"], "Description": f"{e['name']} - the PoC's own entity, serving its Entity Configuration",
            "ClientUri": e["id"], "RedirectUri": [e["id"] + "/callback"], "SoftwareVersion": "1", "Mode": "Live",
            "Environment": "Sandbox", "OpenidFederationEnabled": True,
            "OpenidFederationEntityManagementType": "openid_entity_federation_self_managed",
            "TokenEndpointAuthMethod": "private_key_jwt", "ClientId": e["id"],
            "AdditionalSoftwareMetadata": json.dumps(e["asm"]) if e["asm"] else None,
            "FederationMetadataPolicy": e["policy"] or {},
        }
        if e["id"] in existing:
            ssid = existing[e["id"]]["SoftwareStatementId"]
            call("PUT", f"/organisations/{ORG}/softwarestatements/{ssid}", {**existing[e["id"]], **body})
            verb = "updated"
        else:
            ssid = call("POST", f"/organisations/{ORG}/softwarestatements", body)["SoftwareStatementId"]
            verb = "created"
        # Its keys, certified from CSRs the rig's scripts make (CN = the statement id), as Raidiam certifies rtssigning keys.
        have = {c["n"] for c in call("GET", f"/organisations/{ORG}/softwarestatements/{ssid}/certificates") if c.get("n")}
        # Its keys, certified from CSRs (CN = the statement id), as Raidiam certifies rtssigning keys.
        certified = 0
        for keyfile in sorted(glob.glob(os.path.join(DEMO, e["keys"], "*.key.pem"))):
            cert = call("POST", f"/organisations/{ORG}/softwarestatements/{ssid}/certificates/rtssigning",
                        csr(keyfile, ssid), "application/x-pem-file")
            certified += cert.get("n") not in have
        for role in e["roles"]:
            call("POST", f"/organisations/{ORG}/softwarestatements/{ssid}/authorityclaims",
                 {"Role": role, "AuthorisationDomain": "CBA-Global", "Status": "Active"})
        print(f"seed: {verb} {e['id']} (statement {ssid}; {certified} key(s) newly certified; roles {', '.join(e['roles']) or 'none'})")


if __name__ == "__main__":
    sys.exit(main())
