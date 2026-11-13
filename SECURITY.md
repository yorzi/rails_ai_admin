# Security policy

0.1.0 is a Public Preview. Review the limitations in CHANGELOG.md and deploy
behind your host application's authentication and network controls. Verify
tenant scopes and action and field grants before granting access.

Report suspected vulnerabilities privately to wangyaodi@gmail.com. Include the
affected version, minimal synthetic reproduction, impact and suggested fix.
Do not open a public issue containing exploit details or sensitive data. Reports
are reviewed by the maintainer; no response-time SLA is currently offered.

Authentication and policies belong to the host. A logged-in actor alone grants
no resource access. Trusted Ruby extensions are not sandboxed. See the threat
model and public contract for the supported transaction and privacy boundaries.
