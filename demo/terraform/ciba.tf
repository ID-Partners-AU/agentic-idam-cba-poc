# CIBA (OpenID Connect Client Initiated Backchannel Authentication), for the FAPI-CIBA plan.
#
# PingFederate implements CIBA itself - the backchannel endpoint, poll and ping, signed request
# objects, the hint rules. What it does not ship is an authentication device: the only OOB
# authenticator in the product wants a PingOne tenant and a phone. plugins/ciba-sim is the stand-in,
# an OOBAuthPlugin that answers whatever an operator recorded at POST /ciba-sim/decision, which is the
# endpoint the conformance suite calls to say allow or deny. Nothing is approved by default.
#
# Two things the suite wants this server cannot give, on any PingFederate 13.x: certificate-bound access
# tokens (RFC 8705 §3, cnf.x5t#S256) and tls_client_certificate_bound_access_tokens in discovery. Both
# were looked for in every jar of 13.0.3 and 13.1.3 and are not there. Two modules fail on that and
# nothing here can change it; README.md lists them.

# The authenticator: plugins/ciba-sim, staged into the authoring container by author.sh so the
# descriptor exists when this is applied. The instance carries the one attribute the identity hint
# mapping fills, as the repro this was taken from did.
resource "pingfederate_oauth_out_of_band_auth_plugin" "sim" {
  plugin_id = "cibaSim"
  name      = "Conformance CIBA simulator"

  plugin_descriptor_ref = {
    id = "com.pingidentity.ps.oidf.cibasim.SimOobAuthenticator"
  }

  configuration = {
    fields = []
    tables = []
  }

  attribute_contract = {
    extended_attributes = [{ name = "subject" }]
  }
}

# The request policy: who the login_hint names becomes the grant's user. The suite sends
# login_hint=suite-user (client.hint_type / client.hint_value in the suite configuration), and the same
# DEFAULT access-token mapping the browser flow uses turns USER_KEY into the token's sub.
resource "pingfederate_oauth_ciba_server_policy_request_policy" "suite" {
  policy_id = "conformanceCiba"
  name      = "Conformance CIBA policy"

  authenticator_ref = { id = pingfederate_oauth_out_of_band_auth_plugin.sim.id }

  # Seconds. The suite's longest wait (auth-req-id-expired) is bounded by expires_in, so short is fine.
  transaction_lifetime            = 180
  allow_unsigned_login_hint_token = false
  require_token_for_identity_hint = false

  identity_hint_contract = {
    extended_attributes = []
  }
  identity_hint_contract_fulfillment = {
    attribute_contract_fulfillment = {
      "IDENTITY_HINT_SUBJECT" = { source = { type = "REQUEST" }, value = "IDENTITY_HINT_SUBJECT" }
    }
  }
  identity_hint_mapping = {
    attribute_contract_fulfillment = {
      "USER_KEY" = { source = { type = "REQUEST" }, value = "IDENTITY_HINT_SUBJECT" }
      "subject"  = { source = { type = "REQUEST" }, value = "IDENTITY_HINT_SUBJECT" }
    }
  }
}

# Without a default policy the backchannel endpoint answers every request with a server error.
resource "pingfederate_oauth_ciba_server_policy_settings" "this" {
  default_request_policy_ref = { id = pingfederate_oauth_ciba_server_policy_request_policy.suite.id }
}

# ── FAPI-CIBA ID1: two clients, private_key_jwt, signed requests ────────────────────────────────
#
# Two because the plan needs a second client to show a request object signed by one is no use to the
# other. They are FAPI 1.0 Advanced clients: PS256 everywhere, signed backchannel requests required,
# no user code, and a refresh token for the refresh module. No PAR, PKCE or DPoP - those are
# front-channel and FAPI 2.0 rules, and CIBA has no front channel. Deliberately NOT in
# OIDF_FAPI2_CLIENTS: FAPI 1.0 lets a client assertion name the token endpoint as its audience, and
# one module checks exactly that.
resource "pingfederate_oauth_client" "ciba" {
  for_each = toset(["client1", "client2"])

  client_id = "conformance-ciba-${each.key}"
  name      = "Conformance suite - FAPI-CIBA ${each.key}"

  grant_types = ["CIBA", "REFRESH_TOKEN"]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = {
    jwks = jsonencode(jsondecode(file("${path.module}/../keys/ciba-${each.key}.public.jwks.json")))
  }

  ciba_delivery_mode                    = var.ciba_delivery_mode
  ciba_notification_endpoint            = var.ciba_delivery_mode == "PING" ? "${var.ciba_notification_suite_base_url}/test/a/${var.suite_alias}/ciba-notification-endpoint" : null
  ciba_polling_interval                 = 2
  ciba_require_signed_requests          = true
  ciba_request_object_signing_algorithm = "PS256"
  ciba_user_code_supported              = false
  request_policy_ref                    = { id = pingfederate_oauth_ciba_server_policy_request_policy.suite.id }

  restrict_scopes   = true
  restricted_scopes = ["openid", "profile", "email", "offline_access"]

  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  oidc_policy = {
    id_token_signing_algorithm = "PS256"
    policy_group               = { id = pingfederate_openid_connect_policy.this.id }
  }

  # There is no page to approve on; the simulator is the approval.
  bypass_approval_page = true

  depends_on = [pingfederate_oauth_server_settings.this]
}
