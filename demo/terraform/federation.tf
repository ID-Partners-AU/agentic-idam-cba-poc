# The OpenID Federation OP plan (PF_PROFILE=federation-op): the conformance suite's CA, so PingFederate can fetch
# the suite RP's jwks_uri - PF checks that certificate itself, like any client's. Nothing here unless
# trusted_ca_file_data is set.
resource "pingfederate_certificate_ca" "suite" {
  count     = var.trusted_ca_file_data == "" ? 0 : 1
  ca_id     = "conformance-suite-ca"
  file_data = var.trusted_ca_file_data
}
