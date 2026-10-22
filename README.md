# Agentic IDAM PoC

A runnable proof of concept for *Agentic IDAM - Trust Controller PoC Objectives* (10 July 2026). Agents are
governed through an agent marketplace, identified through OpenID Federation with Raidiam as the Trust Controller,
attested on SPIRE's word, and given sender-constrained tokens by PingFederate. A gateway and a PDP enforce every
call, and Shared Signals carry lifecycle events within seconds.

- [`demo/COMPONENTS.md`](demo/COMPONENTS.md): every component - what it is, what it does, why it matters.
- [`demo/flows.md`](demo/flows.md): each objective, what proves it, and its flow as a sequence diagram, plus the
  parties and why each is needed.
- The marketplace's **Objectives** page (http://localhost:3000/objectives) shows the live evidence for each objective.
- [`AWS.md`](AWS.md): deploying the PoC on AWS - the agents on EKS, PingFederate on EKS or ECS.

## What runs

| Component | Where | Port |
|---|---|---|
| PingFederate + the OpenID Federation modules (token endpoint, attester, SSF transmitter) | `demo/`, `image/` | 9031 (runtime), 9999 (admin) |
| SPIRE server and agent | `spire/` | 8081 |
| SPIRE OIDC provider (the trust domain's live keys) | `demo/spire-workload` | 8445 |
| The agents' gateway (Kong): the sub-agents' Entity Configurations and MCP, and the marketplace's Raidiam sign-in | `demo/spire-workload`, `demo/gateway/kong` | 8443 |
| Resources (rs-accounts, rs-payments) behind Kong + coaz-pep | `demo/spire-workload`, `demo/gateway` | 8446, 8447 |
| Accounts and Payments agents (sub-agents) | `demo/spire-workload` | (behind 8443) |
| PingAuthorize (PDP) and its PAP | `demo/gateway/pingauthorize` | 8448 (PAP) |
| OpenBao (the agents' bridge keys) | `demo/openbao` | 8200 |
| Agent marketplace (control centre) | `demo/marketplace` | 3000 |

Every container, image, network and volume is prefixed with `POC_NAME` (default `agentic-poc`).

There is no agent provider. Raidiam hosts the Principal agents' Entity Configurations, the sub-agents serve their own,
PingFederate's attester reads every agent's SPIFFE binding from Raidiam, and PingFederate registers each agent from its
trust chain at its first attested token request ([`demo/flows.md`](demo/flows.md), "Without an agent provider").

## Prerequisites

- **Docker** (Docker Desktop on Windows or macOS), with 8 GB of memory for it.
- **Tools on the host:** `bash`, `terraform` (1.5+), `node` (20+), `python3`, `openssl`, `curl`, `unzip`, and a JDK's
  `keytool` (17+).
- **Ping licences:** Ping DevOps credentials, in a `KEY=VALUE` file with `PING_IDENTITY_DEVOPS_USER` and
  `PING_IDENTITY_DEVOPS_KEY` (default `~/.pingidentity/config`). PingAuthorize and its PAP fetch evaluation licences
  with them. PingFederate can too, or take a licence file of your own instead ("Licensing PingFederate", below).
- **A public URL for PingFederate's issuer,** e.g. an ngrok tunnel to port 9031, **up whenever the PoC runs**.
  Raidiam fetches PingFederate's discovery document and Entity Configuration from it, external members of the
  federation reach PingFederate through it, and PingFederate itself uses it: its token endpoint trusts its own
  attester by fetching its own Entity Configuration from the issuer. With the URL down, every attested token request
  fails with `invalid_client` ("the subject's Entity Configuration was not presented and could not be fetched").
  `./rig.sh harness` checks it first.
- **Raidiam:** access to the federation's directory as an administrator of the organisation the PoC registers under,
  and a **directory client** for the marketplace (see below).

## Licensing PingFederate

The PingFederate image carries no licence. It is licensed one of two ways, chosen in `poc.env`:

| | Ping DevOps credentials (default) | A licence file |
|---|---|---|
| `poc.env` | `PING_DEVOPS_CONFIG` | `PF_LICENSE_FILE=/path/to/pingfederate.lic` |
| What PingFederate does at start-up | fetches an evaluation licence from Ping | uses the file; calls nobody |
| Lasts | about seven days, renewed at each start | as long as the licence Ping issued you |
| Suits | trying the PoC | keeping it running, or a host that cannot reach Ping's licence service |

**How the licence file works.** The base Ping image's licence hook fetches an evaluation licence only when the server
has no `pingfederate.lic`, and its bootstrap copies everything under `/opt/in` over the server before that hook runs.
So a file at

```
/opt/in/instance/server/default/conf/pingfederate.lic
```

is the licence PingFederate starts with, and the DevOps credentials are never used for it. With `PF_LICENSE_FILE`
set, `./rig.sh pingfederate` (and `./rig.sh up`) puts it there in both PingFederates the PoC starts:

- the **authoring** PingFederate that Terraform configures on the first run: `demo/author.sh` copies the file into
  it before it starts;
- the **running** PingFederate: `demo/docker-compose.license.yml` mounts the file read-only, on every start.

Then `./rig.sh check`, and `./rig.sh pingfederate --author` if PingFederate was already authored with an evaluation
licence. Requirements:

- The licence must cover **PingFederate 13.1** (the file's `Version` line says what it covers). An expired licence,
  or one for another version, leaves PingFederate unlicensed, with the reason in `docker logs agentic-poc-pingfederate`.
- PingFederate's user (uid 9031, gid 0) must be able to read the file. On Linux, `chmod 644 pingfederate.lic`.
- Keep it out of git: `*.lic` is ignored, but it is simplest kept outside this directory.

**The same outside the PoC**, in your own deployment of the image: mount the file at the path above, read-only, and
keep setting `PING_IDENTITY_ACCEPT_EULA=YES` (the image accepts Ping's licence agreement for nobody).

```yaml
# Docker Compose
services:
  pingfederate:
    environment:
      PING_IDENTITY_ACCEPT_EULA: "YES"
    volumes:
      - ./pingfederate.lic:/opt/in/instance/server/default/conf/pingfederate.lic:ro
```

```yaml
# Kubernetes: kubectl create secret generic pingfederate-license --from-file=pingfederate.lic
volumeMounts:
  - name: license
    mountPath: /opt/in/instance/server/default/conf/pingfederate.lic
    subPath: pingfederate.lic
    readOnly: true
volumes:
  - name: license
    secret:
      secretName: pingfederate-license
```

With a server profile, put it at `instance/server/default/conf/pingfederate.lic` in the profile. Never `COPY` a
licence into an image: every layer goes wherever the image goes.

PingAuthorize and its PAP are licensed separately and keep using `PING_DEVOPS_CONFIG`.

## Setting it up

### 1. Settings

```sh
./rig.sh init          # writes poc.env from poc.env.example
```

Fill in `poc.env`. Each setting is explained in the file. The required ones are `PF_BASE_URL`, `TRUST_ANCHOR_JWKS`,
`AUTHORISATION_SERVER_ID`, `RAIDIAM_DIRECTORY_CLIENT_ID` and `RAIDIAM_DIRECTORY_SIGNING_KID`; add `PF_LICENSE_FILE` to
license PingFederate with a file.

Put the directory client's keys in `demo/keys/raidiam/directory-client/`:

| File | What |
|---|---|
| `signing.key` | its `rtssigning` key (PEM), for `private_key_jwt` |
| `transport.crt`, `transport.key` | its `rtstransport` certificate and key, for mutual TLS |
| `ca.pem` | the directory's TLS chain |

Then:

```sh
./rig.sh check
```

### 2. Raidiam (once)

Under your organisation in Raidiam:

1. **PingFederate's authorisation server.** Create a record whose `Issuer` is `PF_BASE_URL`, and put its id in
   `poc.env` (`AUTHORISATION_SERVER_ID`). PingFederate's federation signing key must be one Raidiam certifies:
   `demo/raidiam/pf-signing.sh csr`, upload it at organisation level as a `server_signing` certificate, then
   `demo/raidiam/pf-signing.sh import <certificate>`.
2. **Software statements** for the entities that serve their own metadata - the two sub-agents and the two
   resources. Each is **Self managed** (`OpenidFederationEntityManagementType: openid_entity_self_managed`), with
   `ClientId` exactly as in `poc.env`, `private_key_jwt`, related to PingFederate's authorisation server,
   `Environment: Sandbox`. The sub-agents also need their SPIFFE binding and roles ("Setting up agents in Raidiam",
   below).

   | Entity | ClientId (`poc.env`) | Roles: capabilities it needs |
   |---|---|---|
   | Accounts agent | `<RAIDIAM_PROVIDER_ID>/agent/accounts-agent` | `cba.agentic.member` + one granting `accounts_read` |
   | Payments agent | `<RAIDIAM_PROVIDER_ID>/agent/payments-agent` | `cba.agentic.member` + one granting `payment_initiation` |
   | Accounts resource | `RAIDIAM_RESOURCE_ID` | none |
   | Payments resource | `RAIDIAM_PAYMENTS_RESOURCE_ID` | none |

   The **Principal agents** are not made here: the marketplace creates each Principal version as a **Federation
   managed** statement when you approve it (step 4).
3. **Keys.** Copy `raidiam-statements.env.example` to `raidiam-statements.env` and fill in the statement ids. Then `./rig.sh keys` and `./rig.sh csrs`, and upload each CSR as an `rtssigning` certificate
   on its statement. Each sub-agent has two CSRs, its entity key and its bridge key; each resource has one.
4. **API resources** on PingFederate's authorisation server, each `resource` identical to its statement's
   `ClientId`: the two resources (`interface: mcp`) and the two sub-agents (`interface: agent`), each with
   `authorization_details_types_supported` and `dpop_bound_access_tokens_required: true`. Their API families'
   schemas must allow PingFederate's issuer. `demo/raidiam/README.md` has the bodies.
5. **The marketplace's directory client** must have the redirect URI `https://localhost:8443/cb`.

### 3. Run

```sh
./rig.sh up            # SPIRE, keys, OpenBao, PingFederate (authored and configured on the first run), the services
./rig.sh status
```

The first run takes 10 to 15 minutes, because PingFederate is authored with terraform. After that,
`./rig.sh pingfederate` restarts it with the same configuration in a minute or two.

### 4. Use it

- **Control centre:** http://localhost:3000. Sign in to Raidiam (top right; accept the certificate warning for
  `localhost:8443`, the PoC's own CA), register a **Principal version**, approve it, run its scenarios, suspend and
  reinstate it. The **Objectives** page gathers the evidence.
- **Harness:** `./rig.sh harness` runs the end-to-end checks against the newest Principal version (`--brief` for one
  line per check, `--agent <entity id> --label <workload>` for another version). Its report feeds the Objectives page.

## Setting up agents in Raidiam

Every agent needs four things: a **software statement** in Raidiam, a **SPIFFE identity** in SPIRE, a **bridge key**
that PingFederate signs the agent's client assertions with, and an **Entity Configuration** - its federation metadata,
which says who it is and which keys it uses. PingFederate holds nothing per agent in advance: its attester reads the
agent's SPIFFE binding from Raidiam, and its token endpoint registers the agent from its trust chain at the agent's
first attested token request.

Who hosts the Entity Configuration is set by the statement's management type:

| | **Federation managed** - Raidiam hosts the metadata | **Self managed** - the agent hosts its own metadata |
|---|---|---|
| In the PoC | the Principal agents, created by the marketplace | the Accounts and Payments agents (`demo/spire-workload/sub_agent.py`) |
| The agent's Entity Identifier | Raidiam's: `https://rp.directory.cba.raidiam.io/openid_relying_party/<statement id>` | yours: the statement's `ClientId`, an HTTPS URL you serve |
| Its Entity Configuration | served and signed by Raidiam | served by the agent at `<entity id>/.well-known/openid-federation`, signed with its own entity key |
| Keys certified in Raidiam (`rtssigning`) | one: the bridge key | two: the entity key and the bridge key |
| Who can resolve it | anyone, Raidiam's own resolver included | only those who can reach it - in a protected network, PingFederate and your own components ([PROTECTED-ENVIRONMENTS.md](demo/raidiam/PROTECTED-ENVIRONMENTS.md)) |
| Adding one | approve a version in the marketplace; no restart | the steps below; PingFederate restarts to learn its bridge key |

### What every agent needs

- **The SPIFFE binding**, on the statement's `AdditionalSoftwareMetadata`. Raidiam's authority publishes it as value
  policies on the agent's metadata, which no entity can override, and PingFederate's attester attests a JWT-SVID only
  for the agent whose binding names that SPIFFE ID and names PingFederate:

  ```json
  {
    "spiffe_id": "spiffe://example.org/accounts-agent",
    "spiffe_trust_domain": "example.org",
    "spiffe_bundle_endpoint": "https://host.docker.internal:8445/keys",
    "client_attesters": ["<PF_BASE_URL>"]
  }
  ```

  Raidiam keeps at most 255 characters of it, counted on its own re-serialisation, so add nothing else. The bundle
  endpoint is the PoC's SPIRE OIDC provider, which serves SPIRE's current keys. One SPIFFE ID binds one agent.
  Raidiam's API needs `Environment` on the `PUT` that sets it.
- **Its roles**, as authority claims on the statement: `cba.agentic.member` and a capability role. The agent's
  capabilities (`authorization_details_types`) come from these roles, not from fields on the statement.
- **A SPIRE registration entry** for that SPIFFE ID, selected by the agent's workload: `spiffe://example.org/<name>`
  ← `docker:label:app:<name>`. `spire/setup.sh` makes the sub-agents' (add another with
  `WORKLOADS="<name>" ./rig.sh spire`); the marketplace makes each Principal's.
- **Status `Active`.** `Suspended` withdraws the authority's statement about the agent, so its chain stops resolving
  (`Inactive` is not a status Raidiam accepts).

### Federation managed: Raidiam hosts the metadata

Approve a Principal version in the marketplace and it makes everything, through Raidiam's admin API and OpenBao: the
Federation managed statement related to PingFederate, the SPIFFE binding (`spiffe://example.org/agent-<first 8
characters of the statement id>`), the bridge key `bridge-<statement id>` created in OpenBao (OpenBao makes and signs
its CSR; the key is never exported), its `rtssigning` certificate, the roles and the SPIRE entry. It then waits until
Raidiam serves the Entity Configuration and vouches for it. There is no entity key: Raidiam signs the configuration.
Each step and its API call is in [`demo/raidiam/README.md`](demo/raidiam/README.md), "The control centre".

### Self managed: the agent hosts its own metadata

The agent serves its own Entity Configuration, and Raidiam only vouches for it. The PoC's two sub-agents are set up this
way by the steps in "Setting it up"; for another agent `<name>`:

1. **Choose its Entity Identifier**: `<RAIDIAM_PROVIDER_ID>/agent/<name>`, an HTTPS URL PingFederate can reach. It is
   the statement's `ClientId`, which Raidiam does not let you change, and the `client_id` PingFederate registers.
2. **Make its keys**: `AGENT=<name> demo/raidiam/attested-client.sh keys` writes an entity key (it signs the Entity
   Configuration) and a bridge key (PingFederate signs the agent's client assertions with it) under
   `demo/keys/raidiam/agents/<name>/`.
3. **Register it**: a **Self managed** statement as in "Setting it up", step 2, with the binding and roles above. Make
   the CSRs with `AGENT=<name> demo/raidiam/attested-client.sh csr <statement id> "/C=GB/O=CBA Trust Framework/OU=<organisation id>"`
   and upload both as `rtssigning`. An agent other agents call is also a resource: add its API resource as in step 4.
4. **Serve its Entity Configuration** at `<entity id>/.well-known/openid-federation`, as
   `application/entity-statement+jwt`, signed afresh with a short `exp` (the PoC uses an hour). It carries:
   - `iss` and `sub`: the Entity Identifier; `authority_hints`: `[AUTHORITY_HINT]`;
   - `jwks`: the entity key's public half, and a JWS `kid` matching it. The `kid` must be the one **Raidiam** gives the
     key in its statement about the agent (the authority's fetch endpoint, `?sub=<entity id>`), not the key's
     thumbprint: Raidiam names certified keys its own way, and PingFederate looks the `kid` up in what Raidiam vouches
     for;
   - `metadata.openid_relying_party`: `client_registration_types` including `automatic`, `grant_types`,
     `token_endpoint_auth_method: private_key_jwt`, and `jwks`: the **bridge** key's public half;
   - for an agent that is also a resource, `metadata.oauth_resource`, and the same document at
     `<entity id>/.well-known/oauth-protected-resource`.

   The SPIFFE binding is **not** in it: that is Raidiam's word, read from Raidiam. `sub_agent.py` does all of this from
   `AGENT_ID`, `AUTHORITY_HINT`, `ENTITY_KEY_FILE` and `BRIDGE_JWKS_FILE`, looking Raidiam's `kid` up at start-up and
   hourly; add a service for it in `demo/spire-workload/docker-compose.yml` like `accounts-agent`, and a route for
   `/agent/<name>/` in `demo/gateway/kong/agents.yml.template`.
5. **Let PingFederate reach it.** PingFederate's federation fetches trust only the JVM's CA store. A publicly trusted
   certificate needs nothing; the PoC's gateways use its own CA, which `demo/raidiam/render-runtime-keys.sh` adds to
   the store mounted into PingFederate. A private host must be in `OIDF_FETCH_HOST_ALLOWLIST`, which `up.sh` takes
   from `RAIDIAM_PROVIDER_ID`.
6. **Give PingFederate its bridge key**: add `<name>` to `RAIDIAM_HOSTED_AGENTS` in `poc.env` and run
   `./rig.sh pingfederate`, which renders the bridge-keys file afresh and restarts PingFederate. With `RAIDIAM_BRIDGE_BACKING=vault` the key must be in OpenBao as `bridge-<name>`
   (`demo/openbao/setup.py` imports the sub-agents' keys). Terraform knows `accounts-agent` and `payments-agent` as
   resources; a new agent that is a resource needs a token manager of its own, as `demo/terraform/resource.tf` makes
   theirs.
7. **Check it**:

   ```sh
   curl -sk https://localhost:8443/agent/<name>/.well-known/openid-federation    # a JWT: iss = sub = the entity id
   ```

   and that the authority's fetch endpoint answers for `?sub=<entity id>`. PingFederate registers the agent at its first
   attested token request and logs `verified attestation ...`. A restart of PingFederate drops the registrations; each
   agent is registered again at its next attested request.

## Bridge keys in OpenBao

PingFederate authenticates an attested agent with a per-agent **bridge key**: the module signs a `private_key_jwt` for
the agent once its attestation verifies. With `RAIDIAM_BRIDGE_BACKING=vault` (the default) they live in **OpenBao**'s
transit engine, never exported:
- `./rig.sh up` starts OpenBao and runs `demo/openbao/setup.py`, which initialises it, unseals it, writes the two
  policies and their tokens, and imports the sub-agents' bridge keys.
- PingFederate finds each agent's key by name (`bridge-<statement id>` for a Principal, `bridge-<name>` for a
  sub-agent), so a Principal version the marketplace deploys needs **no restart and has no limit**. The marketplace
  creates its key in OpenBao, and OpenBao makes the CSR.
- **PingFederate** may only read and sign with bridge keys.
- **The marketplace** may only create them and get their CSRs. It can never sign with, export or delete a key.

With `RAIDIAM_BRIDGE_BACKING=config` the keys are in a file PingFederate reads at start-up: the sub-agents only, and no
Principal versions.

`demo/openbao/setup.py` needs `python3` with `cryptography` and `PyJWT` on the host. OpenBao keeps its unseal key and
root token in `demo/keys/openbao/` (git-ignored): a development shortcut (see below).

## Development shortcuts

This is a PoC, not a production deployment. `demo/raidiam/PROTECTED-ENVIRONMENTS.md` (section 13) lists every
shortcut and its production equivalent, including:
- inline keys, and the sub-agents' keys in files (production: OpenBao or a KMS);
- the PoC's own CA;
- the marketplace driving Docker through its socket;
- an operator's Raidiam session kept in an unauthenticated Mongo;
- OpenBao unsealed with a key kept on disk.

## Known gaps

- **Raidiam:** writes to its admin API need an operator's session (`directory:website`) until `directory:management`
  is allowed for client credentials (then `RAIDIAM_GRANT=client_credentials`). Raidiam functionality to hold per-statement
  SPIFFE metadata, so the agent provider carries the SPIFFE bindings, is yet to be released. `demo/flows.md` describes the
  production alternative without an Agent Provider component.


## Layout

| Path | What |
|---|---|
| `rig.sh`, `poc.env.example` | the entry point and its settings |
| `AWS.md` | deploying the PoC on AWS (EKS, ECS) |
| `spire/` | SPIRE server and agent, and their set-up |
| `image/` | PingFederate's image build, with the module release (0.7.0) and its staged jars |
| `demo/` | PingFederate's configuration (`up.sh`, `terraform/`, `vars*.env`, `docker-compose.license.yml`) and the PoC's services (`spire-workload/`, `gateway/`, `marketplace/`, `raidiam/`, `openbao/`) |

`demo/README.md` describes the underlying PingFederate rig, which also serves the modules' conformance testing. This
bundle uses its `raidiam` profile only.
