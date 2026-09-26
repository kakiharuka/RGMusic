# Security Policy

## Sensitive data

The application stores NetEase session cookies and account metadata only in the local application data directory on the user's device.

Do not submit or publish:

- `cookies.json`
- `account.json`
- login QR codes
- session tokens or account identifiers
- private keys
- personal music libraries or logs

If a security issue involves credentials, report it privately to the repository maintainers instead of opening a public issue. Remove or rotate any credential that may have been exposed.

## Supported versions

Security fixes are applied to the latest release line. The current public version is `r0.75`.