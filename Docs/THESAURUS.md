# Agentic Secrets Thesaurus

This thesaurus is the source of truth for durable domain names in code, docs, UI, scripts, package targets, config keys, and release artifacts.

## Name Rendering

- Use `Agentic Secrets` for user-visible product text, macOS window titles, menus, prompts, and `CFBundleName` / `CFBundleDisplayName`.
- Use `AgenticSecrets` for Swift executable products, bundle directory names, app filesystem paths, signing artifacts, and other shell-facing technical identifiers that benefit from no quoting.
- Use `agentic-secrets` for command-line binaries, config filenames, runtime directories, and other kebab-case Unix-facing identifiers.
- Use `com.agenticsecrets` for reverse-DNS identifiers.

## Canonical Terms

### Agentic Secrets
- **Definition**: The macOS product that brokers explicit, bounded, auditable runtime delivery of local secrets to approved developer tools.
- **NOT**: A general endpoint protection product, sandbox, vault, or execution safety system.
- **Synonyms to AVOID**: secret manager, vault.

### Secret Broker
- **Definition**: The local authority that applies policy, authorizes requests, resolves secret material, and brokers delivery.
- **NOT**: A generic core module or service manager.
- **Synonyms to AVOID**: Core, daemon broker, manager.
- **Related terms**: Control Plane, Delivery Request, Local Secret Store.

### Control Plane
- **Definition**: The local UI and IPC surface used to inspect state, configure delivery contracts, and perform administrative actions.
- **NOT**: The component that reads secret values directly.
- **Synonyms to AVOID**: Management, admin service.
- **Related terms**: Secret Broker, Audit Event.

### Local Secret Store
- **Definition**: The owner-only encrypted local store that holds secret material behind local authentication.
- **NOT**: A cloud vault, shared keychain group, or plaintext config file.
- **Synonyms to AVOID**: Vault, secret database.
- **Related terms**: Secret Broker, Secret Alias.

### Secret Alias
- **Definition**: A stable local identifier for secret material that can be referenced by policy and audit without exposing the value.
- **Synonyms to AVOID**: Secret ID when referring to local identifiers, token name.
- **Related terms**: Environment Secret Binding, Bitwarden Secret Binding.

### CLI Delivery
- **Definition**: Delivery of approved secret material to a registered command-line tool for one invocation.
- **NOT**: Ambient shell environment injection.
- **Synonyms to AVOID**: CLI secrets, raw env delivery.
- **Related terms**: Command Line Tool Registration, Environment Secret Binding, Command Shim.

### Command Line Tool Registration
- **Definition**: The trusted local record of a command-line tool, its target identity, and its secret bindings.
- **Synonyms to AVOID**: CLI app registration, tool metadata.
- **Related terms**: Tool Registry Integrity, Environment Secret Binding.

### Environment Secret Binding
- **Definition**: A mapping from an environment variable name to a local secret alias for a registered command-line tool.
- **NOT**: A stored environment variable value.
- **Synonyms to AVOID**: CLI environment binding, env secret.
- **Related terms**: CLI Delivery, Secret Alias.

### Command Shim
- **Definition**: A signed helper invoked through tool-name symlinks to request brokered CLI delivery.
- **NOT**: A generated shell script.
- **Synonyms to AVOID**: Shim script, shell shim.
- **Related terms**: CLI Delivery, Secret Broker.

### Delivery Request
- **Definition**: A structured request describing which secret may be delivered, by which mechanism, to which local context.
- **Synonyms to AVOID**: Delivery intent.
- **Related terms**: Delivery Decision Manifest, Delivery Mechanism.

### Delivery Decision Manifest
- **Definition**: The deterministic record used to explain and authorize a delivery decision.
- **Synonyms to AVOID**: Decision manifest.
- **Related terms**: Delivery Request, Delivery Contract, Audit Event.

### Delivery Contract
- **Definition**: A bounded safety claim describing what a delivery channel guarantees and explicitly does not guarantee.
- **Synonyms to AVOID**: Bounded safety profile, delivery claim.
- **Related terms**: Delivery Channel, Security Invariant.

