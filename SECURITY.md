# Security

Please do not open public issues containing Feishu App Secrets, webhook URLs,
pairing codes, user IDs, Codex session data, or local logs. Report security
issues privately through GitHub Security Advisories.

Credentials are encrypted with Windows DPAPI in the `CurrentUser` scope. The
bridge intentionally rejects group chats, unpaired users, oversized images,
unsupported image signatures, and outbound image paths outside the active
workspace or Codex visualizations directory.

