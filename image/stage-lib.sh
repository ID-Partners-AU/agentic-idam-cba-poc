# shellcheck shell=bash
# What stage-modules.sh (from the reactor) and stage-from-release.sh (from a release's assets) share, so the
# two stage directories they write cannot drift apart: the digest, the v2 MANIFEST and the staged war
# assembler. Sourced, never executed; it sets no shell options of its own, and each function returns
# non-zero rather than exiting, so the caller's `set -e` decides.
#
#   pfai_sha256 <file>                                  the file's sha256, hex, on stdout
#   pfai_write_manifest <dest> <profile> <commit> "<section> <path>"...
#                                                       <dest>/MANIFEST for the jars already copied into
#                                                       <dest>, in the order given (a path's basename is the
#                                                       file in <dest>)
#   pfai_stage_assembler <jar> <dest-dir-parent>        <jar> as <dest-dir-parent>/assembler/war-assembler.jar

# The same digest the assembler and the release workflow compute; GNU and busybox have sha256sum, macOS
# has shasum.
pfai_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A manifest of exactly what a run staged. assemble-pf-runtime-war.sh refuses to build from a modules/
# directory that does not match it - because the failure mode otherwise is silent and expensive: a
# hand-populated or stale modules/ assembles a war that boots fine and then throws NoClassDefFoundError at
# the first request that touches the missing module. That has now happened twice (agent-registry, then
# device-instance), each time discovered from a 500 in staging rather than from the build.
#
# MANIFEST v2: one header line naming the format, the profile, the build time and the commit; then a
# [section] per module group, and one "<sha256>  <file>" line per jar - sha256sum's own format, so
# `grep -E '^[0-9a-f]{64}  ' MANIFEST | sha256sum -c` checks the directory by hand. The profile is what
# the assembler compares with the image's; the digests catch a jar rebuilt or swapped after staging, which
# the v1 list of bare filenames could not.
pfai_write_manifest() {
  local dest="$1" profile="$2" commit="$3" section="" entry s b digest
  shift 3
  {
    echo "MANIFEST/2 profile=$profile built=$(date -u +%Y-%m-%dT%H:%M:%SZ) commit=$commit"
    for entry in "$@"; do
      s="${entry%% *}"; b="$(basename "${entry#* }")"
      if [[ "$s" != "$section" ]]; then echo "[$s]"; section="$s"; fi
      digest="$(pfai_sha256 "$dest/$b")" || return 1
      echo "$digest  $b"
    done
  } > "$dest/MANIFEST"
}

# The war assembler assemble-pf-runtime-war.sh runs (build/war-assembler), into assembler/ beside modules/ -
# so a context composed from the stage directory's parent carries it too. It is a build tool, not a module,
# so it is never in the MANIFEST: it never goes into the war or server/default/deploy.
pfai_stage_assembler() {
  local jar="$1" dest="$2/assembler"
  [[ -f "$jar" ]] || { echo "ERROR: no war assembler at $jar" >&2; return 1; }
  mkdir -p "$dest" && cp "$jar" "$dest/war-assembler.jar"
}
