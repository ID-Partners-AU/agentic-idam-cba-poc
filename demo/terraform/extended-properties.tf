# The extended properties the modules write on a client they register or read from a client's configuration:
# extended-properties.json (beside this file; docs/extended-properties.json in pf-agentic-identity), which tools/config-reference.py generates from the settings catalogues and CI
# holds current. PingFederate drops a property it has not been told about - silently - and without `status` a
# federation client looks like one an administrator made: never expired, never renewed, its requests held to
# nothing. The module now refuses to register when that happens; this makes sure it doesn't. A per-client
# attestation or chain setting that PingFederate dropped is simply not applied (F-0041). trust_chain and contacts
# hold several values each.
locals {
  federation_extended_properties   = jsondecode(file("${path.module}/extended-properties.json")).extended_properties
  multi_valued_extended_properties = ["trust_chain", "contacts"]
}

resource "pingfederate_extended_properties" "federation" {
  # A description on each: PingFederate answers an empty one where none was sent, and the provider then cannot match
  # the set it planned with the one it read back.
  items = [for name in local.federation_extended_properties : {
    name         = name
    description  = "Read or written by the OIDF modules (extended-properties.json)"
    multi_valued = contains(local.multi_valued_extended_properties, name)
  }]
}
