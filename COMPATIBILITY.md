# Compatibility

Only observed combinations are evidence. CI configuration is not a CI result.

| Component | Required range | Current evidence |
| --- | --- | --- |
| Ruby | 3.4 or newer | Local development: 4.0.9; 3.4 not yet run |
| Rails | 8.1.4 to below 8.2 | First validation line: 8.1.4 |
| rails_tool_views | 1.0.1 to below 1.1 | Published 1.0.1 package, SHA-256 b35d792611e46e55b1be1b79898fab39445bebc7583d7e1e67ae7229468ada1e |
| RubyLLM | 2.1.1 to below 3 | Baseline 2.1.1; no provider evidence |
| Database | SQLite / PostgreSQL targets | Tests and packaged hosts must identify each executed combination |
| Assets | Propshaft / Sprockets targets | Strict CSP and browser checks remain mandatory |

Unsupported until explicitly validated: MySQL, composite keys, multiple mounts,
shards, cross-pool atomic writes, arbitrary host JS extensions, AI sessions,
Surface dispatch, private attachments, imports, exports and background operations.
Only models with optimistic locking (`lock_version`) can use generic writes.

RubyGems name lookup returned HTTP 404 on 2026-10-29. No name is reserved, no
remote repository is assumed, and no trademark clearance is claimed.
