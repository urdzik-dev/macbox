# Security policy

MacBox is an experimental local virtualization and desktop-control prototype. Its VM boundary and file checks reduce some accidental access and malformed-input risks, but the project is **not verified as a sandbox for hostile code** and is not ready to expose as a public service. See [README.md](README.md) for current implementation and validation status.

## Supported versions and reporting

| Version | Security maintenance |
| --- | --- |
| Current `main` | Experimental; no support commitment or response SLA is published. |
| Other commits or future releases | No support policy is currently defined. |

Please do not open a public issue containing a working exploit, credentials, or sensitive data. If the repository's **Security → Report a vulnerability** feature is enabled, submit a private report there: [private vulnerability reporting](https://github.com/urdzik-dev/macbox/security/advisories/new). Otherwise, contact the repository maintainer privately to arrange a secure reporting channel before sharing details. Include the affected commit, environment, impact, and minimal reproduction steps; avoid real user data. No response or disclosure timeline is guaranteed. Coordinated disclosure timing should be agreed with the maintainer after acknowledgement.

## Trust boundaries

1. The host runs the CLI, VM process, and local stdio MCP server. A client able to invoke that server can ask it to operate a configured guest.
2. The guest has its own macOS installation, files, applications, accounts, and privacy permissions. Its screen, documents, web content, and mailbox responses are untrusted inputs to the host and any AI client.
3. The VM receives two virtio-fs shares: `control` is read/write and `tools` is read-only. The host home directory, clipboard, microphone, and camera are not configured as shared devices by the current VM builder.
4. Default NAT networking is not LAN isolation. The guest may reach network-accessible host and local services; `--offline` omits the network device. The optional user-space NAT mode is also not a security boundary or a VPN-routing guarantee.

## Controls present in the code

### Authentication and authorization

- MCP uses local stdio, rather than exposing an HTTP listener. **There is no application-level MCP authentication, per-tool authorization, or user-approval policy.** Operating-system access to the executable, VM data, and invoking process is therefore significant.
- The virtio-fs mailbox has no peer-authentication token. The control directory is shared with the guest and must be treated as writable by it. UUIDs correlate messages; they are not credentials.
- The optional `gvproxy` path creates a random API token in a mode-0600 file inside a mode-0700 temporary directory and disables its default SSH forwarding. This token is for the proxy API, not MCP or mailbox authorization. The installer script pins the optional helper's download to a SHA-256 digest; an executable supplied via `--vpn-proxy` is chosen by the caller.
- Guest startup checks whether `hw.model` begins with `VirtualMac`. This is an accidental-host-execution guard, not hardware attestation or protection from a compromised host.

### Data and secrets

- For the conditional macOS 27 provisioning path, the code generates a random guest account password and stores it as a generic password in the host user's Keychain. Its UUID reference is stored in VM configuration. This SDK-dependent path has not been built or exercised with macOS 27.
- VM disks, configuration, identity files, restore images, and the exchange directory are stored under `~/.macbox` by default or the configured data directory. Guest screen captures and action data **can be written to the shared mailbox** and returned to the MCP client. Cleanup is attempted, but interruption or failure can leave artifacts. Treat VM storage, backups, temporary files, and client transcripts as sensitive.
- `.gitignore` excludes build output, IPSW files, saved VM-state files, and the downloaded `vendor/` directory. It is not a secret scanner and does not prevent secrets, guest data, or logs from being committed through other paths.
- There is no PII classification, redaction, retention policy, or comprehensive audit log. The host and guest emit status and error messages; privacy properties of all errors and downstream clients have not been audited.

### Input validation and file handling

- The control protocol uses Codable messages, a 32 MiB maximum framed JSON body, UUID request matching, protocol version checks, and request expiry. Text input is limited to 65,536 UTF-8 bytes; coordinates, scroll deltas, click counts, and key-string lengths are bounded.
- The mailbox opens its directory and file entries with `O_NOFOLLOW`, reads only regular files with one link, checks size limits, and uses `openat`/`renameat` with temporary files for publication. Per-request claim files reduce duplicate execution by cooperating agent processes. Timeouts do not guarantee cancellation of an action already in progress.
- Readiness checks validate PNG type and dimensions and attempt to decode the image. This does not mean every MCP screenshot or guest-supplied image is comprehensively validated by all downstream clients.
- The update path validates the installed code and staged candidate against the installed application's designated requirement before an atomic swap; a previous bundle is retained for rollback. Initial trust still depends on the source application and host environment. Stable signing is needed for updates across different builds; ad-hoc builds generally do not share a designated identity. The full update and rollback lifecycle has not been verified in a real guest.
- There is no SQL or database layer in this repository, so database injection controls are not applicable. The MCP endpoint does not implement a general input-line size limit, rate limiting, or complete JSON Schema enforcement.

### Resilience and network assumptions

- A mailbox request defaults to a 15-second timeout; readiness checks use a shorter timeout. Requests carry an expiry, and image downloads may save URLSession resume data on recoverable errors. Resume behavior depends on the OS and server, and hard termination can lose progress.
- VM lifecycle uses advisory file locks and rejects existing VM directories during creation. The checks are not a distributed locking or high-availability system.
- Apple restore-image downloads use the URL provided by Virtualization and URLSession's default transport behavior. The repository does not implement certificate pinning. There is no inbound public HTTP API, CORS policy, Dockerfile, WAF, or container-hardening configuration.
- The optional proxy is an external executable and adds a separate network stack and attack surface. NAT and local socket permissions do not replace firewall rules or egress controls.

## AI-agent threat model

MacBox does not embed an LLM or call a model provider. It returns guest screenshots and status to an external MCP client and accepts that client's desktop actions. A web page, document, terminal output, or application UI in the guest can contain prompt-injection instructions that the external model might interpret as commands. MacBox does **not** classify, sanitize, or filter that content, enforce task boundaries, redact sensitive material, or determine whether an action is safe.

Although the MCP tools do not expose a direct host-shell operation, an authorized client can type into guest applications, including a guest terminal, and can access whatever accounts and network resources are available there. Provider retention, model context, token limits, cost limits, and further action approvals are controlled outside this repository. A SHA-256 unchanged-image check reduces repeated image payloads only when requested; it is not a token budget or abuse-control system.

## Before production or multi-user deployment

- [ ] Complete and document live guest tests for privacy permissions, coordinate alignment, input, screen capture, login items, update identity, rollback, and network modes.
- [ ] Define a supported-version policy, a monitored private disclosure channel, and realistic response targets.
- [ ] Authenticate and authorize MCP clients and individual sensitive operations; add user-controlled approvals and audit logging where needed.
- [ ] Bound and validate MCP input and all untrusted guest responses, including images; add abuse limits and test malformed messages, process crashes, and concurrent clients.
- [ ] Establish a stable signing and distribution process, including identity rotation, notarization where appropriate, and tested recovery from failed or interrupted updates.
- [ ] Apply host firewall and egress controls appropriate to the threat model; do not rely on NAT for isolation. Review the separately supplied network helper and its update process.
- [ ] Protect VM disks, mailbox artifacts, backups, Keychain access, and agent-client transcripts; define retention, redaction, and secure deletion procedures.
- [ ] Define explicit agent instructions and approvals for untrusted screen content and high-impact actions; configure model-provider retention, token budgets, and client-side safeguards separately.
- [ ] Validate restore-image provenance and interrupted-download behavior in the target environment, and test the macOS 27 provisioning path with the required SDK and guest.
