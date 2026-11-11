# Security

Do not post credentials or suspected exploitable secrets in a public issue. Use GitHub's private vulnerability reporting for this repository when enabled; otherwise contact the maintainer privately before sharing sensitive details.

Release signing and notarization credentials are local/private. No private signing keys, relay administration credentials, hosting credentials, or production certificates belong in this repository. Client-visible service URLs and public verification material are not authentication secrets.

The public snapshot excludes the hosted services and deployment tooling. Public relay listings indicate availability, not an independent security certification. Passwords and invite codes restrict rooms; they are not a substitute for emulator and operating-system updates.

Secret scanning reduces accidental exposure but is not a mathematical guarantee. Review every release/export, including generated files and binary assets. Never add real credentials to the provided placeholder templates.
