# Contributing

Start with ARCHITECTURE.md, COMPATIBILITY.md and docs/reference/public-contract.md.
Keep changes focused. Add a failing regression test before changing an authority,
transaction or persistence boundary. Document public API changes with the code.

Use synthetic data. Never include credentials, production records, provider
transcripts of real data or private files. Report vulnerabilities privately under
SECURITY.md.

The only provider recordings in the repository are the OpenRouter cassettes in
`test/cassettes/openrouter`: synthetic test data, recorded through
`test/support/recorded_provider.rb`, which keeps only the Content-Type header and
filters the key. The suite replays them offline. Record them again only when you
change the assistant's instructions, tools or an evaluation question (the suite
says so), with `OPENROUTER_API_KEY` loaded from an env file, never typed on the
command line; recording costs a few cents. After changing only the grader, use
`RAA_REGRADE=1` instead, which calls no provider. Check the diff for anything but
synthetic data before committing.

Contributions are provided under the project's MIT license; no CLA is required.

Local research, issue/PR drafts and one-off reports belong in ignored `drafts/`.
Do not stage that directory. Commit coherent, verified milestones using your Git
identity. Stop all task-owned services before finishing.
