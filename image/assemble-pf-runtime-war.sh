#!/usr/bin/env bash
# Assemble pf-runtime.war = STOCK PingFederate runtime war + the OIDF module jars (+ optionally jose4j),
# injected into WEB-INF/lib, PLUS the filters filters.xml declares, registered over PF's own endpoints in
# its WEB-INF/web.xml.
#
# A thin wrapper. The work is done by the war assembler (build/war-assembler, a JDK-only jar the reactor
# builds and stage-modules.sh stages into assembler/ beside this script), which reads web.xml with the JDK's
# DOM rather than awk and grep: it checks the MANIFEST and the profile, the servlet namespace, that every
# declared filter ends up with exactly one <filter> and one <filter-mapping> over exactly its declared
# paths, the declared order, that the stock web.xml serves each path, metadata-complete, the declared
# listeners and their classes - and prints each path's filter chain. See build/war-assembler/README.md.
# It replaced seven awk blocks and a line-number order check that had to be written around `grep -q`
# under pipefail: grep -q exits at its first match, unzip dies of SIGPIPE, and a mapping that is present
# reads as absent (Railway's builder, 2026-09-23) or a namespace hit as a miss.
#
#   assemble-pf-runtime-war.sh STOCK_WAR MODULES JOSE4J_JAR OUT_WAR [PROFILE]
#
# Inputs (provided by the caller - build/pingfederate/Dockerfile here, or a consumer repo's CI job):
#   $1  STOCK_WAR   path to the stock pf-runtime.war extracted from the pingidentity/pingfederate image
#   $2  MODULES     the built module jar(s): either a single jar (the legacy monolith
#                   pf-oidf-modules.jar), or a DIRECTORY of jars staged by stage-modules.sh (oidf.jar +
#                   attestation-issuer/ssf and the libraries they need), checked against its MANIFEST;
#                   every jar in the directory is injected into WEB-INF/lib under its own name.
#   $3  JOSE4J_JAR  path to jose4j jar, or "-" to skip. SKIP for pf-runtime.war merging: PF already
#                   ships jose4j on its server classpath, and bundling a second copy in WEB-INF/lib
#                   causes a LinkageError (loader constraint violation) when PF-loaded jose4j types
#                   (JwksEndpointKeyAccessor results) cross into module code.
#   $4  OUT_WAR     path to write the assembled pf-runtime.war
#   $5  PROFILE     optional: the staging profile the image is built for, production (the default) or
#                   conformance. MODULES' MANIFEST names the profile stage-modules.sh staged for, and the
#                   two must agree: a conformance stage carries the CIBA simulator, an approval oracle
#                   that must never reach a production image, and a production stage assembled into a
#                   conformance image boots a rig with no CIBA device that fails the FAPI-CIBA plan on
#                   every module.
#
# The environment can move the two things this script finds beside itself:
#   WAR_ASSEMBLER_JAR  the assembler jar (default: assembler/war-assembler.jar next to this script, which
#                      stage-modules.sh writes)
#   WAR_FILTERS_XML    the declaration (default: filters.xml next to this script)
# and the java that runs it is $JAVA_HOME/bin/java when JAVA_HOME is set, else java on the PATH (17 or later).
#
# Exit 0 with OUT_WAR written; 2 for a usage error; 1 for any refusal, and then OUT_WAR does not exist - a
# refusal leaves no plausible-looking war with none of this repo's code in it for a later step to deploy.
set -euo pipefail
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $(basename "$0") STOCK_WAR MODULES JOSE4J_JAR OUT_WAR [PROFILE]" >&2
  exit 2
fi
OUT_WAR="$4"
# Refused before anything can delete OUT_WAR: here it would be the stock war.
if [[ -e "$OUT_WAR" && "$1" -ef "$OUT_WAR" ]]; then
  echo "ERROR: STOCK_WAR and OUT_WAR are the same file ($OUT_WAR). Write the war somewhere else." >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
JAR="${WAR_ASSEMBLER_JAR:-$HERE/assembler/war-assembler.jar}"
FILTERS="${WAR_FILTERS_XML:-$HERE/filters.xml}"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"

# Anything that stops the assembler starting is a refusal too, and removes OUT_WAR as the assembler would.
refuse() { echo "ERROR: $1" >&2; rm -f "$OUT_WAR"; exit 1; }
[[ -f "$JAR" ]] || refuse "no war assembler at $JAR. Run 'mvn -q -DskipTests package' and build/pingfederate/stage-modules.sh, which stages it into assembler/ beside this script (or set WAR_ASSEMBLER_JAR)."
[[ -f "$FILTERS" ]] || refuse "no filter declaration at $FILTERS (or set WAR_FILTERS_XML)."
command -v "$JAVA" >/dev/null 2>&1 || refuse "no java to run the assembler ($JAVA): set JAVA_HOME or put Java 17 or later on the PATH."

# Not exec: a JVM that cannot run the jar (older than 17, or an Error the assembler did not catch) exits
# non-zero without the assembler's own clean-up, so OUT_WAR is removed here on any exit but 0 and usage.
rc=0
"$JAVA" -jar "$JAR" --filters "$FILTERS" "$@" || rc=$?
if [[ $rc -ne 0 && $rc -ne 2 ]]; then
  rm -f "$OUT_WAR"
fi
exit "$rc"
