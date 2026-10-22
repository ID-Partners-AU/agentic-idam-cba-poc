# The capability's PingFederate image: stock PingFederate 13.1.3 (jakarta.servlet) + this repo's module set,
# merged into pf-runtime.war, and nothing else. No RAR->PingAuthorize plugin, no consent page, no agentic
# clients: those belong to a consumer's own image, built FROM the same base with its own archive.
#
# Three targets (plan item R-CI6, taking R-I3's build targets ahead of Phase 3):
#   builder      assembles pf-runtime.war from the stock war, modules/ and filters.xml; nothing else
#   capability   the image with no configuration archive: what Build's image job builds, tests and scans
#   deployment   capability plus the configuration archive and overlay/ - the last stage, so a
#                `docker build` with no --target builds it, as it did before the targets existed
#
# Build-context artifacts required here (see README.md in this directory):
#   data.zip.age (preferred) or data.zip  <- the config archive (produced by terraform/ export); deployment only
#   overlay/config-store/org.sourceid.saml20.domain.mgmt.impl.DataDeployer.xml   deployment only
#   overlay/pf.jwk, overlay/pingfederate-system-keys.xml   only under the plaintext scheme (SECRET, git-ignored)
#   modules/                         <- stage-modules.sh output of this repo's reactor, staged for the
#                                       profile this image is built for (merged into pf-runtime.war AND
#                                       copied to server/default/deploy; see below)
#   assembler/war-assembler.jar      <- stage-modules.sh output too; with assemble-pf-runtime-war.sh and filters.xml
#
# Build arg STAGING_PROFILE selects what the image is: production (the default; the jars modules/MANIFEST names) or
# conformance (those and the CIBA simulator, an approval oracle for the suite's FAPI-CIBA plan that
# has no business in a production image, plus the directory it keeps its decisions in). The profile is
# recorded as a label, and the assembler refuses a modules/ that was staged for the other one.
#   (no jose4j: the assemble call passes "-" and relies on PF's own copy in server/default/lib)
#
# The image carries no configuration of its own (plan item R-I3): no EULA acceptance, no DEBUG logging, no plain
# HTTP listener, no ForceUnsupportedImport, no required claims and no mock attesters. Each is the deployment's to
# set at run time - README.md, "What the image leaves to you".
#
# The module is MERGED INTO pf-runtime.war (not deployed as a loose oidf.war + jar). This puts its
# @WebServlet servlets in the ROOT context — so `/.well-known/ssf-configuration`, `/ssf/*`, the challenge endpoints
# at `/federation/attestation-challenge` and `/federation/attestation/challenge`, etc. serve at root (no `/oidf` prefix) — gives a single
# classloader (one AttestationSupport singleton; no OGNL-hook caching split), and lets the SSF logout filter
# run over PF's own `/idp/init_logout.openid`. Repoint any `/oidf/*` consumers (e.g. the demo UI PF_BASE) to root.
#
# Licensing is DevOps-fetched — NO pingfederate.lic is baked. The base image's boot hook
# 17-check-license.sh pulls a fresh evaluation license when these RUNTIME env vars are set (as the
# deployment's secrets - see vars.<env>.env):
#   PING_IDENTITY_ACCEPT_EULA=YES            (the deployment's to set; pf-entrypoint.sh refuses to start without it)
#   PING_IDENTITY_DEVOPS_USER=<devops email> (SECRET — never in git)
#   PING_IDENTITY_DEVOPS_KEY=<devops key>    (SECRET — never in git)
# Trade-off: DevOps eval licenses are short-lived (~7 days) and re-fetched only at container start.

ARG STAGING_PROFILE=production
# What the OCI labels say (org.opencontainers.image.*): the release version, the commit and the build time. CI
# passes all three; a local build says unknown, unknown and nothing.
ARG OCI_VERSION=unknown
ARG OCI_REVISION=unknown
ARG OCI_CREATED=

# The tag and digest are the ones build/pf-version.env records (PF_IMAGE, PF_IMAGE_DIGEST), written out as a
# literal so Dependabot can bump them here; tools/pf-version-check.py fails when the two disagree, and
# tools/pf-version-sync.py rewrites the env file from this line after a bump. It is the one FROM that names an
# image a shipped stage starts from; the only other is age-build's Go toolchain, which hands on nothing but age.
FROM pingidentity/pingfederate:13.1.3-alpine_3.24.1-al21-latest@sha256:0d559261d658222179b07de8b2c84a8aea3cb30c7be107970686f58ea9dd3a4a AS pingfederate
ARG STAGING_PROFILE
# Refuse a third value here, at the top, rather than let a typo build a production image by default.
RUN case "$STAGING_PROFILE" in production|conformance) ;; *) \
      echo "ERROR: STAGING_PROFILE must be production or conformance, not '$STAGING_PROFILE'" >&2; exit 1 ;; esac

