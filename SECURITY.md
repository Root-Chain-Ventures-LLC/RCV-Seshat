# Security policy

Seshat is developed by Root Chain Ventures. We take reports of vulnerabilities in Seshat seriously and
handle them as follows.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting on the public distribution
repository (Security tab, then "Report a vulnerability"). Do not open public issues, pull requests or
discussions for security problems, and do not post details publicly before a fix is available.

When you report, include:

* the version (`seshat --version`) and how it is deployed (package, container, Helm);
* what you did, what you expected and what happened, with the smallest reproduction you can give;
* the impact you believe it has, and whether it needs a network position, credentials or user interaction.

Use synthetic data in anything you send: no real device names, addresses or credentials.

## What to expect

We acknowledge reports, assess them, and tell you whether we consider them a vulnerability. Confirmed issues
are fixed privately and released with a CHANGELOG entry under "Security"; we credit the reporter if they wish.
We do not promise fixed response or fix times, but we keep you informed of progress and agree a disclosure
date with you: please allow us to release a fix before you publish.

## Supported versions

| Version | Security fixes |
|---|---|
| Latest release | yes |
| Older releases | no: upgrade (see [`docs/hardening.md`](docs/hardening.md), "Upgrading") |

## Verifying what you run

Releases carry a signed `SHA256SUMS`, SBOMs and signed container images. See
[`docs/hardening.md`](docs/hardening.md), "Verifying a release", for the commands. Operator guidance on
deploying Seshat safely is in the same document.
