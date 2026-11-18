// Run against a freshly started offline bin/demo. This tour changes its sample data.
const assert = require("node:assert/strict");
const { mkdir, readFile, writeFile } = require("node:fs/promises");
const { join, resolve } = require("node:path");
const { chromium } = require("../../tmp/demo-browser/node_modules/playwright");

const root = resolve(__dirname, "../..");
const port = Number(process.argv[2] || 3917);
assert(Number.isInteger(port) && port >= 1024 && port <= 65534, "Use a valid demo port");
const origin = `http://127.0.0.1:${port}`;
const output = resolve(process.argv[3] || join(root, "tmp/demo-screenshots"));
const csvFile = join(__dirname, "showcase/articles-import.csv");

async function tour(page) {
  const shots = new Map();
  const main = page.getByRole("main");
  const button = (name) => page.getByRole("button", { name, exact: true });
  const link = (name) => page.getByRole("link", { name, exact: true });
  const field = (name) => page.getByLabel(name, { exact: true });
  const heading = (name) => main.getByRole("heading", { name, exact: true });
  const rows = () => main.locator("tbody tr");
  const visit = async (path) => {
    const response = await page.goto(`${origin}${path}`);
    assert(response.ok(), `${path}: HTTP ${response.status()}`);
  };
  const shot = async (name, options = {}) => {
    await page.evaluate(() => window.scrollTo(0, 0));
    shots.set(name, await page.screenshot({ animations: "disabled", ...options }));
  };
  const signIn = async (role) => {
    await visit("/login");
    await page.getByRole("heading", { name: "Rails AI Admin demo", exact: true }).waitFor();
    await button(`Sign in as ${role}`).click();
    await heading("Overview").waitFor();
  };
  const chat = async (prompt, result) => {
    await field("Message").fill(prompt);
    await button("Send").click();
    await result.waitFor();
    await main.locator("[data-raa-pending]").waitFor({ state: "hidden" });
  };

  console.log("Overview, global search and list tools");
  await signIn("Admin");
  await main.getByText("Orders waiting for review", { exact: true }).waitFor();
  await shot("overview");
  await page.locator("#raa-global-search").fill("upgrading");
  await page.locator("#raa-global-search").press("Enter");
  await main.getByRole("link", { name: "Article 2: Upgrading" }).waitFor();
  await visit("/staff/articles");
  await main.getByRole("link", { name: "Article 1: Getting started", exact: true }).waitFor();
  await shot("list");
  await main.locator("summary").getByText("Filters", { exact: true }).click();
  await field("Contact contains").fill("editor1");
  await button("Apply filters").click();
  await page.waitForURL((url) => url.searchParams.get("filter[contact][contains]") === "editor1");
  await main.getByText("Save this view", { exact: true }).click();
  await field("Name for the current view").fill("Editor contacts");
  await button("Save view").click();
  await link("Editor contacts").waitFor();
  const download = page.waitForEvent("download");
  await button("Export CSV").click();
  const csv = await readFile(await (await download).path(), "utf8");
  assert(csv.includes("editor1@example.test") && !csv.includes("editor0@example.test"), "CSV should use the active filter");

  console.log("Edit a record with typed fields and an association");
  await visit("/staff/articles/1");
  await link("Summary of article 1").waitFor();
  const coverUrl = await main.getByRole("link", { name: /cover-1\.png/ }).getAttribute("href");
  const cover = await page.request.get(`${origin}${coverUrl}`);
  assert(cover.ok() && cover.headers()["content-disposition"].startsWith("attachment;"));
  const image = await cover.body();
  assert.equal(image.subarray(1, 4).toString(), "PNG");
  // Open a fresh document for Trix rather than carrying a previous page's CSP.
  await visit("/staff/articles/1/edit");
  await heading("Edit Article 1: Getting started").waitFor();
  await main.getByRole("tab", { name: "Content", exact: true }).click();
  await main.locator("trix-editor").waitFor();
  await shot("form", { fullPage: true });
  await main.locator("trix-editor").fill("A short rich text edit from the demo tour.");
  await main.locator('input[type="file"][name="record[cover]"]').setInputFiles({
    name: "cover-from-demo.png", mimeType: "image/png", buffer: image,
  });
  await main.getByRole("tab", { name: "Details", exact: true }).click();
  await field("Views").fill("42");
  await button("Save").click();
  await main.getByText("Changes saved.", { exact: true }).waitFor();
  await main.getByText("A short rich text edit from the demo tour.", { exact: true }).waitFor();
  await main.getByRole("link", { name: /cover-from-demo\.png/ }).waitFor();

  console.log("Assistant search, grouped totals, single review, bulk review and audit");
  await link("Assistant").click();
  await button("New conversation").click();
  await chat("search articles for upgrading", main.getByRole("link", { name: "Article 2: Upgrading" }));
  await chat("sum orders total by state", main.getByText(/The sum of total is/));
  await chat("set articles 1 title to Hello", button("Confirm and execute"));
  // Frame the proposal header as well as its controls, rather than the latest reply.
  await main.locator(".raa-chat-surface").evaluate((card) => {
    const thread = card.closest(".raa-conversation-thread");
    thread.scrollTop += card.getBoundingClientRect().top - thread.getBoundingClientRect().top - 24;
  });
  await shot("assistant");
  const articleBefore = await page.request.get(`${origin}/staff/articles/1`);
  assert.match(await articleBefore.text(), /<h1>Article 1: Getting started<\/h1>/);
  await button("Confirm and execute").click();
  await main.getByText(/The confirmed change was applied/).waitFor();
  await chat("set customers points to 50 for Bulk", link("Review the change to 30 records"));
  await link("Review the change to 30 records").click();
  await button("Update 30 records").waitFor();
  assert.equal(await rows().count(), 30);
  await shot("bulk-review");
  await button("Update 30 records").click();
  await main.getByText("Updated 30 records.", { exact: true }).waitFor();
  await visit("/staff/articles/1");
  await heading("Hello").waitFor();
  await link("History").click();
  await heading("History of Hello").waitFor();
  await main.getByText("From a review in Chat", { exact: true }).waitFor();
  await shot("history");
  await link("Audit log").click();
  await heading("Audit log").waitFor();
  assert(await rows().count() > 30, "Audit should include the form, export and assistant changes");

  console.log("Concurrent edits cannot overwrite the winning save");
  const stale = await page.context().newPage();
  try {
    await stale.goto(`${origin}/staff/articles/1/edit`);
    await visit("/staff/articles/1/edit");
    await field("Views").fill("43");
    await button("Save").click();
    await main.getByText("Changes saved.", { exact: true }).waitFor();
    await stale.getByLabel("Views", { exact: true }).fill("44");
    const rejected = stale.waitForResponse((response) =>
      response.url() === `${origin}/staff/articles/1` && response.request().method() === "POST");
    await stale.getByRole("button", { name: "Save", exact: true }).click();
    assert.equal((await rejected).status(), 409);
  } finally {
    await stale.close();
  }

  console.log("CSV validation, import, bulk soft delete and restore");
  await visit("/staff/articles/imports/new");
  await field("CSV file").setInputFiles(csvFile);
  await button("Check file").click();
  await main.getByText("2 of 3 rows can be imported.", { exact: true }).waitFor();
  await field("CSV file").setInputFiles(csvFile);
  await button("Import").click();
  await main.getByText("Created 2 of 3 records.", { exact: true }).waitFor();
  await visit("/staff/articles");
  await field("Select Article 2: Upgrading").check();
  await field("Select Article 3: Policies").check();
  await button("Delete selected").click();
  await heading("Delete selected records").waitFor();
  await button("Delete 2 records").click();
  await visit("/staff/articles/deleted");
  await button("Restore Article 2: Upgrading").click();
  await main.getByText("Restored the record.", { exact: true }).waitFor();

  console.log("Member and queued collection actions");
  await visit("/staff/orders/1");
  await link("Review order").click();
  await main.getByRole("combobox", { name: "Decision", exact: true }).selectOption("approve");
  await main.getByRole("textbox", { name: "Note", exact: true }).fill("Approved in the demo tour");
  await button("Review operation").click();
  await button("Confirm and execute").click();
  await main.getByText("Operation completed.", { exact: true }).waitFor();
  await visit("/staff/customers");
  await field("Select Ada Lovelace").check();
  await field("Select Grace Hopper").check();
  await button("Award points to selected customers").click();
  await main.getByRole("spinbutton", { name: "Amount", exact: true }).fill("5");
  await button("Review changes").click();
  await button("Confirm and queue").click();
  await page.waitForURL("**/staff/jobs/*");
  // The job page is a snapshot; refresh while the in-process worker runs.
  const finished = main.getByRole("cell", { name: "Succeeded", exact: true });
  for (const deadline = Date.now() + 8_000; Date.now() < deadline && await finished.count() !== 2;) {
    await page.reload();
    await finished.nth(1).waitFor({ timeout: 250 }).catch((error) => {
      if (error.name !== "TimeoutError") throw error;
    });
  }
  assert.equal(await finished.count(), 2);

  console.log("MCP read, proposal and revocation; no token is captured");
  await link("MCP access").click();
  await field("Name").fill("Screenshot tour");
  await button("Create token").click();
  const token = await main.locator("code.raa-token").textContent();
  const tool = (name, args) => page.request.post(`${origin}/staff/mcp`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json, text/event-stream" },
    data: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: { resource: "articles", ...args } } },
  });
  const toolResult = async (name, args) => {
    const response = await tool(name, args);
    assert.equal(response.status(), 200);
    const { result } = await response.json();
    assert.equal(result.isError, false);
    return JSON.parse(result.content[0].text);
  };
  assert.equal((await toolResult("count_records")).count, 19);
  const proposal = await toolResult("propose_change", { action: "update", id: "1", values: { title: "Proposed by MCP" } });
  assert.equal(proposal.status, "awaiting_human_confirmation");
  const review = new URL(proposal.review_url);
  assert.equal(review.origin, origin);
  await visit(review.pathname);
  await main.getByText("Hello → Proposed by MCP", { exact: true }).waitFor();
  await visit("/staff/articles/1");
  await heading("Hello").waitFor();
  await visit("/staff/mcp/tokens");
  await button("Revoke").click();
  await main.getByText("Token revoked.", { exact: true }).waitFor();
  assert.equal((await tool("count_records")).status(), 401);

  console.log("Read-only and tenant boundaries");
  await button("Sign out").click();
  await signIn("Viewer");
  await visit("/staff/articles/1");
  await heading("Hello").waitFor();
  assert.equal(await main.getByRole("link", { name: "Edit", exact: true }).count(), 0);
  assert.equal(await link("Assistant").count(), 0);
  assert.equal(await link("Audit log").count(), 0);
  await button("Sign out").click();
  await signIn("Other tenant");
  await visit("/staff/customers");
  await link("Other tenant customer").waitFor();
  assert.equal(await link("Ada Lovelace").count(), 0);
  return shots;
}

async function run() {
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "light" });
    const page = await context.newPage();
    page.setDefaultTimeout(12_000);
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const shots = await tour(page);
    assert.deepEqual(errors, [], "Unexpected browser errors");
    await mkdir(output, { recursive: true });
    for (const [name, png] of shots) await writeFile(join(output, `${name}.png`), png);
    console.log(`Saved ${shots.size} screenshots to ${output}`);
  } finally {
    await browser.close();
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
