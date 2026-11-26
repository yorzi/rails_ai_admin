// Run on the disposable, freshly seeded offline demo. This tour approves one award and imports 125 articles.
const assert = require("node:assert/strict");
const { resolve } = require("node:path");
const { chromium } = require("../../tmp/demo-browser/node_modules/playwright");

async function run() {
  const port = Number(process.argv[2] || 3917);
  assert(Number.isInteger(port) && port >= 1024 && port <= 65534);
  const base = `http://127.0.0.1:${port}`;
  const demo = port === 3917 ? "demo" : `demo-${port}`;
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(15000);
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const visit = async path => assert((await page.goto(base + path)).ok(), path);
    const button = name => page.getByRole("button", { name, exact: true });
    const heading = name => page.getByRole("heading", { name, exact: true });
    const signIn = async role => {
      await visit("/login");
      await button("Sign in as " + role).click();
      await heading("Overview").waitFor();
    };

    await signIn("Admin");
    const report = page.locator("section").filter({ has: heading("Orders by review state") });
    assert.equal(await report.locator(".raa-metric-value").innerText(), "45");
    assert.equal(await report.locator("tbody tr").count(), 3);

    await visit("/staff/tasks");
    await page.getByRole("link", { name: "Recipes", exact: true }).click();
    await heading("First customer award").waitFor();
    await heading("Daily order brief").waitFor();
    await heading("Customer duplicate check").waitFor();
    await Promise.all([
      page.waitForResponse(response => response.url().endsWith("/tasks/recipes/library") && response.ok()),
      button("Run for review").click()
    ]);
    await signIn("Reviewer");
    await visit("/staff/tasks");
    const proposal = page.getByRole("row").filter({ hasText: "Recipe run" }).getByRole("link").first();
    await proposal.click();
    await heading("Review and approve").waitFor();
    await button("Approve and execute").click();
    await page.getByText("Succeeded", { exact: true }).first().waitFor();

    await signIn("Admin");
    await visit("/staff/articles/imports/new");
    await page.getByLabel("CSV file", { exact: true }).setInputFiles(resolve(__dirname, "../../tmp", demo, "articles-batch.csv"));
    await button("Review CSV import").click();
    await button("Confirm creation of 125 records").click();
    const refresh = page.getByRole("link", { name: "Refresh progress" });
    await refresh.waitFor();
    const done = page.getByText("Created 125 of 125 records.", { exact: true });
    const deadline = Date.now() + 30000;
    while (!(await done.count()) && Date.now() < deadline) {
      await page.waitForTimeout(300);
      await page.reload();
    }
    assert.equal(await done.count(), 1, "The background worker must finish the admitted batch");
    await signIn("Other tenant");
    assert.equal(await heading("Orders by review state").count(), 0);
    assert.deepEqual(errors, []);
    console.log("Passed shared dashboard, recipe approval, 125-row import and tenant isolation.");
  } finally {
    await browser.close();
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