### Delivery Channel
- **Definition**: A high-level delivery path such as CLI delivery, API session delivery, Bitwarden provider delivery, or remote MCP delivery.
- **Synonyms to AVOID**: Delivery flow.
- **Related terms**: Delivery Mechanism.

### Delivery Mechanism
- **Definition**: The concrete transfer mechanism used by a delivery channel, such as environment variable, stdin, API session, token file, MCP header, provider fetch, or cloud identity.
- **Synonyms to AVOID**: Delivery mode.
- **Related terms**: Delivery Channel.

### Delivery Grant
- **Definition**: A short scoped local-authentication reuse grant bound to the command, target, workspace, policy context, and secret alias.
- **NOT**: A bearer credential or secret value.
- **Synonyms to AVOID**: Unlock grant.
- **Related terms**: Remembered Approval, Delivery Request.

### Remembered Approval
- **Definition**: A persistent local approval for a narrowly scoped delivery request when policy allows remembering.
- **NOT**: A bypass of policy evaluation.
- **Synonyms to AVOID**: Persistent allow grant.
- **Related terms**: Delivery Grant.

### API Session
- **Definition**: A bounded localhost session that gives a client a local endpoint and per-session token while keeping the upstream API key inside the brokered provider path.
- **Synonyms to AVOID**: Proxy session.
- **Related terms**: API Session Profile.

### API Session Profile
- **Definition**: A pinned upstream origin, method/path allowlist, token TTL, and secret alias used to create API sessions.
- **Synonyms to AVOID**: Proxy profile.
- **Related terms**: API Session.

### MCP Profile
- **Definition**: A pinned Model Context Protocol upstream profile used for bounded authorization injection.
- **NOT**: A generic agent access profile.
- **Synonyms to AVOID**: Agent access profile.
- **Related terms**: MCP Bridge Session.

### Bitwarden Provider Binding
- **Definition**: Local metadata that authorizes one exact Bitwarden Secrets Manager secret for a brokered invocation without exposing fetched values.
- **Synonyms to AVOID**: BWS binding.
- **Related terms**: Bitwarden Secret Binding, Provider Environment.

### Bitwarden Secret Binding
- **Definition**: The durable domain record for a Bitwarden project ID, secret ID digest, local alias, and provider environment.
- **Synonyms to AVOID**: BWS secret binding.
- **Related terms**: Bitwarden Provider Binding.

### Command Policy Pack
- **Definition**: A signed command-classification payload that teaches the broker how to classify supported command-line tools.
- **NOT**: A secret or runtime credential.
- **Synonyms to AVOID**: Adapter pack.
- **Related terms**: Command Adapter, Policy Pack Trust Configuration.

### Command Adapter
- **Definition**: The runtime classifier role that turns a command invocation into a normalized command and action class.
- **Synonyms to AVOID**: Adapter when the policy-pack boundary is meant.
- **Related terms**: Command Policy Pack.

### Tool Registry Integrity
- **Definition**: The device-local integrity protection for registered command-line tool metadata.
- **Synonyms to AVOID**: CLI registry integrity.
- **Related terms**: Command Line Tool Registration.

### Audit Event
- **Definition**: A redacted record of a delivery decision or related control-plane action.
- **NOT**: A log containing secret values.
- **Synonyms to AVOID**: Raw audit log entry.

### Security Invariant
- **Definition**: A named product rule that must hold across implementation, release gates, and contract tests.
- **Synonyms to AVOID**: Product invariant when the rule is security-specific.

## Forbidden Lexicon

- **Vault**: Avoid because it overclaims the boundary and conflicts with industry expectations.
- **Central authority**: Use Secret Broker for the central local authority.
- **Management**: Use Control Plane for administrative UI and IPC surfaces.
- **Unlock Grant**: Use Delivery Grant.
- **Proxy Profile / Proxy Session**: Use API Session Profile / API Session.
- **BWS Binding**: Use Bitwarden Provider Binding or Bitwarden Secret Binding.
- **Service / Manager / Info / Data**: Avoid in durable domain-bearing names unless required by a platform API.
