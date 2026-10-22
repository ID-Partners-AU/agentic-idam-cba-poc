#!/usr/bin/env bash
# Stage modules/ and assembler/ from a published release's assets instead of from the reactor: the same
# directory stage-modules.sh writes, so compose-context.sh, assemble-pf-runtime-war.sh and the Dockerfile
# cannot tell the two apart. No Maven and no git.
#
#   stage-from-release.sh [--profile production|conformance] [<version>|<dir>]
#
#   <version>   e.g. 0.6.1 (a leading v is dropped): fetched from
#               ${PFAI_RELEASE_BASE_URL:-https://github.com/$PFAI_RELEASE_REPO/releases/download}/v<version>/
#               into the git-ignored cache .release/<version>/ beside this script, and reused from there
#               while it verifies and was fetched from that same URL (.source records it)
#   <dir>       a directory holding a release's assets (what release.yml puts in dist/), used where it is
#   (neither)   PFAI_RELEASE from release.env beside this script; the public tree has one, the internal
#               repository does not, and there the argument is required
#
#   PFAI_RELEASE_REPO      owner/name the release is fetched from (default: release.env's, else
#                          ID-Partners/pf-agentic-identity)
#   PFAI_RELEASE_BASE_URL  the URL the v<version>/ directories sit under, for a mirror or a local test
#   STAGE_DEST             where modules/ goes (default: modules/ beside this script); assembler/ goes beside it
#
# The release is trusted only as far as its SHA256SUMS: that is fetched first, then every file it lists, and
# nothing is staged unless every file verifies - a directory source is held to the same check, and a file in it
# that SHA256SUMS does not list is refused. Fetches send no credentials (release assets are anonymous; GH_TOKEN
# is never read). The jars staged are exactly the ones the release's MANIFEST lists, under its sections, each
# with the digest the MANIFEST gives; the conformance profile adds the CIBA simulator, which a release carries as
# demo-only-ciba-sim.jar so that nothing globbing pf.plugins.* picks it up, staged under its own name,
# pf.plugins.ciba-sim.jar (the name is a label: PingFederate 13.1.3 loads the jar under either, U-0460). The
# production profile never stages it. A release with no
# war-assembler-<version>.jar - everything before 0.6.1 - is refused: the image build cannot assemble without it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=stage-lib.sh
. "$HERE/stage-lib.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
PROFILE=production SOURCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || { echo "ERROR: --profile needs a value" >&2; exit 2; }; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#--profile=}"; shift ;;
    -*) echo "ERROR: unknown option '$1' - usage: stage-from-release.sh [--profile production|conformance] [<version>|<dir>]" >&2; exit 2 ;;
    *) [[ -z "$SOURCE" ]] || { echo "ERROR: one release only, not '$SOURCE' and '$1'" >&2; exit 2; }; SOURCE="$1"; shift ;;
  esac
done
case "$PROFILE" in
  production | conformance) ;;
  *) echo "ERROR: --profile must be production or conformance, not '$PROFILE'" >&2; exit 2 ;;
esac

# release.env: KEY=VALUE, no quoting, written by the public export. Read, not sourced.
env_value() { [[ -f "$HERE/release.env" ]] && sed -n "s/^$1=//p" "$HERE/release.env" | tail -n 1; }
if [[ -z "$SOURCE" ]]; then
  SOURCE="$(env_value PFAI_RELEASE || true)"
  [[ -n "$SOURCE" ]] || die "no release named, and no PFAI_RELEASE in $HERE/release.env - give a version (0.6.1 or later) or a directory of release assets"
fi
REPO_SLUG="${PFAI_RELEASE_REPO:-$(env_value PFAI_RELEASE_REPO || true)}"
REPO_SLUG="${REPO_SLUG:-ID-Partners/pf-agentic-identity}"

