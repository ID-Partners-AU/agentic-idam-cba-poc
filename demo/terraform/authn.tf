# How the suite's browser becomes a user: one account, one HTML form.
#
# The suite drives this page itself (the `browser` block of its configuration types the username and
# password and presses the button), so the form has to stay the stock one - the selectors in
# ../suite/*.template.json are written against it. It is the only adapter mapped to a grant, which is
# what lets PF use it without an authentication policy choosing for it.

resource "pingfederate_password_credential_validator" "suite_user" {
  validator_id = "conformanceUsers"
  name         = "Conformance suite user"

  plugin_descriptor_ref = {
    id = "org.sourceid.saml20.domain.SimpleUsernamePasswordCredentialValidator"
  }

  attribute_contract = {}

  configuration = {
    tables = [
      {
        name = "Users"
        rows = [
          {
            fields = [
              { name = "Username", value = "suite-user" },
              { name = "Relax Password Requirements", value = "true" },
            ]
            sensitive_fields = [
              { name = "Password", value = var.test_user_password },
              { name = "Confirm Password", value = var.test_user_password },
            ]
            default_row = false
          },
        ]
      },
    ]
    fields = []
  }
}

resource "pingfederate_idp_adapter" "login_form" {
  adapter_id = "conformanceLogin"
  name       = "Conformance login form"

  plugin_descriptor_ref = {
    id = "com.pingidentity.adapters.htmlform.idp.HtmlFormIdpAuthnAdapter"
  }

  configuration = {
    tables = [
      {
        name = "Credential Validators"
        rows = [
          {
            fields = [
              {
                name  = "Password Credential Validator Instance"
                value = pingfederate_password_credential_validator.suite_user.id
              },
            ]
            default_row = false
          },
        ]
      },
    ]
    fields = []
  }

  attribute_contract = {
    core_attributes = [
      { name = "policy.action" },
      { name = "username", masked = false, pseudonym = true },
    ]
  }

  attribute_mapping = {
    attribute_contract_fulfillment = {
      "policy.action" = { source = { type = "ADAPTER" }, value = "policy.action" }
      "username"      = { source = { type = "ADAPTER" }, value = "username" }
    }
  }
}

# The persistent grant is keyed by the username the form authenticated.
resource "pingfederate_oauth_idp_adapter_mapping" "login_form" {
  mapping_id = pingfederate_idp_adapter.login_form.id

  attribute_contract_fulfillment = {
    "USER_KEY"  = { source = { type = "ADAPTER" }, value = "username" }
    "USER_NAME" = { source = { type = "ADAPTER" }, value = "username" }
  }
}
