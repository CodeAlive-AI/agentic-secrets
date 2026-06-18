# Security Policy

Agentic Secrets is security-sensitive software. Please do not disclose suspected vulnerabilities in public issues, discussions, pull requests, screenshots, logs, or social media before maintainers have had time to investigate.

## Supported Versions

Agentic Secrets is currently `0.1.0 alpha`. The storage format, CLI UX, and trust policy may change before a stable release. Security fixes target the `main` branch until release branches exist.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting for this repository when available. If it is not available to you, open a minimal public issue that says you need a private security contact, without technical details or proof-of-concept material.

Include privately:

- affected commit or version
- macOS and Swift/Xcode versions
- concise impact description
- reproduction steps using synthetic placeholder secrets only
- logs or screenshots with all sensitive values redacted

Do not include real provider tokens, private keys, Bitwarden item data, shell environment dumps, Keychain contents, or secret-derived output.

## Scope

High-priority reports include:

- plaintext secret exposure in logs, manifests, registries, audit exports, UI, or process environment beyond the approved delivery boundary
- bypass of LocalAuthentication for secret delivery, trust refresh, or grant creation
- registry, grant, manifest, or policy-pack tampering that does not fail closed
- command shim or broker IPC authentication bypass
- provider binding behavior that can resolve more secret material than approved for one invocation

Agentic Secrets does not claim to sandbox arbitrary commands or make target tools trustworthy. Reports that rely on a malicious approved binary reading its own delivered secret are normally out of scope unless Agentic Secrets delivered a broader secret than policy allowed.
