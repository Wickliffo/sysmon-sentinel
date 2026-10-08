# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a suspected security vulnerability. Email the repository maintainer privately or use GitHub's private vulnerability reporting feature once enabled.

Include:

- A clear description of the impact
- Reproduction steps or a minimal proof of concept
- Affected version or commit
- Any suggested mitigation

Do not include live webhook URLs, credentials, hostnames, or private logs in a report.

## Operational security

- Run the monitor as root only because it needs to restart systemd services.
- Keep `/etc/sysmon-sentinel/webhook.url` and `sysmon-sentinel.env` mode `0600`.
- Never commit webhook URLs or tokens.
- Review the configured service allowlist before enabling the unit.
