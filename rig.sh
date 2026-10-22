#!/usr/bin/env bash
# The Agentic IDAM PoC: one entry point.
#
#   ./rig.sh init          create poc.env from poc.env.example (then fill it in)
#   ./rig.sh check         what the PoC needs: tools, poc.env, licences, the directory client's keys
#   ./rig.sh up            everything, in order: SPIRE, keys, (OpenBao,) PingFederate, the PoC's services
#   ./rig.sh openbao       OpenBao only, with RAIDIAM_BRIDGE_BACKING=vault: start it, unseal, policies, import keys
#   ./rig.sh spire         SPIRE only (spire/setup.sh)
#   ./rig.sh keys          the PoC's keys and certificates only (idempotent: existing ones are kept)
#   ./rig.sh pingfederate  PingFederate only: authored and configured the first time, restarted with the same
#                          configuration after that (--author to author again)
#   ./rig.sh services      the PoC's services only (build and start)
#   ./rig.sh csrs          the CSRs to upload to Raidiam, for the statements listed in raidiam-statements.env
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
  export PF_RIG_NAME="${PF_RIG_NAME:-$POC_NAME-pingfederate}" PF_PROFILE=raidiam
  export SPIRE_BUNDLE_FILE="$HERE/spire/certs/bundle.spiffe.json"
}

require() {
  local missing=()
  for v in PF_BASE_URL TRUST_ANCHOR_JWKS AUTHORISATION_SERVER_ID AUTHORITY_HINT TRUST_ANCHOR \
           RAIDIAM_DIRECTORY_CLIENT_ID RAIDIAM_DIRECTORY_SIGNING_KID; do
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
  for f in signing.key transport.crt transport.key ca.pem; do
    [[ -f "$DEMO/keys/raidiam/directory-client/$f" ]] || { echo "missing demo/keys/raidiam/directory-client/$f"; bad=1; }
  done
  python3 -c 'import json,os,sys; json.loads(os.environ["TRUST_ANCHOR_JWKS"])["keys"]' 2>/dev/null \
    || { echo "TRUST_ANCHOR_JWKS is not a JWK Set"; bad=1; }
  curl -sk --max-time 10 -o /dev/null "$PF_BASE_URL" || echo "note: $PF_BASE_URL does not answer yet (fine before PingFederate is up; Raidiam needs it reachable)"
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
  # SPIRE's OIDC Discovery Provider: a certificate from the rig's CA, which PingFederate and the agents trust.
  local d="$DEMO/keys/raidiam/spire-oidc" ca="$DEMO/keys/pf-runtime-tls-ca"
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
    docker compose build agent
    docker compose up -d --build "${SERVICES[@]}" )
  # No agent provider: PingFederate registers each agent from its trust chain at its first attested token request.
  echo "marketplace: http://localhost:${MARKETPLACE_PORT:-3000}  (sign in to Raidiam there)"
}

csrs() {
  load
  local f="$HERE/raidiam-statements.env"
  [[ -f "$f" ]] || die "no raidiam-statements.env: copy raidiam-statements.env.example and fill in the statement ids"
  # shellcheck disable=SC1090
  . "$f"
  [[ -z "${ACCOUNTS_AGENT_SSID:-}" ]] || AGENT=accounts-agent "$DEMO/raidiam/attested-client.sh" csr "$ACCOUNTS_AGENT_SSID" "/C=GB/O=CBA Trust Framework/OU=$RAIDIAM_ORGANISATION_ID"
  [[ -z "${PAYMENTS_AGENT_SSID:-}" ]] || AGENT=payments-agent "$DEMO/raidiam/attested-client.sh" csr "$PAYMENTS_AGENT_SSID" "/C=GB/O=CBA Trust Framework/OU=$RAIDIAM_ORGANISATION_ID"
  [[ -z "${RS_ACCOUNTS_SSID:-}" ]] || RESOURCE=rs-accounts "$DEMO/raidiam/resource.sh" csr "$RS_ACCOUNTS_SSID" "/C=GB/O=CBA Trust Framework/OU=$RAIDIAM_ORGANISATION_ID"
  [[ -z "${RS_PAYMENTS_SSID:-}" ]] || RESOURCE=rs-payments "$DEMO/raidiam/resource.sh" csr "$RS_PAYMENTS_SSID" "/C=GB/O=CBA Trust Framework/OU=$RAIDIAM_ORGANISATION_ID"
  echo "upload each as an rtssigning certificate on its statement (Raidiam website, or POST .../certificates/rtssigning with Accept: */*)"
}

case "${1:-}" in
  init)
    [[ -f "$HERE/poc.env" ]] && die "poc.env exists"
    cp "$HERE/poc.env.example" "$HERE/poc.env"; echo "wrote poc.env - fill in the REQUIRED values" ;;
  check) check ;;
  up) load; require; spire; keys; openbao; pingfederate; services ;;
  openbao) load; openbao ;;
  spire) load; spire ;;
  keys) load; keys ;;
  pingfederate) load; require; pingfederate "${2:-}" ;;
  services) load; require; services ;;
  csrs) csrs ;;
  harness) load; shift; cd "$DEMO/spire-workload" && exec python3 harness.py "$@" ;;
  status) load; docker ps --filter "name=$POC_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
  down)
    load
    ( cd "$DEMO/spire-workload" && docker compose down )
    ( cd "$DEMO" && COMPOSE_FILE="docker-compose.yml:docker-compose.raidiam.yml" COMPOSE_PROJECT_NAME="$PF_RIG_NAME" docker compose down )
    ( cd "$HERE/spire" && docker compose down ) ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
