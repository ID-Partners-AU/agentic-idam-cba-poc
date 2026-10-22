# PingFederate is authored against a LOCAL stock PF and shipped as a config archive.
#
# This provider never points at a running deployment: a deployed PF exposes its runtime and not its
# admin API. It points at a stock PF container on this machine (../author.sh), the realised
# config is exported as data.zip (../export.sh), and every PF built from this repo boots from that.
provider "pingfederate" {
  https_host     = var.pf_admin_host
  admin_api_path = "/pf-admin-api/v1"
  username       = var.pf_admin_username
  password       = var.pf_admin_password
  # Which fields the provider may send. ../apply.sh sets it from build/pf-version.env
  # (PF_TERRAFORM_PRODUCT_VERSION); the default in variables.tf is checked against the same file.
  product_version = var.pf_product_version
  # Self-signed, and on 127.0.0.1: variables.tf refuses any other host.
  insecure_trust_all_tls              = true
  x_bypass_external_validation_header = true
}
