# Security

Yank holds what you copy, so security reports are taken seriously.

## Reporting a problem

Please do not open a public issue. Report it privately through GitHub:
[Report a vulnerability](https://github.com/ThatTechedGuy/Yank/security/advisories/new).

Say what you found, how to reproduce it, and which version of Yank and macOS you used.

## Supported versions

Only the latest release gets fixes.

## What counts

- Copied content leaving the Mac, or reaching the system log.
- A copy marked private by its app being saved.
- Another process reading Yank's history without the user's permission.
- A link preview loading an address it should not.

The history is not encrypted by Yank: someone with access to your user account or an unencrypted disk can
read it. That is a known limit, not a vulnerability.