# --- builder: pf-runtime.war, assembled ---
# Merge the OIDF attestation/federation/SSF modules into pf-runtime.war (root context, the webapp
# classloader — the same jars are ALSO copied to server/default/deploy below, so the engine classloader
# gets its own copy: two classloaders, deliberately, and without Redis the filter and the OGNL criterion
# therefore keep separate in-memory challenge/replay stores), and register the filters filters.xml declares
# (OidfCorrelation, SsfLogoutSignal, Fapi2Profile, FapiResourceServer, OAuthErrorDescription, OidfFrontChannelAutoRegistration,
# OidfAutoRegistration, ClientAttestationAuth) in its web.xml - via the same assemble script a consumer's CI
# would use, a wrapper round the war assembler (build/war-assembler) that stage-modules.sh stages into
# assembler/, run here on the base image's own Java 21 (JAVA_HOME=/opt/java). modules/ holds the reactor's jars
# (modules/MANIFEST names every one; under the conformance profile the CIBA simulator too), staged for one
# profile, and the assembler checks them against the MANIFEST - digests, and the profile against
# STAGING_PROFILE. bash is for the wrapper, in this stage only: the image the capability stage makes has no bash.
# The base image has unzip itself. (No pf-rar-paz-plugin - agentic.)
FROM pingfederate AS builder
USER root
ARG STAGING_PROFILE
COPY assemble-pf-runtime-war.sh filters.xml assembler/war-assembler.jar /tmp/assembler/
COPY modules/ /tmp/modules/
RUN apk add --no-cache bash \
 && mkdir -p /build \
 && STOCK="$(find /opt -name pf-runtime.war 2>/dev/null | grep -v '/opt/in/' | head -1)" \
 && { [ -n "$STOCK" ] || { echo 'stock pf-runtime.war not found in base image'; exit 1; }; } \
 && WAR_ASSEMBLER_JAR=/tmp/assembler/war-assembler.jar bash /tmp/assembler/assemble-pf-runtime-war.sh "$STOCK" \
      /tmp/modules - /build/pf-runtime.war "$STAGING_PROFILE"

# --- age: built from its source with a patched Go, checked, in stages of their own ---
# age decrypts the configuration archive at boot (pf-entrypoint.sh). It is not from apk: the base image has no apk
# database (/lib/apk/db holds no installed file), so `apk add` believed nothing was installed and reinstalled the
# whole of PingFederate's Alpine userland at the day's versions (F-0220). Nor is it age's own release binary any
# more: age 1.3.2's (2026-08-29, still the latest) is built with go1.27.0, whose standard library carries two
# CRITICAL and eight HIGH advisories fixed in go1.27.2, and those failed Build's image scan (F-0708). So age-build
# compiles age 1.3.2 from its module source with the Go toolchain pinned below, and nothing else moves: the same
# module version, so the same dependencies at the versions age's own go.sum names (golang.org/x/crypto v0.55.0,
# F-0285).
#
# The source is checked, not just named: `go install filippo.io/age/cmd/age@v1.3.2` (and cmd/age-keygen) fetches the
# module from the Go module proxy and verifies its hash, and every dependency's, against the Go checksum database
# (GOSUMDB, set explicitly here, as are GOPROXY and GOFLAGS=-mod=readonly, so nothing rewrites age's go.sum), and
# stops on a mismatch. The binaries are static (CGO_ENABLED=0) and built with -trimpath, and are not stripped:
# `govulncheck -mode binary` needs the symbol table to tell a vulnerable function age calls from one it merely links,
# which is what F-0285 rests on. age-build runs on the build host's platform and cross-compiles for TARGETARCH; the
# age stage then runs both binaries on the target's own, so an image of either architecture is smoke-tested where it
# will run.
#
# Only /age - the two binaries and age's LICENSE, from the module source - reaches the image, and no Go does: its
# system files are the base image's, byte for byte, apart from the two binaries and the licence copied below, and
# Build's image job checks exactly that. To move age: change AGE_VERSION. To move Go: change the tag and the digest
# together (the multi-platform index's, from `docker buildx imagetools inspect`).
FROM --platform=$BUILDPLATFORM golang:1.27.2-alpine3.24@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS age-build
ARG TARGETARCH
ARG AGE_VERSION=1.3.2
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
RUN GOOS=linux GOARCH="$TARGETARCH" go install -trimpath \
      "filippo.io/age/cmd/age@v${AGE_VERSION}" "filippo.io/age/cmd/age-keygen@v${AGE_VERSION}" \
 && bin="$(go env GOPATH)/bin" && { [ -x "$bin/age" ] || bin="$bin/linux_${TARGETARCH}"; } \
 && mkdir /age && cp "$bin/age" "$bin/age-keygen" "$(go env GOMODCACHE)/filippo.io/age@v${AGE_VERSION}/LICENSE" /age/ \
 && chmod 0755 /age/age /age/age-keygen && chmod 0644 /age/LICENSE \
 && go version -m /age/age

