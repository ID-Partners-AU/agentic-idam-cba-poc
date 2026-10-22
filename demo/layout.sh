# shellcheck shell=bash
# Where the rig's scripts find the image build, the PingFederate version and the modules, in either tree they
# run in. Sourced by up.sh, author.sh, apply.sh, compose-context.sh and verify-rar-principal.sh; sets no shell
# options, and returns non-zero (after saying why) when neither layout is there.
#
#   PFAI_ROOT         the directory above this one
#   PFAI_MODE         release when PF_RELEASE is set or there is no $PFAI_ROOT/pom.xml (the public tree has
#                     none), else reactor
#   PFAI_IMAGE_DIR    $PFAI_ROOT/build/pingfederate when that has a Dockerfile (this repository), else
#                     $PFAI_ROOT/image (the public tree)
#   PFAI_VERSION_ENV  $PFAI_ROOT/build/pf-version.env (this repository), else $PFAI_IMAGE_DIR/pf-version.env
#   PFAI_RELEASE_DIR  release mode: where the release's assets are - PF_RELEASE when it names a directory, else
#                     stage-from-release.sh's cache for PF_RELEASE (or release.env's PFAI_RELEASE); empty in
#                     reactor mode
#
# pfai_slot_ports SLOT (C-6) gives a slot, 0 to 44, its own twenty host ports from 57100 + 20 x SLOT, so parallel
# worktrees each run a rig or a reference stack without colliding: it exports PFAI_SLOT_BASE and PFAI_PORT_<NAME>
# for each offset in PFAI_SLOT_OFFSETS, and returns non-zero (after saying why) for anything but a whole number
# in range. reference/README.md has the table.
#
# In reactor mode PF_AGENTIC_IDENTITY_HOME, when set, still names the checkout whose build/pingfederate and
# build/pf-version.env are used (a sibling clone's modules, as before this file); release mode ignores it.
_pfai_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PFAI_ROOT="$(cd "$_pfai_here/.." && pwd)"
if [[ -n "${PF_RELEASE:-}" || ! -f "$PFAI_ROOT/pom.xml" ]]; then PFAI_MODE=release; else PFAI_MODE=reactor; fi
_pfai_base="$PFAI_ROOT"
if [[ "$PFAI_MODE" == reactor && -n "${PF_AGENTIC_IDENTITY_HOME:-}" ]]; then _pfai_base="$PF_AGENTIC_IDENTITY_HOME"; fi
if [[ -f "$_pfai_base/build/pingfederate/Dockerfile" ]]; then
  PFAI_IMAGE_DIR="$_pfai_base/build/pingfederate"
elif [[ -f "$PFAI_ROOT/image/Dockerfile" ]]; then
  PFAI_IMAGE_DIR="$PFAI_ROOT/image"
else
  echo "ERROR: no image build at $_pfai_base/build/pingfederate or $PFAI_ROOT/image (neither has a Dockerfile)" >&2
  return 1
fi
if [[ -f "$_pfai_base/build/pf-version.env" ]]; then
  PFAI_VERSION_ENV="$_pfai_base/build/pf-version.env"
elif [[ -f "$PFAI_IMAGE_DIR/pf-version.env" ]]; then
  PFAI_VERSION_ENV="$PFAI_IMAGE_DIR/pf-version.env"
else
  echo "ERROR: no PingFederate version at $_pfai_base/build/pf-version.env or $PFAI_IMAGE_DIR/pf-version.env" >&2
  return 1
fi
PFAI_RELEASE_DIR=""
if [[ "$PFAI_MODE" == release ]]; then
  if [[ -n "${PF_RELEASE:-}" && -d "$PF_RELEASE" ]]; then
    PFAI_RELEASE_DIR="$(cd "$PF_RELEASE" && pwd)"
  else
    _pfai_version="${PF_RELEASE:-}"
    if [[ -z "$_pfai_version" && -f "$PFAI_IMAGE_DIR/release.env" ]]; then
      _pfai_version="$(sed -n 's/^PFAI_RELEASE=//p' "$PFAI_IMAGE_DIR/release.env" | tail -n 1)"
    fi
    [[ -z "$_pfai_version" ]] || PFAI_RELEASE_DIR="$PFAI_IMAGE_DIR/.release/${_pfai_version#v}"
  fi
fi
export PFAI_ROOT PFAI_MODE PFAI_IMAGE_DIR PFAI_VERSION_ENV PFAI_RELEASE_DIR
unset _pfai_here _pfai_base _pfai_version

# The slot layout: NAME=offset, fixed. Offsets 0-4 are the rig's (up.sh, PF_RIG_SLOT); 5-17 a reference stack's
# (REF_SLOT); 18-19 are spare. Changing an offset moves every stack that uses it, so add, never renumber.
PFAI_SLOT_OFFSETS="RIG_HTTPS=0 RIG_HTTP=1 RIG_ADMIN=2 RIG_AUTHOR_ADMIN=3 RIG_AUTHOR_RUNTIME=4
RUNTIME=5 ADMIN=6 ENGINE_1=7 ENGINE_2=8 HAPROXY_API=9 HAPROXY_STATS=10 POSTGRES=11 REDIS=12 OPENBAO=13
AUTHOR_ADMIN=14 AUTHOR_RUNTIME=15 SPIRE=16 MDM=17"
export PFAI_SLOT_OFFSETS
pfai_slot_ports() {
  local slot="${1:-}" pair
  if [[ ! "$slot" =~ ^(0|[1-9][0-9]?)$ ]] || (( slot > 44 )); then
    echo "ERROR: a slot is a whole number from 0 to 44, not '$slot'" >&2
    return 1
  fi
  PFAI_SLOT_BASE=$((57100 + 20 * slot))
  export PFAI_SLOT_BASE
  for pair in $PFAI_SLOT_OFFSETS; do
    export "PFAI_PORT_${pair%%=*}=$((PFAI_SLOT_BASE + ${pair#*=}))"
  done
}
