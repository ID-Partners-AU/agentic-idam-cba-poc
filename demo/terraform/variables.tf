# ── admin API (the local authoring container only) ──────────────────────────────────────────────

variable "pf_admin_host" {
  description = "Admin API of the LOCAL authoring PingFederate, e.g. https://localhost:19999"
  type        = string

  validation {
    condition     = can(regex("^https://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?$", var.pf_admin_host))
    error_message = "pf_admin_host must be a local endpoint. The rig's admin API is not exposed; author locally and ship the archive."
  }
}

variable "pf_admin_username" {
  description = "Admin username on the authoring PingFederate"
  type        = string
  default     = "administrator"
}

variable "pf_admin_password" {
  description = "Admin password on the authoring PingFederate (TF_VAR_pf_admin_password; never commit)"
  type        = string
  sensitive   = true
}

# The provider decides which fields it may send from this (major.minor). The default is
# PF_TERRAFORM_PRODUCT_VERSION in build/pf-version.env, which ../apply.sh exports and
# tools/pf-version-check.py holds this default to. Provider 1.10.0's binary names 13.1.0 and 13.1.1
# (strings in it, 2026-09-26); this configuration has been validated at "13.1", not yet applied.
variable "pf_product_version" {
  description = "The PingFederate product version the provider is told: major.minor"
  type        = string
  default     = "13.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.pf_product_version))
    error_message = "pf_product_version is major.minor, e.g. 13.1."
  }
}

# ── the origin PF advertises ────────────────────────────────────────────────────────────────────

# PF derives its issuer, every endpoint in discovery and the audiences it accepts on a client
# assertion from this. The default is the PF ../up.sh runs on this machine. For a PF on a public
# address (a rig behind a TLS-passthrough proxy, say) set TF_VAR_pf_base_url to that origin BEFORE
# applying: it is baked into the archive, and a suite fails its first check if the issuer in discovery
# is not byte-for-byte the URL it fetched discovery from.
variable "pf_base_url" {
  description = "The origin PF advertises: https://host[:port], no trailing slash"
  type        = string
  default     = "https://localhost:9031"

  validation {
    condition     = can(regex("^https://[^/]+$", var.pf_base_url))
    error_message = "pf_base_url is an https origin with no path and no trailing slash."
  }
}

# ── the suites that will test it ────────────────────────────────────────────────────────────────

# Each suite redirects the browser back to <base>/test/a/<alias>/callback, and PF only redirects to a
# URI registered on the client. The hosted suite is where a certification run happens; the local one
# is for iterating without a login, and reaches the rig outbound like any other client.
variable "suite_base_urls" {
  description = "Origins of the conformance suites allowed as redirect targets"
  type        = list(string)
  default = [
    "https://www.certification.openid.net",
    "https://localhost.emobix.co.uk:9643",
  ]
}

variable "suite_alias" {
  description = "The alias in the suite configuration; part of every redirect URI"
  type        = string
  default     = "pf-agentic-identity"
}

# ── CIBA ────────────────────────────────────────────────────────────────────────────────────────

# POLL or PING: one delivery mode per archive, because it is a property of the client. The FAPI-CIBA
# plan is run once per mode; author with PING, re-export, and run the ping plan against that image.
variable "ciba_delivery_mode" {
  description = "CIBA token delivery mode of the two conformance clients: POLL or PING"
  type        = string
  default     = "POLL"

  validation {
    condition     = contains(["POLL", "PING"], var.ciba_delivery_mode)
    error_message = "ciba_delivery_mode is POLL or PING."
  }
}

# Where PingFederate pings. A client has ONE notification endpoint, so ping mode targets one suite:
# the hosted one by default, since a local suite is on a name PF would have to be taught to resolve.
variable "ciba_notification_suite_base_url" {
  description = "Origin of the conformance suite whose CIBA notification endpoint the PING clients are registered with"
  type        = string
  default     = "https://www.certification.openid.net"
}

# ── generated secrets (../secrets.env, written by ../gen-keys.sh) ───────────────────────────────

variable "test_user_password" {
  description = "Password of the one test user the suite signs in as"
  type        = string
  sensitive   = true
}

variable "ssf_emitter_client_secret" {
  description = "Secret of the client suite/trigger-caep-events.py raises CAEP events with (holds ssf.provision)"
  type        = string
  sensitive   = true
}

variable "ssf_introspection_client_secret" {
  description = "Secret of the client the SSF servlet introspects receiver tokens with (OIDF_SSF_INTROSPECTION_CLIENT_SECRET)"
  type        = string
  sensitive   = true
}

# ── the OpenID Federation OP plan (PF_PROFILE=federation-op) ───────────────────────────────────

# The OP plan's relying party registers at the authorization endpoint with a request object sent by value,
# which a server that requires PAR refuses before federation is asked. REQUIRED is what FAPI 2.0 wants.
variable "par_status" {
  description = "PingFederate's pushed authorization request support: DISABLED, ENABLED or REQUIRED"
  type        = string
  default     = "REQUIRED"

  validation {
    condition     = contains(["DISABLED", "ENABLED", "REQUIRED"], var.par_status)
    error_message = "par_status is DISABLED, ENABLED or REQUIRED."
  }
}

# A CA PingFederate trusts for outbound TLS, as the base64 of its DER encoding: the suite's, so PF can fetch the
# suite RP's jwks_uri. Empty imports nothing.
variable "trusted_ca_file_data" {
  description = "Base64 DER of an extra CA certificate for PingFederate to trust, or empty"
  type        = string
  default     = ""
}

# ── the runtime certificate (F-0362) ────────────────────────────────────────────────────────────

variable "pf_runtime_tls_password" {
  description = "The password of keys/pf-runtime-tls.p12, which ../gen-keys.sh writes to secrets.env (TF_VAR_pf_runtime_tls_password)"
  type        = string
  sensitive   = true
}
