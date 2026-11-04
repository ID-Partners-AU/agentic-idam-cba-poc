# The self-hosted Trust Controller (in place of Raidiam Connect)

This branch of the PoC (`oidf-federation`) runs with no Raidiam. `demo/federation` is a Go service on
[`go-openid-federation`](https://github.com/MichaelFraser99/go-openid-federation) v0.11.0, and it is everything the PoC
used Raidiam for. Everything is at `https://host.docker.internal:9443` (`FED_BASE_URL`), with a TLS certificate from the
rig's CA:

| Path | Raidiam's equivalent | Who uses it |
|---|---|---|
| `/anchor` | the CBA trust anchor | PingFederate and every agent pin its keys (`.federation.env`) |
| `/authority` (`fetch`, `list`, `resolve`) | the CBA authority | PingFederate's superior; vouches for every entity |
| `/openid_relying_party/<statement id>` | `rp.directory.cba.raidiam.io/openid_relying_party/<id>` | Principal versions: the Entity Configurations it hosts and signs |
| `/keystore/<org>/<statement id>/application.jwks` | `keystore.directory.cba.raidiam.io/...` | the `jwks_uri` of each statement: its certified keys, with `x5c` |
| `/directory[/participants]` | `data.directory.cba.raidiam.io/participants` | agents and resources find PingFederate's issuer (`AUTHORISATION_SERVER_ID`) |
| `/api/organisations/...` | `matls-api.directory.cba.raidiam.io` | the marketplace: software statements, CSR → certificate, authority claims |

`127.0.0.1:9444` serves the same in plain HTTP, for `rig.sh`, along with two extras:
- `/api/_state` shows every statement, its policy and the pinned anchor keys.
- `/api/_verify?sub=…` builds and resolves a chain with the library's client.

## What changed from `agentic-idam-poc`

- `poc.env` has no Raidiam values, no tunnel and no directory client:
  - `PF_BASE_URL=https://host.docker.internal:9031`.
  - The federation URLs point here.
  - `RAIDIAM_GRANT=none`.
  - `POC_NAME=agentic-oidf`, so the original PoC's containers and volumes are left alone.
- `./rig.sh federation` is a new step of `up`, run before PingFederate. It does three things:
  - starts this service;
  - pins its anchor (`.federation.env`, read by every later step);
  - runs `seed.py`, which registers the rig's own entities:
    - the sub-agents and the resource servers each get a statement;
    - their keys are certified from CSRs;
    - the sub-agents get their roles and SPIFFE bindings, and the resources get their `oauth_resource` policy.

  These are the steps that used to be done by hand in Raidiam's website, and `./rig.sh csrs` is gone.
- PingFederate needs no registration. The authority vouches for the authorisation server named by
  `AUTHORISATION_SERVER_ID`, with keys it reads from PingFederate's own Entity Configuration once PingFederate is up.
- The marketplace is unchanged apart from `raidiam-auth.js`, whose `RAIDIAM_GRANT=none` skips the sign-in.
- `harness.py` reaches `host.docker.internal` through `localhost` and trusts the rig's CA. The host's hosts-file entry
  for that name can be stale; set `HOST_VIA_LOCALHOST=0` to undo this.

## How it builds the authority's policy (as Raidiam does)

For each Active statement with a certified key:

- **Value policies** on `openid_relying_party`, set from the statement's own fields:
  - `client_name`, `client_uri`, `logo_uri`, `software_version`, `redirect_uris`;
  - `jwks_uri`, which points at the keystore.
- **The SPIFFE binding**, from `AdditionalSoftwareMetadata`:
  - `spiffe_id`, `spiffe_trust_domain`, `spiffe_bundle_endpoint`, `spiffe_bundle_format`, `client_attesters`;
  - each is `null` when absent, so no leaf can claim one for itself;
  - an agent with a binding also gets the agent grant types and `backchannel_token_delivery_mode`.
- **Capabilities:** the union of its roles' `authorization_details_types`. The role catalogue is `roleCapabilities`
  in `main.go`:

  | Role | Grants |
  |---|---|
  | `cba.accounts.reader` | `accounts_read` |
  | `cba.payments.initiator` | `payment_initiation` |
  | `Payments-Execution` | `payment_initiation`, `accounts_write` |
  | `cba.supplier.reader` | `supplier_invoice`, `supplier_payment` |
  | `cba.oidc.participant` | `openid_credential` |

- **`FederationMetadataPolicy`** on the statement, which is an extension (Raidiam derives the resources' policy from
  `ApiResources`). It is used for the resources' `oauth_resource` policy.

A Suspended statement is no longer vouched for: it drops out of `/list`, and `/fetch` answers `not_found`.

## Build note

Module downloads go through `proxy.golang.org`. Behind TLS inspection (Avast on the dev laptop), put the inspecting
root CA in `build-ca/*.pem`; it's git-ignored and used in the build stage only.
