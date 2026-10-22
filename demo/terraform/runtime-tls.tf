# PingFederate's runtime certificate (F-0362): ../gen-keys.sh issues keys/pf-runtime-tls.p12 from its own CA,
# naming localhost, host.docker.internal, the rig's container name and the issuer's host, and this imports it as
# the server certificate. Before it the rig served PingFederate's generated CN=localhost certificate with no
# subject alternative names, so a module in PingFederate calling PingFederate at its own issuer failed the host
# check, and HSSF1 had to run with a JDK switch the production profile forbids. The admin console takes the same
# certificate: it is served on localhost only, which the certificate names, and the settings need one there too.
resource "pingfederate_keypairs_ssl_server_key" "runtime" {
  key_id    = "pf-runtime-tls"
  file_data = filebase64("${path.module}/../keys/pf-runtime-tls.p12")
  format    = "PKCS12"
  password  = var.pf_runtime_tls_password
}

resource "pingfederate_keypairs_ssl_server_settings" "this" {
  runtime_server_cert_ref     = { id = pingfederate_keypairs_ssl_server_key.runtime.id }
  active_runtime_server_certs = [{ id = pingfederate_keypairs_ssl_server_key.runtime.id }]
  admin_console_cert_ref      = { id = pingfederate_keypairs_ssl_server_key.runtime.id }
  active_admin_console_certs  = [{ id = pingfederate_keypairs_ssl_server_key.runtime.id }]
}

# The CA in PingFederate's trusted CAs: PingFederate points javax.net.ssl.trustStore at its own store, so this is the
# JVM's default trust, and a module calling the issuer checks the chain (and the host name) against it.
resource "pingfederate_certificate_ca" "runtime" {
  ca_id     = "pf-runtime-tls-ca"
  file_data = replace(replace(file("${path.module}/../keys/pf-runtime-tls-ca.crt"), "/-----[A-Z ]+-----/", ""), "/\\s/", "")
}
