#!/usr/bin/env bash
# Compose the PingFederate image's build context.
#
# The image build is ../build/pingfederate/ here, ../image/ in the public tree (Dockerfile, war assembly and
# the filters it declares, entrypoint, staged module jars and the staged war assembler; layout.sh says which);
# this directory owns what configures it: the archive export.sh produced and the cipher-list overlay.
# `docker build` (and a deploy tool such as `railway up`) want one directory, so this assembles
# .context/ (git-ignored) and prints its path.
#
# In reactor mode PF_AGENTIC_IDENTITY_HOME defaults to this repo. Point it at another checkout or worktree to
# build a branch's modules with this configuration.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=layout.sh
. "$HERE/layout.sh"
BUILD="$PFAI_IMAGE_DIR"
if [[ "$PFAI_MODE" == release ]]; then STAGE_HINT="$BUILD/stage-from-release.sh --profile conformance"; else STAGE_HINT="mvn package and $BUILD/stage-modules.sh --profile conformance"; fi
[[ -f "$BUILD/modules/MANIFEST" ]] || { echo "ERROR: no staged modules - run $STAGE_HINT" >&2; exit 1; }
# This image is the conformance profile - the CIBA simulator in it, for the FAPI-CIBA plan - and
# docker-compose.yml builds it as such. The assembler refuses a modules/ staged for production, so say
# it here, before a minute of docker build.
manifest_header="$(head -n 1 "$BUILD/modules/MANIFEST")"
case "$manifest_header" in
  "MANIFEST/2 profile=conformance "*) ;;
  *) echo "ERROR: modules/ is not staged for the conformance profile (its MANIFEST starts '$manifest_header')." >&2
     echo "       Run $STAGE_HINT - up.sh does." >&2; exit 1 ;;
esac
# The war assembler the Dockerfile runs, which stage-modules.sh and stage-from-release.sh stage beside modules/.
[[ -f "$BUILD/assembler/war-assembler.jar" ]] || { echo "ERROR: no staged war assembler at $BUILD/assembler - run $STAGE_HINT" >&2; exit 1; }
for f in data.zip overlay/pf.jwk overlay/pingfederate-system-keys.xml; do
  [[ -f "$HERE/$f" ]] || { echo "ERROR: missing $f - run ./export.sh" >&2; exit 1; }
done

CTX="$HERE/.context"
rm -rf "$CTX"; mkdir -p "$CTX/overlay"
cp "$BUILD/Dockerfile" "$BUILD/assemble-pf-runtime-war.sh" "$BUILD/filters.xml" "$BUILD/pf-entrypoint.sh" "$BUILD/pf-healthcheck.sh" "$CTX/"
cp -R "$BUILD/modules" "$CTX/modules"
cp -R "$BUILD/assembler" "$CTX/assembler"
cp -R "$BUILD/overlay/config-store" "$CTX/overlay/config-store"
# This rig's own config-store files, laid over the image as well as carried in the archive - see
# config-store/com.pingidentity.crypto.SunJCEManager.xml for why it takes both.
cp "$HERE"/config-store/*.xml "$CTX/overlay/config-store/"
cp "$HERE/data.zip" "$CTX/"
cp "$HERE/overlay/pf.jwk" "$HERE/overlay/pingfederate-system-keys.xml" "$CTX/overlay/"
# No mock attesters: this PF trusts no attester. The image no longer reads oidf-mock-attesters.json from the
# context (0.6.0); a development deployment that wants them mounts the file and sets oidf.mock.attesters itself.

jars=("$CTX/modules"/*.jar)
echo "composed $CTX from $BUILD (${#jars[@]} module jars; $manifest_header)" >&2
echo "$CTX"
