# Access tokens, ID tokens, and what goes in them.
#
# Three separate PS256 settings exist in PingFederate and they are easy to confuse: the access token's
# signature (here, on the token manager), the client assertion's (clients.tf,
# token_endpoint_auth_signing_algorithm) and the ID token's (clients.tf, oidc_policy). FAPI 2.0 permits
# PS256, ES256 and EdDSA and nothing weaker, for every JWT the server creates or accepts.

resource "pingfederate_oauth_access_token_manager" "jwt" {
  manager_id = "conformanceJwt"
  name       = "Conformance JWT access tokens"

  plugin_descriptor_ref = {
    id = "com.pingidentity.pf.access.token.management.plugins.JwtBearerAccessTokenManagementPlugin"
  }

  configuration = {
    fields = [
      # MINUTES - the plugin descriptor says so ("Defines how long, in minutes"); its default is 120.
      # Ten also keeps an SSF receiver's token under the hour past which the suite warns.
      { name = "Token Lifetime", value = "10" },
      # PF's own rotating OAuth/OIDC keys, the ones published at /pf/JWKS.
      { name = "Use Centralized Signing Key", value = "true" },
      { name = "JWS Algorithm", value = "PS256" },
      { name = "Issuer Claim Value", value = var.pf_base_url },
      { name = "Type Header Value", value = "at+jwt" },
    ]
    tables = []
  }

  attribute_contract = {
    extended_attributes = [
      { name = "sub", multi_valued = false },
    ]
  }
}

# Authorization code grant: the subject is the user who signed in.
resource "pingfederate_oauth_access_token_mapping" "user" {
  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }
  context                  = { type = "DEFAULT" }

  attribute_contract_fulfillment = {
    "sub" = { source = { type = "OAUTH_PERSISTENT_GRANT" }, value = "USER_KEY" }
  }
}

# Client credentials grant (the SSF receiver): there is no user, so the subject is the client.
resource "pingfederate_oauth_access_token_mapping" "client" {
  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }
  context                  = { type = "CLIENT_CREDENTIALS" }

  attribute_contract_fulfillment = {
    "sub" = { source = { type = "CONTEXT" }, value = "ClientId" }
  }
}

resource "pingfederate_openid_connect_policy" "this" {
  policy_id = "conformanceOidc"
  name      = "Conformance OpenID Connect policy"

  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  id_token_lifetime = 5

  attribute_contract = {
    extended_attributes = []
  }

  attribute_mapping = {
    attribute_contract_fulfillment = {
      "sub" = { source = { type = "TOKEN" }, value = "sub" }
    }
  }
}

# Without a default policy, a request for the openid scope is a server_error at the authorization
# endpoint ("No default OpenID Connect Policy found") rather than anything a client could act on.
resource "pingfederate_openid_connect_settings" "this" {
  default_policy_ref = { id = pingfederate_openid_connect_policy.this.id }
}
