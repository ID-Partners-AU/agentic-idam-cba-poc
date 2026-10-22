# Authorization-server settings: the half of FAPI 2.0 that PingFederate enforces server-wide.
#
# The other half is per client (clients.tf) - PF decides DPoP, PKCE and the response type client by
# client. Both halves are set, deliberately: a server-wide PAR requirement means a client created later
# without its flags still cannot make a front-channel authorization request.
#
# Clause references are to the FAPI 2.0 Security Profile (Final), authorization server requirements.
resource "pingfederate_oauth_server_settings" "this" {
  # §5.3.2.2: PAR is supported, and an authorization request that did not come through it is rejected.
  par_status = var.par_status
  # §5.3.2.2: request_uri lifetime under 600 seconds. A minute is ample for a redirect.
  par_reference_timeout = 60
  par_reference_length  = 24

  # §5.3.2.2: PKCE with S256. Requiring PKCE is per client; this removes the method that defeats it.
  disallow_plain_pkce = true

  # §5.3.2.2: iss in the authorization response (RFC 9207), which is what stops a mix-up attack.
  include_issuer_in_authorization_response = true

  # §5.3.2.1: authorization codes live at most 60 seconds.
  authorization_code_timeout = 60
  authorization_code_entropy = 30

  # §5.3.2.1: no refresh token rotation. With a confidential client and a sender-constrained token it
  # buys nothing, and it loses the grant whenever a rotated token goes missing in transit.
  roll_refresh_token_values      = false
  refresh_rolling_interval       = 0
  refresh_token_length           = 42
  persistent_grant_lifetime      = -1
  persistent_grant_lifetime_unit = "DAYS"

  # DPoP. A proof is single-use within its lifetime; the nonce stays off because the profile makes it
  # optional and the first runs should fail for one reason at a time.
  dpop_proof_enforce_replay_prevention = true
  dpop_proof_lifetime_seconds          = 120
  dpop_proof_require_nonce             = false

  # Not used here, but required by the API.
  bypass_activation_code_confirmation = false
  device_polling_interval             = 5
  pending_authorization_timeout       = 600
  default_scope_description           = ""

  scopes = [
    { name = "openid", description = "OpenID Connect", dynamic = false },
    { name = "profile", description = "Profile", dynamic = false },
    { name = "email", description = "Email", dynamic = false },
    { name = "offline_access", description = "Refresh tokens", dynamic = false },
  ]

  # Exclusive, so that no client carries it unless clients.tf names it. It is the only thing between
  # a token and every SSF stream this transmitter holds.
  exclusive_scopes = [
    { name = "ssf.manage", description = "Manage Shared Signals streams", dynamic = false },
    # The provisioner scope: raises events and deprovisions subjects across every receiver's streams.
    # Never granted to a receiver - the servlet refuses a configuration where the two are the same.
    { name = "ssf.provision", description = "Raise Shared Signals events", dynamic = false },
  ]
}
