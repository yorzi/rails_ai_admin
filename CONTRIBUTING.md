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

## Refresh the demo screenshots

From the repository root, install Playwright in the ignored `tmp` directory. It is only needed to run the browser tour and does not change the gem's dependencies.

```sh
npm install --prefix tmp/demo-browser --no-save --no-package-lock playwright@1.65.1
tmp/demo-browser/node_modules/.bin/playwright install chromium
bin/demo --port 3957
```

In a second terminal run `node script/demo/screenshots.cjs 3957`. The script writes to `tmp/demo-screenshots` only after the tour passes. It edits sample records, so restart the offline demo before each run. Inspect the images, then copy the six PNGs to `docs/site/assets/images/screenshots/`. For the 0.9 workflow, start a fresh demo and run `node script/demo/recipe_tour.cjs 3957`. It creates a report from chat, approves a recipe with a second account, and follows a 125-row import through Tasks. Press Ctrl-C in the first terminal to stop both demo servers.
