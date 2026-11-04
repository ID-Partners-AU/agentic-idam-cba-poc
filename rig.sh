#!/usr/bin/env bash
# The Agentic IDAM PoC: one entry point.
#
#   ./rig.sh init          create poc.env from poc.env.example (then fill it in)
#   ./rig.sh check         what the PoC needs: tools, poc.env, licences
#   ./rig.sh up            everything, in order: SPIRE, keys, the Trust Controller, (OpenBao,) PingFederate, the
#                          PoC's services
#   ./rig.sh federation    the self-hosted Trust Controller only (demo/federation, in place of Raidiam Connect): start
#                          it, pin its anchor (.federation.env), register the rig's own entities (demo/federation/seed.py)
#   ./rig.sh openbao       OpenBao only, with RAIDIAM_BRIDGE_BACKING=vault: start it, unseal, policies, import keys
#   ./rig.sh spire         SPIRE only (spire/setup.sh)
#   ./rig.sh keys          the PoC's keys and certificates only (idempotent: existing ones are kept)
#   ./rig.sh pingfederate  PingFederate only: authored and configured the first time, restarted with the same
#                          configuration after that (--author to author again)
#   ./rig.sh services      the PoC's services only (build and start)
#   ./rig.sh harness [..]  the end-to-end harness (spire-workload/harness.py); its report feeds the marketplace
#   ./rig.sh status        what is running
#   ./rig.sh down          stop everything (volumes and keys are kept)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEMO="$HERE/demo"
# Git Bash on Windows: ":" between compose files (it splits on ";" by default). MSYS_NO_PATHCONV only where a
# docker argument is a container path - set globally, it breaks the host paths node and terraform are given.
export COMPOSE_PATH_SEPARATOR=":"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

load() {
  [[ -f "$HERE/poc.env" ]] || die "no poc.env - run ./rig.sh init and fill it in"
  set -a
  # shellcheck disable=SC1091
  . "$HERE/poc.env"
  set +a
  # The anchor's keys, pinned from the self-hosted Trust Controller by ./rig.sh federation (a placeholder before then,
  # so docker compose can read its files).
  if [[ -f "$HERE/.federation.env" ]]; then . "$HERE/.federation.env"; else TRUST_ANCHOR_JWKS='{"keys":[]}'; fi
  export TRUST_ANCHOR_JWKS
  export PF_RIG_NAME="${PF_RIG_NAME:-$POC_NAME-pingfederate}" PF_PROFILE=raidiam
  export SPIRE_BUNDLE_FILE="$HERE/spire/certs/bundle.spiffe.json"
}

