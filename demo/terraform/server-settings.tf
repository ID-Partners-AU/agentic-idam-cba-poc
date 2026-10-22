# The base URL is the whole reason this file exists: see var.pf_base_url.
#
# No import block, unlike ../../pingfederate/terraform/server-settings.tf. That one adopts a server
# that already carries config; this one is applied to a from-zero PF, and the provider creates a
# singleton by PUT.
resource "pingfederate_server_settings" "this" {
  federation_info = {
    base_url = var.pf_base_url
    # The admin API will not accept an empty entity id. Nothing here does SAML.
    saml_2_entity_id = var.pf_base_url
  }
  notifications = {
    expired_certificate_administrative_console_warning_days  = 14
    expiring_certificate_administrative_console_warning_days = 14
    notify_admin_user_password_changes                       = false
    thread_pool_exhaustion_notification_settings = {
      email_address       = ""
      notification_mode   = "LOGGING_ONLY"
      thread_dump_enabled = true
    }
  }
}
