#!/usr/bin/env bash
# terraform plan/apply against the LOCAL authoring PingFederate.
#
#   ./apply.sh plan | apply | <any terraform subcommand and its arguments>
#
# The admin password is read from a file rather than the environment of whoever runs this, so it is
# never in a shell history or a process listing for longer than terraform itself runs:
#   PF_AUTHOR_ENV   a KEY=VALUE file holding PING_IDENTITY_PASSWORD (what the authoring container
#                   was started with - see README.md)
#   PF_ADMIN_HOST   defaults to https://localhost:19999
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${PF_AUTHOR_ENV:?set PF_AUTHOR_ENV to the env file the authoring container was started with}"
[[ -f "$HERE/secrets.env" ]] || { echo "ERROR: no secrets.env - run ./gen-keys.sh first" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
. "$HERE/secrets.env"
set +a
TF_VAR_pf_admin_password="$(sed -n 's/^PING_IDENTITY_PASSWORD=//p' "$PF_AUTHOR_ENV")"
[[ -n "$TF_VAR_pf_admin_password" ]] || { echo "ERROR: no PING_IDENTITY_PASSWORD in $PF_AUTHOR_ENV" >&2; exit 1; }
export TF_VAR_pf_admin_password
export TF_VAR_pf_admin_host="${PF_ADMIN_HOST:-https://localhost:19999}"
# The product version the provider is told, from the one place the PingFederate version is written down,
# which layout.sh finds in either tree.
# shellcheck source=layout.sh
. "$HERE/layout.sh"
# shellcheck disable=SC1090,SC1091
. "$PFAI_VERSION_ENV"
export TF_VAR_pf_product_version="${PF_TERRAFORM_PRODUCT_VERSION:?}"

cd "$HERE/terraform"
[[ -d .terraform ]] || terraform init -input=false
exec terraform "$@"
