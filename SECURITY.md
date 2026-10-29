# Security policy

This project is unreleased and has no supported production release yet. Do not
use it for real administrative access until the documented security and release
gates pass.

Report suspected vulnerabilities privately to wangyaodi@gmail.com. Include the
affected version, minimal synthetic reproduction, impact and suggested fix.
Do not open a public issue containing exploit details or sensitive data. Reports
are reviewed by the maintainer; no response-time SLA is currently offered.

Authentication and policies belong to the host. A logged-in actor alone grants
no resource access. Trusted Ruby extensions are not sandboxed. See the threat
model and public contract for the supported transaction and privacy boundaries.
