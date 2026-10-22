# Security policy

The artefacts released here run inside PingFederate, so a defect in them is a defect in someone's token
endpoint. Please report one privately.

## Reporting a vulnerability

Use this repository's private vulnerability reporting: the **Security and quality** tab (under the ... menu on a
narrow window), then **Report a vulnerability**. It opens a draft advisory that only the maintainers can see. Do not open an issue, a discussion or a pull request
that names the module, the endpoint or the trigger.

Say what you found, which release and which artefact, how to reproduce it, and what you think it lets an
attacker do. A proof of concept is welcome; a working exploit against someone else's deployment is not. The
report is acknowledged, the defect confirmed, and the fix released with a note under "Before you deploy" in
that release's notes when a consumer has to act. Credit is given in the release notes unless you would rather
not be named.

## Supported versions

| Version | Supported |
|---|---|
| The latest 0.x release | Yes - fixes land in the next release |
| Earlier 0.x releases | No - move to the latest release |

## Scope

- The released artefacts: the module jars, the wars and the plugin jars.
- The image build under `image/`.
- The demo's configuration under `demo/`, where it would carry into a deployment.

PingFederate itself, PingAuthorize and the Ping Identity images are out of scope: report those through Ping
Identity's own disclosure process.

## Config archives and key material

A PingFederate configuration archive is a plain zip holding `pf.jwk`, the master key that decrypts every secret
in it, beside the system keys, the keystores and the admin password hash. Never commit one, or any key, to a
repository: this repository's `.gitignore` ignores `data*.zip`, `*.jwk`, `pingfederate-system-keys.xml`,
`*.jks`, `*.p12`, `*.pfx` and `*.lic`. Keep an age identity, whatever its file name, in a password manager and
a sealed runtime variable, never beside the archive it decrypts. A key that was public once stays public: the
fix is rotation, not deletion.
