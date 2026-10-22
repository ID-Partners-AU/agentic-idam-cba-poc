terraform {
  required_version = ">= 1.5.0"

  required_providers {
    pingfederate = {
      source = "pingidentity/pingfederate"
      # 1.10 is what these files were validated against. par_status, disallow_plain_pkce and
      # include_issuer_in_authorization_response are the fields FAPI 2.0 turns on, and an older
      # provider that does not know them fails at validate rather than quietly leaving them off.
      version = "~> 1.10"
    }
  }
}