require() {
  local missing=()
  for v in PF_BASE_URL AUTHORISATION_SERVER_ID AUTHORITY_HINT TRUST_ANCHOR; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  ((${#missing[@]} == 0)) || die "poc.env: set ${missing[*]}"
}

check() {
  load
  local bad=0
  for tool in docker terraform node python3 openssl curl unzip keytool; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool"; bad=1; }
  done
  docker info >/dev/null 2>&1 || { echo "docker is not running"; bad=1; }
  require || bad=1
  # PingFederate takes a licence file (PF_LICENSE_FILE) or fetches an evaluation licence; PingAuthorize and its PAP
  # always fetch theirs with the DevOps credentials.
  [[ -z "${PF_LICENSE_FILE:-}" || -f "$PF_LICENSE_FILE" ]] || { echo "PF_LICENSE_FILE=$PF_LICENSE_FILE is not a file"; bad=1; }
  [[ -f "${PING_DEVOPS_CONFIG/#\~/$HOME}" ]] || { echo "no Ping DevOps credentials at $PING_DEVOPS_CONFIG (PingAuthorize needs them${PF_LICENSE_FILE:+; PingFederate uses PF_LICENSE_FILE})"; bad=1; }
  [[ -f "$HERE/.federation.env" ]] || echo "note: no .federation.env yet - ./rig.sh federation (or up) pins the anchor"
  ((bad == 0)) && echo "ready" || die "fix the above first"
}

spire() {
  say "SPIRE"
  "$HERE/spire/setup.sh"
  MSYS_NO_PATHCONV=1 docker exec "$POC_NAME-spire-server" /opt/spire/bin/spire-server bundle show -format spiffe > "$SPIRE_BUNDLE_FILE"
  echo "bundle    spire/certs/bundle.spiffe.json (PingFederate's attestation client)"
}

keys() {
  say "keys"
  # The rig's runtime CA, PingFederate's keys and secrets (up.sh would make them too; the others below need the CA).
  "$DEMO/gen-keys.sh" >/dev/null
  "$DEMO/raidiam/gen-keys.sh" >/dev/null
  "$DEMO/raidiam/attested-client.sh" keys                       # the gateways' TLS certificate (8443, 8446, 8447)
  # The sub-agents' entity and bridge keys. Principal versions have none here: Raidiam hosts them, and the marketplace
  # creates each one's bridge key in OpenBao when it deploys it.
  for agent in $RAIDIAM_HOSTED_AGENTS; do AGENT="$agent" "$DEMO/raidiam/attested-client.sh" keys; done
  for rs in rs-accounts rs-payments; do RESOURCE="$rs" "$DEMO/raidiam/resource.sh" keys; done
  "$DEMO/gateway/gen-keys.sh"
  local ca="$DEMO/keys/pf-runtime-tls-ca"
  # The self-hosted Trust Controller's TLS certificate, from the rig's CA, which PingFederate and every agent trust.
  local f="$DEMO/keys/federation"
  if [[ ! -f "$f/tls.crt" ]]; then
    mkdir -p "$f"
    ( cd "$f" && umask 077
      export MSYS2_ARG_CONV_EXCL="/CN="
      openssl req -new -newkey rsa:2048 -nodes -keyout tls.key -subj "/CN=host.docker.internal" -out tls.csr 2>/dev/null
      printf 'subjectAltName=DNS:host.docker.internal,DNS:localhost,DNS:federation\nextendedKeyUsage=serverAuth\n' > tls.ext
      openssl x509 -req -in tls.csr -CA "$ca.crt" -CAkey "$ca.key" -CAcreateserial -days 397 -extfile tls.ext -out tls.crt 2>/dev/null
      rm -f tls.csr tls.ext; chmod 644 tls.crt tls.key )
    echo "generated keys/federation/tls.* (from the rig's runtime CA)"
  fi
  # Mounted by the marketplace; the self-hosted API wants no directory client keys, so it stays empty.
  mkdir -p "$DEMO/keys/raidiam/directory-client"
  # SPIRE's OIDC Discovery Provider: a certificate from the rig's CA, which PingFederate and the agents trust.
  local d="$DEMO/keys/raidiam/spire-oidc"
  if [[ ! -f "$d/tls.crt" ]]; then
    mkdir -p "$d"
    ( cd "$d" && umask 077
      export MSYS2_ARG_CONV_EXCL="/CN="   # Git Bash would rewrite the subject as a Windows path
      openssl req -new -newkey rsa:2048 -nodes -keyout tls.key -subj "/CN=host.docker.internal" -out tls.csr 2>/dev/null
      printf 'subjectAltName=DNS:host.docker.internal,DNS:localhost,DNS:spire-oidc\nextendedKeyUsage=serverAuth\n' > tls.ext
      openssl x509 -req -in tls.csr -CA "$ca.crt" -CAkey "$ca.key" -CAcreateserial -days 397 -extfile tls.ext -out tls.crt 2>/dev/null
      rm -f tls.csr tls.ext; chmod 644 tls.crt tls.key )
    echo "generated keys/raidiam/spire-oidc/tls.* (from the rig's runtime CA)"
  fi
}

federation() {
  say "Trust Controller (self-hosted, demo/federation)"
  ( cd "$DEMO/spire-workload" && docker compose up -d --build federation )
  local api="http://localhost:${FED_ADMIN_PORT:-9444}/api" state=""
  for _ in $(seq 1 60); do state="$(curl -sf "$api/_state" 2>/dev/null)" && break; sleep 2; done
  [[ -n "$state" ]] || die "the Trust Controller did not answer on $api"
  # The anchor's keys, pinned: what PingFederate and every agent trust a chain to end at.
  TRUST_ANCHOR_JWKS="$(printf '%s' "$state" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["trust_anchor_jwks"],separators=(",",":")))')"
  printf "# Written by ./rig.sh federation: the self-hosted anchor's keys, pinned. Not a secret.\nTRUST_ANCHOR_JWKS='%s'\n" \
    "$TRUST_ANCHOR_JWKS" > "$HERE/.federation.env"
  export TRUST_ANCHOR_JWKS
  echo "anchor    $TRUST_ANCHOR (keys pinned in .federation.env)"
  echo "authority $AUTHORITY_HINT"
  FED_API="$api" python3 "$DEMO/federation/seed.py"
  # PingFederate's static signing key, certified by the directory at organisation level (server_signing), as Raidiam
  # certified it: terraform/signing-keys.tf authors it, and PingFederate signs its Entity Configuration with it.
  local ps="$DEMO/keys/raidiam/pf-signing"
  if [[ ! -f "$ps/signing.p12" ]]; then
    "$DEMO/raidiam/pf-signing.sh" csr >/dev/null
    curl -sf -X POST -H 'content-type: application/x-pem-file' --data-binary @"$ps/signing.csr" \
      "$api/organisations/${RAIDIAM_ORGANISATION_ID:-CBA-123}/certificates/server_signing" \
      | python3 -c 'import json,sys;sys.stdout.write(json.load(sys.stdin)["PemCertificate"])' > "$ps/directory.crt.pem"
    "$DEMO/raidiam/pf-signing.sh" import "$ps/directory.crt.pem"
  fi
}

openbao() {
  # Principal versions need it: their bridge keys exist only in the vault.
  [[ "${RAIDIAM_BRIDGE_BACKING:-vault}" == vault ]] || return 0
  say "OpenBao (bridge keys)"
  ( cd "$DEMO/spire-workload" && docker compose up -d openbao )
  OPENBAO_ADDR="http://localhost:8200" python3 "$DEMO/openbao/setup.py"
}

pingfederate() {
  say "PingFederate ($PF_RIG_NAME, issuer $PF_BASE_URL)"
  # The bundle ships the module jars staged (image/modules), so they are never re-staged; after the first run, the
  # configuration archive (demo/data.zip) is reused too, unless --author.
  local mode=(SKIP_BUILD=1)
  [[ "${1:-}" == --author || ! -f "$DEMO/data.zip" ]] || mode+=(SKIP_AUTHOR=1)
  ( cd "$DEMO" && env "${mode[@]}" ./up.sh )
}

SERVICES=(spire-oidc rs-accounts rs-payments accounts-agent payments-agent coaz-pep pingauthorize
          pingauthorize-pap gateway gateway-payments gateway-agents marketplace)

services() {
  say "services"
  [[ "${RAIDIAM_BRIDGE_BACKING:-vault}" != vault ]] || SERVICES=(openbao "${SERVICES[@]}")
  ( cd "$DEMO/spire-workload"
    # PingAuthorize from a licence file, when there is one (demo/licences/, git-ignored), rather than a fetched one.
    [[ ! -f "$DEMO/licences/PingAuthorize.lic" ]] || export COMPOSE_FILE="docker-compose.yml:docker-compose.licences.yml"
    docker compose build agent
    docker compose up -d --build "${SERVICES[@]}" )
  # No agent provider: PingFederate registers each agent from its trust chain at its first attested token request.
  echo "marketplace: http://localhost:${MARKETPLACE_PORT:-3000}  (Trust Controller: $TRUST_ANCHOR)"
}

case "${1:-}" in
  init)
    [[ -f "$HERE/poc.env" ]] && die "poc.env exists"
    cp "$HERE/poc.env.example" "$HERE/poc.env"; echo "wrote poc.env - fill in the REQUIRED values" ;;
  check) check ;;
  up) load; require; spire; keys; federation; openbao; pingfederate; services ;;
  federation) load; require; federation ;;
  openbao) load; openbao ;;
  spire) load; spire ;;
  keys) load; keys ;;
  pingfederate) load; require; pingfederate "${2:-}" ;;
  services) load; require; services ;;
  harness) load; shift; cd "$DEMO/spire-workload" && exec python3 harness.py "$@" ;;
  status) load; docker ps --filter "name=$POC_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
  down)
    load
    ( cd "$DEMO/spire-workload" && docker compose down )
    ( cd "$DEMO" && COMPOSE_FILE="docker-compose.yml:docker-compose.raidiam.yml" COMPOSE_PROJECT_NAME="$PF_RIG_NAME" docker compose down )
    ( cd "$HERE/spire" && docker compose down ) ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
