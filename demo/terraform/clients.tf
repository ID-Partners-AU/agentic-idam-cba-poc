# The clients the conformance suite acts as, and the one the SSF servlet acts as.
#
# Public halves only. ../gen-keys.sh writes the key pairs to ../keys/ (git-ignored); PF gets the
# *.public.jwks.json here and the suite gets the *.private.jwks.json in its configuration.

locals {
  suite_callbacks = [for base in var.suite_base_urls : "${base}/test/a/${var.suite_alias}/callback"]

  # The suite gives its second client a redirect URI with a query string, and checks the parameters
  # come back on the callback - an AS that matched redirect URIs loosely, or rebuilt them, would drop
  # them. PF matches exactly, so each client is registered with the form the suite sends for it.
  fapi2_redirect_uris = {
    client1 = local.suite_callbacks
    client2 = [for uri in local.suite_callbacks : "${uri}?dummy1=lorem&dummy2=ipsum"]
  }
}

# ── FAPI 2.0 Security Profile: private_key_jwt + DPoP ───────────────────────────────────────────
#
# Two of them because the plan needs a second client to show that a code, a request_uri and a token
# issued to the first are no use to anyone else. They differ in id, key and redirect URI only.
resource "pingfederate_oauth_client" "fapi2" {
  for_each = toset(["client1", "client2"])

  client_id = "conformance-fapi2-${each.key}"
  name      = "Conformance suite - FAPI 2.0 ${each.key}"

  grant_types   = ["AUTHORIZATION_CODE", "REFRESH_TOKEN"]
  redirect_uris = local.fapi2_redirect_uris[each.key]

  # Confidential, and authenticated by a key rather than a shared secret.
  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = {
    # Compact: PF re-serialises a JWKS, so a pretty-printed one never reads back equal.
    jwks = jsonencode(jsondecode(file("${path.module}/../keys/fapi2-${each.key}.public.jwks.json")))
  }

  # The per-client half of the profile (oauth-server.tf has the rest).
  require_pushed_authorization_requests = true
  require_proof_key_for_code_exchange   = true
  require_dpop                          = true
  restricted_response_types             = ["code"] # the wire value; PF rejects "CODE"

  restrict_scopes   = true
  restricted_scopes = ["openid", "profile", "email", "offline_access"]

  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  oidc_policy = {
    id_token_signing_algorithm = "PS256"
    policy_group               = { id = pingfederate_openid_connect_policy.this.id }
  }

  # The consent page stays. One module in the plan has the user refuse, and a client that skips the
  # page gives them nothing to refuse on.
  bypass_approval_page = false

  depends_on = [pingfederate_oauth_server_settings.this]
}

# ── Shared Signals: the suite as a receiver ─────────────────────────────────────────────────────
#
# Gets a token by client credentials, then manages streams with it. private_key_jwt again, so the
# archive holds no secret for it. Not DPoP-bound: the SSF servlet takes a plain bearer token, and
# requiring DPoP here would issue tokens the transmitter has no means of checking the binding on.
resource "pingfederate_oauth_client" "ssf_receiver" {
  client_id = "conformance-ssf-receiver"
  name      = "Conformance suite - SSF receiver"

  grant_types = ["CLIENT_CREDENTIALS"]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = {
    jwks = jsonencode(jsondecode(file("${path.module}/../keys/ssf-receiver.public.jwks.json")))
  }

  restrict_scopes  = true
  exclusive_scopes = ["ssf.manage"]

  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  depends_on = [
    pingfederate_oauth_server_settings.this,
    pingfederate_oauth_access_token_mapping.client,
  ]
}

# ── Shared Signals: the operator that raises events ─────────────────────────────────────────────
#
# The CAEP Interop plan creates a stream, verifies it, and then waits for someone to "trigger these
# events on the transmitter now" - three of them, one of which (device-compliance-change) PingFederate
# never observes. suite/trigger-caep-events.py raises them through POST /ssf/events:emit with a token
# from this client. It holds ssf.provision and nothing else, and authenticates with a secret rather
# than a key so that a stdlib-only script can get its token: the secret reaches the script from
# secrets.env, and the archive holds it obfuscated like the introspection client's.
resource "pingfederate_oauth_client" "ssf_emitter" {
  client_id = "conformance-ssf-emitter"
  name      = "Conformance run - SSF event operator"

  grant_types = ["CLIENT_CREDENTIALS"]

  client_auth = {
    type   = "SECRET"
    secret = var.ssf_emitter_client_secret
  }

  restrict_scopes  = true
  exclusive_scopes = ["ssf.provision"]

  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  depends_on = [
    pingfederate_oauth_server_settings.this,
    pingfederate_oauth_access_token_mapping.client,
  ]
}

# ── Shared Signals: the servlet as a resource server ────────────────────────────────────────────
#
# The servlet cannot validate a receiver's token itself; it asks PF (RFC 7662), and PF wants to know
# who is asking. This client can do that and nothing else - it has no grant that yields a token. Its
# secret reaches the running rig as OIDF_SSF_INTROSPECTION_CLIENT_SECRET, which is why it is a secret
# and not a key: SsfConfiguration takes an id and a secret and speaks HTTP Basic.
resource "pingfederate_oauth_client" "ssf_introspection" {
  client_id = "conformance-ssf-rs"
  name      = "SSF servlet - token introspection"

  grant_types = ["ACCESS_TOKEN_VALIDATION"]

  client_auth = {
    type   = "SECRET"
    secret = var.ssf_introspection_client_secret
  }
}
