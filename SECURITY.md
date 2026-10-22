# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue: use
[**Report a vulnerability**](https://github.com/alphaexposure/kapitsa-launcher/security/advisories/new)
on this repository's Security tab. Include what you found, how to reproduce it, and which
version you used. You'll get a reply as soon as possible; this is a small, single-maintainer
project.

## Scope

This policy covers Kapitsa Launcher itself, for example:

- how it stores and passes the API key (Keychain, environment, log redaction);
- how it starts and stops Kapitsa (it launches the executable directly with an explicit
  argument list, and stops only processes it started);
- anything that could expose data from your Mac.

Problems in Kapitsa itself belong with that project:
[nace-ai/kapitsa](https://github.com/nace-ai/kapitsa).

## Supported versions

Fixes go into the latest release. Please check that the problem still happens there.
