import { build } from "esbuild";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const output = fileURLToPath(new URL("../app/assets/builds/", import.meta.url));
await mkdir(output, { recursive: true });
const built = await build({ entryPoints: [fileURLToPath(new URL("application.js", import.meta.url))], bundle: true, format: "esm", target: "es2022", minify: true, legalComments: "inline", write: false });
const files = { "rails_ai_admin.js": built.outputFiles[0].text, "rails_ai_admin.css": await readFile(new URL("application.css", import.meta.url), "utf8") };
files["rails_ai_admin.LICENSE.txt"] = "Turbo 8.0.23\n" + await readFile(new URL("licenses/turbo.txt", import.meta.url), "utf8") + "\nStimulus 3.2.2\n" + await readFile(new URL("licenses/stimulus.txt", import.meta.url), "utf8") + "\nrails_tool_views 1.0.2 (Stimulus controller)\n" + await readFile(new URL("licenses/rails_tool_views.txt", import.meta.url), "utf8");
for (const [name, contents] of Object.entries(files)) {
  if (process.argv.includes("--check")) {
    if (await readFile(output + name, "utf8") !== contents) throw new Error(`${name} is stale; run npm run build`);
  } else { await writeFile(output + name, contents); }
}