FROM pingfederate AS age
COPY --from=age-build /age/ /age/
RUN /age/age --version && /age/age-keygen --version

# --- pgjdbc: PostgreSQL's JDBC driver, checked, in a stage of its own ---
# The stock image carries no PostgreSQL driver (checked 2026-10-06 against the digest above: h2.jar, hsqldb.jar and
# spring-jdbc.jar in server/default/lib, and no class org/postgresql/Driver in any jar), and every store here that
# talks to PostgreSQL needs one: a direct URL (OIDF_SSF_JDBC_URL, OIDF_AUTHORITY_JDBC_URL ...), which platform's
# DataSources opens with Class.forName("org.postgresql.Driver"), and a PingFederate JDBC data store pointed at
# PostgreSQL (finding F-0330). So the image ships PgJDBC in server/default/lib, beside PingFederate's own libraries,
# where the engine and the webapp both see it - never in modules/, which goes into the war. The version is the one
# the reactor tests with (bom/pom.xml's version.postgresql; tools/pf-version-check.py fails when the two differ), the
# jar comes from Maven Central and is checked against the sha256 recorded here before anything else reads it. The
# sum is of the jar as downloaded on 2026-10-06, and agrees with Central's own postgresql-42.7.13.jar.sha1
# (a6e1bd21b412d6ffb3df23cd13d507bc2cc9e37d) and with the copy in the build's Maven repository. Its licence is
# BSD-2-Clause, and so are the four OnGres libraries it bundles (SCRAM and SASLprep); the jar's own LICENSE and
# licenses/ folder are copied out below, as the terms ask a binary distribution to carry them. To move PgJDBC: change
# the version here and in the BOM, and the sum.
FROM pingfederate AS pgjdbc
USER root
ARG PGJDBC_VERSION=42.7.13
RUN case "$PGJDBC_VERSION" in \
      42.7.13) sum=6e0e4cc2d8cae902084f8a2b18728b073a6fd9d1f87c9d8bff8f298c18185b93 ;; \
      *) echo "ERROR: no checksum recorded for PgJDBC '$PGJDBC_VERSION'" >&2; exit 1 ;; \
    esac \
 && mkdir /pgjdbc \
 && curl -fsSL --retry 3 -o "/pgjdbc/postgresql-${PGJDBC_VERSION}.jar" \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PGJDBC_VERSION}/postgresql-${PGJDBC_VERSION}.jar" \
 && echo "$sum  /pgjdbc/postgresql-${PGJDBC_VERSION}.jar" | sha256sum -c - \
 && mkdir /tmp/pgjdbc-meta \
 && unzip -q "/pgjdbc/postgresql-${PGJDBC_VERSION}.jar" 'META-INF/LICENSE' 'META-INF/licenses/*' -d /tmp/pgjdbc-meta \
 && mv /tmp/pgjdbc-meta/META-INF /pgjdbc/licence

# --- capability: the image with no configuration archive ---
FROM pingfederate AS capability
USER root
ARG STAGING_PROFILE
ARG OCI_VERSION
ARG OCI_REVISION
ARG OCI_CREATED
LABEL io.github.dphhyland.pf-agentic-identity.staging-profile=$STAGING_PROFILE \
      org.opencontainers.image.title="pf-agentic-identity PingFederate" \
      org.opencontainers.image.description="PingFederate 13.1.3 with pf-agentic-identity's modules merged into pf-runtime.war" \
      org.opencontainers.image.source="https://github.com/ID-Partners/pf-agentic-identity" \
      org.opencontainers.image.version=$OCI_VERSION \
      org.opencontainers.image.revision=$OCI_REVISION \
      org.opencontainers.image.created=$OCI_CREATED \
      org.opencontainers.image.licenses="Apache-2.0 AND BSD-3-Clause AND BSD-2-Clause AND LicenseRef-PingIdentity-Proprietary"