command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "sha256sum or shasum is required"
# Every file SHA256SUMS lists, checked in the directory given; --strict also refuses a malformed line.
verify_sums() {
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$1" && sha256sum -c --strict --quiet SHA256SUMS )
  else
    ( cd "$1" && shasum -a 256 -c --strict --quiet SHA256SUMS )
  fi
}
# The names SHA256SUMS lists. Each line must be "<sha256>  <name>" (or " *<name>"), and a name a plain file
# name: a release has no directories, and a name with a slash or a leading dot could write outside the cache.
listed_files() {
  local line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[0-9a-f]{64}\ [\ *](.+)$ ]] || die "$1/SHA256SUMS has a line that is not '<sha256>  <file>': $line"
    name="${BASH_REMATCH[1]}"
    [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._+-]*$ ]] || die "$1/SHA256SUMS names '$name', which is not a plain file name"
    echo "$name"
  done < "$1/SHA256SUMS"
}

VERSION=""
if [[ -d "$SOURCE" ]]; then
  REL="$(cd "$SOURCE" && pwd)"
  [[ -f "$REL/SHA256SUMS" ]] || die "$REL has no SHA256SUMS - is it a release's assets?"
  # Listed in the main shell, not in a process substitution, so a refused name stops the script.
  listed="$(listed_files "$REL")"
  while IFS= read -r name; do
    [[ -f "$REL/$name" ]] || die "SHA256SUMS lists $name, which is not in $REL"
  done <<<"$listed"
  verify_sums "$REL" || die "$REL does not match its SHA256SUMS (the lines above)"
  for f in "$REL"/*; do
    b="$(basename "$f")"
    [[ "$b" == SHA256SUMS ]] && continue
    grep -qxF -- "$b" <<<"$listed" || die "$REL/$b is not listed in SHA256SUMS, so nothing vouches for it"
  done
  echo "release assets: $REL (verified against its SHA256SUMS)"
else
  VERSION="${SOURCE#v}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || die "'$SOURCE' is neither a directory nor a release version like 0.6.1"
  BASE="${PFAI_RELEASE_BASE_URL:-https://github.com/$REPO_SLUG/releases/download}"
  BASE="${BASE%/}/v$VERSION"
  REL="$HERE/.release/$VERSION"
  # The cache records where it came from (.source, the URL above), and is reused only for that same URL: a copy
  # fetched from a mirror or a test server is never taken for the release itself, since SHA256SUMS vouches only
  # for the files beside it, not for their origin.
  if [[ -f "$REL/SHA256SUMS" && "$(cat "$REL/.source" 2>/dev/null || true)" == "$BASE" ]] && verify_sums "$REL" >/dev/null 2>&1; then
    echo "release $VERSION: the cached copy in $REL, from $BASE/, verifies against its SHA256SUMS"
  else
    command -v curl >/dev/null 2>&1 || die "curl is required to fetch a release"
    # https only, redirects included, unless PFAI_RELEASE_BASE_URL itself names an http server (a local test).
    proto='=https'
    [[ "$BASE" == http://* ]] && proto='=http,https'
    TMP="$HERE/.release/.fetch-$VERSION-$$"
    rm -rf "$TMP"; mkdir -p "$TMP"
    trap 'rm -rf "$TMP"' EXIT
    echo "release $VERSION: fetching from $BASE/"
    # No credentials: -q keeps curl from reading a .curlrc (which could add a header, a .netrc or a proxy), no
    # token is read from the environment, and no .netrc is asked for.
    fetch() { curl -q -fsSL --retry 3 --proto "$proto" --proto-redir "$proto" -o "$1" "$2"; }
    fetch "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" \
      || die "could not fetch $BASE/SHA256SUMS - is v$VERSION published at $BASE?"
    # Listed in the main shell, not in a process substitution, so a refused name stops the script before any
    # fetch: the name check is what keeps a served SHA256SUMS from writing outside $TMP.
    listed="$(listed_files "$TMP")"
    while IFS= read -r name; do
      fetch "$TMP/$name" "$BASE/$name" || die "could not fetch $BASE/$name, which SHA256SUMS lists"
    done <<<"$listed"
    verify_sums "$TMP" || die "release $VERSION from $BASE does not match its SHA256SUMS (the lines above); nothing was staged"
    printf '%s\n' "$BASE" > "$TMP/.source"
    rm -rf "$REL"; mv "$TMP" "$REL"
    # Kept only if it stages: a release refused below is not left in the cache to be found next time.
    drop_failed_cache() { local status=$?; [[ $status -eq 0 ]] || rm -rf "$REL"; exit "$status"; }
    trap drop_failed_cache EXIT
    echo "release $VERSION: every file verified against SHA256SUMS, cached in $REL"
  fi
  listed="$(listed_files "$REL")"
fi

# The war assembler: a release has carried one from 0.6.1. Before that the image could only be built from source.
# (A version names its own; a directory must hold exactly one.) No mapfile: macOS's bash is 3.2.
assemblers=()
while IFS= read -r name; do
  [[ -z "$VERSION" || "$name" == "war-assembler-$VERSION.jar" ]] && assemblers+=("$name")
done < <(grep -E '^war-assembler-.+\.jar$' <<<"$listed" || true)
[[ ${#assemblers[@]} -eq 1 ]] || die "the release in $REL carries no war-assembler-<version>.jar (or more than one), so the image cannot be assembled from it. The first release this script can stage is 0.6.1; build an older one from its source (mvn package, then stage-modules.sh)."
ASSEMBLER_JAR="$REL/${assemblers[0]}"

# The release's MANIFEST: a production stage, MANIFEST/2, and the list of what to stage.
grep -qxF MANIFEST <<<"$listed" || die "the release in $REL has no MANIFEST in its SHA256SUMS"
header="$(head -n 1 "$REL/MANIFEST")"
[[ "$header" =~ ^MANIFEST/2\ profile=production\ built=[^\ ]+\ commit=([^\ ]+)$ ]] \
  || die "the release's MANIFEST does not start with a MANIFEST/2 production header (it starts '$header')"
COMMIT="${BASH_REMATCH[1]}"
ENTRIES=() WANT=()
section=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^\[([a-z]+)\]$ ]]; then section="${BASH_REMATCH[1]}"; continue; fi
  [[ "$line" =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || die "the release's MANIFEST has a line that is neither a [section] nor '<sha256>  <file>': $line"
  digest="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
  [[ -n "$section" ]] || die "the release's MANIFEST lists $name before any [section]"
  grep -qxF -- "$name" <<<"$listed" || die "the release's MANIFEST names $name, which its SHA256SUMS does not list"
  ENTRIES+=("$section $name"); WANT+=("$digest")
done < <(tail -n +2 "$REL/MANIFEST")
[[ ${#ENTRIES[@]} -gt 0 ]] || die "the release's MANIFEST lists no jars"
if [[ "$PROFILE" == conformance ]]; then
  # The simulator is an approval oracle keyed by nothing but an auth_req_id; it runs only where
  # OIDF_DEPLOYMENT_PROFILE=development, and only this profile stages it (plugins/ciba-sim/README.md).
  grep -qxF demo-only-ciba-sim.jar <<<"$listed" || die "the release in $REL carries no demo-only-ciba-sim.jar, which the conformance profile stages"
fi

DEST="${STAGE_DEST:-$HERE/modules}"
mkdir -p "$DEST"
rm -f "$DEST"/*.jar "$DEST/MANIFEST"
for i in "${!ENTRIES[@]}"; do
  name="${ENTRIES[$i]#* }"
  cp "$REL/$name" "$DEST/"
  [[ "$(pfai_sha256 "$DEST/$name")" == "${WANT[$i]}" ]] || die "$name does not have the digest the release's MANIFEST gives it"
done
if [[ "$PROFILE" == conformance ]]; then
  cp "$REL/demo-only-ciba-sim.jar" "$DEST/pf.plugins.ciba-sim.jar"
  ENTRIES+=("plugins pf.plugins.ciba-sim.jar")
fi
pfai_write_manifest "$DEST" "$PROFILE" "$COMMIT" "${ENTRIES[@]}"

echo "staged ${#ENTRIES[@]} jars ($PROFILE profile) into $DEST from ${VERSION:+release $VERSION in }$REL:"
cat "$DEST/MANIFEST"

pfai_stage_assembler "$ASSEMBLER_JAR" "$(dirname "$DEST")"
echo "staged the war assembler into $(dirname "$DEST")/assembler/war-assembler.jar"
