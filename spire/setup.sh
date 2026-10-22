#!/usr/bin/env bash
# SPIRE for the PoC, from nothing:
#   1. a CA for node attestation and the agent's certificate (x509pop, CN=agent1) - certs/, git-ignored
#   2. the server, then its trust bundle as the agent's bootstrap bundle
#   3. the agent
#   4. the PoC's registration entries: each SPIFFE ID for containers with a Docker label app=<name>
#
#   ./setup.sh            idempotent: existing certificates and entries are kept
#   ./setup.sh entries    only (re)create the entries
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"
POC_NAME="${POC_NAME:-agentic-poc}"
SERVER="$POC_NAME-spire-server"
TRUST_DOMAIN="${TRUST_DOMAIN:-example.org}"
PARENT="spiffe://$TRUST_DOMAIN/spire/agent/x509pop/agent1"
# The PoC's workloads: the SPIRE OIDC provider, the Principal, the two sub-agents, and another workload the harness
# uses to show a container that is not the agent is refused. Principal versions deployed from the marketplace get
# their entries from the marketplace.
WORKLOADS="${WORKLOADS:-spire-oidc spire-client accounts-agent payments-agent my-workload}"

certs() {
  mkdir -p certs
  [[ -f certs/ca.key ]] || {
    openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/ca.key -out certs/ca.crt -days 365 \
      -subj "/CN=spire-poc-ca" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    echo "made      certs/ca.*"
  }
  [[ -f certs/agent.crt ]] || {
    openssl req -newkey rsa:2048 -nodes -keyout certs/agent.key -out certs/agent.csr -subj "/CN=agent1" 2>/dev/null
    printf 'keyUsage=digitalSignature\n' > certs/agent.ext
    openssl x509 -req -in certs/agent.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial -days 365 \
      -extfile certs/agent.ext -out certs/agent.crt 2>/dev/null
    rm -f certs/agent.csr certs/agent.ext
    echo "made      certs/agent.* (CN=agent1)"
  }
  chmod 600 certs/*.key
  # The containers read these as their own users.
  chmod 644 certs/agent.key certs/agent.crt certs/ca.crt
}

server() {
  docker compose up -d spire-server >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$SERVER" /opt/spire/bin/spire-server healthcheck >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec "$SERVER" /opt/spire/bin/spire-server bundle show > certs/bootstrap.crt
  echo "server    up; its bundle is certs/bootstrap.crt"
}

agent() {
  docker compose up -d spire-agent >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$SERVER" /opt/spire/bin/spire-server agent list 2>/dev/null | grep -q "$PARENT" && { echo "agent     attested as $PARENT"; return; }
    sleep 2
  done
  echo "ERROR: the agent did not attest - docker compose logs spire-agent" >&2
  exit 1
}

entries() {
  for name in $WORKLOADS; do
    id="spiffe://$TRUST_DOMAIN/$name"
    if docker exec "$SERVER" /opt/spire/bin/spire-server entry show -spiffeID "$id" | grep -q "docker:label:app:$name"; then
      echo "kept      $id <- docker:label:app:$name"
    else
      docker exec "$SERVER" /opt/spire/bin/spire-server entry create -spiffeID "$id" -parentID "$PARENT" \
        -selector "docker:label:app:$name" >/dev/null
      echo "created   $id <- docker:label:app:$name"
    fi
  done
}

case "${1:-all}" in
  entries) entries ;;
  all) certs; server; agent; entries ;;
  *) echo "usage: $0 [entries]" >&2; exit 1 ;;
esac