# age and age-keygen (the entrypoint needs age; test-entrypoint.sh --image makes its fixtures with age-keygen),
# and age's licence, which its BSD-3-Clause terms ask a binary distribution to carry.
COPY --from=age --chown=0:0 /age/age /age/age-keygen /usr/local/bin/
COPY --from=age --chown=0:0 /age/LICENSE /usr/local/share/licenses/age/LICENSE

# PgJDBC (the pgjdbc stage above) into PingFederate's own library directory, which the base image's bootstrap copies
# from /opt/in to /opt/out at every start as it does deploy/, and its licences - PgJDBC's LICENSE and the licenses/
# folder that LICENSE points to, as the jar carries them.
COPY --from=pgjdbc --chown=0:0 /pgjdbc/licence/ /usr/local/share/licenses/pgjdbc/

# The assembled war from the builder. The directories above deploy/ are PingFederate's user's, as the archive's
# COPY used to leave them when it came first.
COPY modules/ /tmp/modules/
RUN mkdir -p /opt/in/instance/server/default/deploy \
 && chown 9031:0 /opt/in/instance /opt/in/instance/server /opt/in/instance/server/default
COPY --from=builder --chown=9031:0 /build/pf-runtime.war /opt/in/instance/server/default/deploy/pf-runtime.war
COPY --from=pgjdbc --chown=9031:0 /pgjdbc/*.jar /opt/in/instance/server/default/lib/

# ALSO place the module jars on the ENGINE classpath (server/default/deploy): the token-endpoint OGNL
# issuance criteria evaluate on the engine classloader, which does NOT search pf-runtime.war's
# WEB-INF/lib — without this, @ClientAttestationUtils@validateClientAttestation fails as an opaque
# OGNL "Method failed" (ClassNotFoundException). The webapp and engine copies communicate only via
# request attributes with string keys, so the dual-classloader split is by design. jose4j is already
# in server/default/lib.
RUN cp /tmp/modules/*.jar /opt/in/instance/server/default/deploy/ \
 && chown 9031:0 /opt/in/instance/server/default/deploy/*.jar \
 && rm -rf /tmp/modules

# The CIBA simulator's decision directory, conformance profile only. plugins/ciba-sim refuses every
# request unless OIDF_CIBA_SIM_DIR names a directory that exists, is not a symlink, is owned by the user
# PingFederate runs as and is 0700: it is the handoff between the plugin's two classloaders, and anyone
# else who could write to it could approve a request. Made here so the rig's vars.env can simply name
# it; outside /opt/out, which the base image's bootstrap populates by copying without preserving modes.
# A production image has neither the jar nor the directory.
RUN if [ "$STAGING_PROFILE" = conformance ]; then \
      mkdir -m 0700 /opt/ciba-sim && chown 9031:0 /opt/ciba-sim && echo 'ciba-sim: /opt/ciba-sim made for the simulator (conformance profile)'; \
    else echo 'ciba-sim: not in this image (production profile)'; fi

# PingFederate's plain HTTP runtime listener, off as PingFederate ships it and switchable at run time. The base
# image's run.properties template has pf.http.port=-1 written out, where its neighbours read variables
# (pf.https.port=${PF_ENGINE_PORT}); this has it read PF_RUN_PF_HTTP_PORT - the base image's PF_RUN_PF_* naming -
# which the base image's 05-expand-templates.sh substitutes at boot as it does the others. -1 is off, and the
# entrypoint refuses any port outside the development profile. (Checked 2026-09-29 in the 13.1.3 image: no
# variable of the base image's own reaches pf.http.port.) The template's lines end CRLF, and the sed keeps the CR.
ENV PF_RUN_PF_HTTP_PORT=-1
RUN F=/opt/staging/instance/bin/run.properties.subst.default \
 && sed -i 's/^pf\.http\.port=-1\([[:space:]]*\)$/pf.http.port=${PF_RUN_PF_HTTP_PORT}\1/' "$F" \
 && [ "$(grep -c '^pf\.http\.port=' "$F")" = 1 ] \
 && grep -q '^pf\.http\.port=\${PF_RUN_PF_HTTP_PORT}[[:space:]]*$' "$F"

# server.log prints PingFederate's request id beside its tracking id (F-0395). A refusal answered at one of our
# filters runs before PingFederate's endpoint code sets a tracking id, so its reference is PingFederate's
# httprequestid (docs/operator/logging.md); with the stock pattern ("%d %X{trackingid} %-5p [%c] %m%n") no
# PingFederate line printed it. The stock log4j2.xml's own comment lists %X{httprequestid} as an available field.
# The edited copy goes into /opt/in, which the base image's bootstrap lays over the instance at every start, as it
# does deploy/ and lib/; a server profile's own log4j2.xml still wins. The checks fail the build if the stock pattern
# ever changes rather than ship an unedited file.
RUN S=/opt/server/server/default/conf/log4j2.xml D=/opt/in/instance/server/default/conf/log4j2.xml \
 && [ "$(grep -c '<pattern>%d %X{trackingid} %-5p \[%c\] %m%n</pattern>' "$S")" = 1 ] \
 && mkdir -p /opt/in/instance/server/default/conf \
 && sed 's|<pattern>%d %X{trackingid} %-5p \[%c\] %m%n</pattern>|<pattern>%d %X{trackingid} %X{httprequestid} %-5p [%c] %m%n</pattern>|' "$S" > "$D" \
 && [ "$(grep -c '<pattern>%d %X{trackingid} %X{httprequestid} %-5p \[%c\] %m%n</pattern>' "$D")" = 1 ] \
 && [ "$(grep -vxFf "$D" "$S" | wc -l)" = 1 ] \
 && chown -R 9031:0 /opt/in/instance/server/default/conf

# Check and decrypt the archive at boot, with the identity gone from the environment before PingFederate
# starts, then hand over to the base image's own bootstrap. build/pingfederate/test-entrypoint.sh --image
# exercises its decisions in the built image, and the healthcheck's.
COPY --chown=9031:0 pf-entrypoint.sh pf-healthcheck.sh /opt/
RUN chmod 755 /opt/pf-entrypoint.sh /opt/pf-healthcheck.sh

# The runtime (HTTPS) and admin ports, as the base image declares them; the plain HTTP listener is off unless
# the deployment turns it on, so it is not declared. The healthcheck is live, not ready: see pf-healthcheck.sh
# and README.md, "The healthcheck". It replaces the base image's (liveness.sh alone), which it runs first; the
# timings are the base image's.
EXPOSE 9031 9999
HEALTHCHECK --interval=31s --timeout=29s --start-period=241s --retries=7 CMD ["/opt/pf-healthcheck.sh"]

USER 9031:0
ENTRYPOINT ["/opt/pf-entrypoint.sh"]

# --- deployment: capability plus the configuration (the default target) ---
FROM capability AS deployment
USER root

# Config restore via PF's native drop-in-deployer: the DataDeployer timer imports data.zip on boot
# (no admin API, no license-acceptance gate). The overlay's DataDeployer settings are PingFederate's own
# defaults (README.md, "The drop-in deployer's settings"); the master-key overlay lets the archive's encrypted
# secrets decrypt natively (running master key == archive key).
# data.zip.age (encrypted, preferred) or data.zip (plaintext, transitional); the glob takes whichever
# is staged. It does NOT enforce that one is: a COPY glob matching nothing succeeds silently under
# BuildKit, which would produce an image that boots with no configuration and looks like it worked.
# Hence the assertion below - verified to fail when neither file is present.
COPY --chown=9031:0 data.zip* /opt/in/instance/server/default/data/drop-in-deployer/
RUN D=/opt/in/instance/server/default/data/drop-in-deployer; \
    if [ ! -f "$D/data.zip" ] && [ ! -f "$D/data.zip.age" ]; then \
      echo "ERROR: no config archive staged. Put data.zip.age (preferred) or data.zip in the build" >&2; \
      echo "       context. An image with neither imports nothing and starts an empty PF." >&2; \
      exit 1; \
    fi

# overlay/ as a directory, because under the encrypted scheme pf.jwk and the system keys are NOT staged
# at all - pf-entrypoint.sh extracts them from inside the archive at boot, so the running key is by
# construction the one the archive was encrypted under. config-store/ is plain config and always present.
COPY --chown=9031:0 overlay/ /opt/in/overlay-staged/
RUN D=/opt/in/instance/server/default/data; mkdir -p "$D/config-store"; \
    cp /opt/in/overlay-staged/config-store/*.xml "$D/config-store/"; \
    for f in pf.jwk pingfederate-system-keys.xml; do \
      if [ -f "/opt/in/overlay-staged/$f" ]; then \
        echo "WARNING: staging plaintext $f into an image layer - ship data.zip.age instead"; \
        cp "/opt/in/overlay-staged/$f" "$D/$f"; \
      fi; \
    done; \
    rm -rf /opt/in/overlay-staged; chown -R 9031:0 "$D"
# NB: no pingfederate.lic COPY — the boot hook fetches the license from the DevOps env vars above.

USER 9031:0
# The capability stage's entrypoint and healthcheck: pf-entrypoint.sh places the archive, and the drop-in
# deployer imports data.zip during boot.
