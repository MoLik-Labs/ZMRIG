// Two locales are a promise, and a missing translation file silently falls back
// to English — which looks like a bug to a Vietnamese reader and like success to
// a build. These tests walk the file trees instead of trusting the config.
//
// They also check the sidebar, because a doc that exists but is not reachable
// from the navigation is invisible in practice.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const SITE = path.resolve(import.meta.dirname, "..");
const EN = path.join(SITE, "docs");
const VI = path.join(SITE, "i18n", "vi", "docusaurus-plugin-content-docs", "current");

function walk(dir, base = dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, base, out);
    else if (/\.mdx?$/.test(entry.name)) out.push(path.relative(base, full));
  }
  return out.sort();
}

const enPages = walk(EN);
const viPages = walk(VI);

test("the site has the pages the documentation promises", () => {
  const expected = [
    "intro.md",
    "install/quickstart.md",
    "install/builder.mdx",
    "install/installer.md",
    "install/engines.md",
    "install/docker.md",
    "appliance/iso.md",
    "appliance/web.md",
    "configure/config-file.md",
    "configure/cli.md",
    "operate/monitoring.md",
    "operate/networks.md",
    "operate/performance.md",
    "operate/troubleshooting.md",
    "pools/choosing.mdx",
    "pools/coins.mdx",
    "economics/profitability.mdx",
    "economics/report-codes.md",
    "fleet/telegram.md",
    "fleet/dashboard.md",
    "fleet/proxy.md",
    "fleet/pool.md",
    "reference/benchmarks.md",
    "reference/fee.md",
    "development/architecture.md",
    "development/testing.md",
    "support.md",
  ];
  for (const page of expected) assert.ok(enPages.includes(page), `missing docs/${page}`);
  assert.equal(enPages.length, expected.length, `unexpected extra page: ${enPages}`);
});

test("every English page has a Vietnamese counterpart", () => {
  const missing = enPages.filter((page) => !viPages.includes(page));
  assert.deepEqual(missing, [], `untranslated: ${missing.join(", ")}`);
  const orphan = viPages.filter((page) => !enPages.includes(page));
  assert.deepEqual(orphan, [], `orphan translations: ${orphan.join(", ")}`);
});

test("a translation keeps its front matter, and a different title", () => {
  for (const page of enPages) {
    const en = fs.readFileSync(path.join(EN, page), "utf8");
    const vi = fs.readFileSync(path.join(VI, page), "utf8");
    assert.match(en, /^---\n/, `${page} has no front matter`);
    assert.match(vi, /^---\n/, `${page} (vi) has no front matter`);
    const enTitle = /title:\s*(.+)/.exec(en)?.[1] ?? "";
    const viTitle = /title:\s*(.+)/.exec(vi)?.[1] ?? "";
    assert.ok(viTitle, `${page} (vi) has no title`);
    assert.notEqual(viTitle, enTitle, `${page} (vi) keeps the English title`);
    // Same slug or none at all, so the two locales cannot drift apart.
    const slug = (text) => /slug:\s*(\S+)/.exec(text)?.[1] ?? "";
    assert.equal(slug(vi), slug(en), `${page} slug differs between locales`);
  }
});

test("translated pages import the same components", () => {
  const imports = (text) =>
    [...text.matchAll(/^import\s+.+from\s+"(@site\/[^"]+)";$/gm)]
      .map((match) => match[1])
      .sort();
  for (const page of enPages) {
    const en = fs.readFileSync(path.join(EN, page), "utf8");
    const vi = fs.readFileSync(path.join(VI, page), "utf8");
    assert.deepEqual(imports(vi), imports(en), `${page} component imports differ`);
  }
});

test("the sidebar lists only pages that exist", () => {
  const sidebar = fs.readFileSync(path.join(SITE, "sidebars.js"), "utf8");
  const ids = [...sidebar.matchAll(/"([a-z0-9/-]+)"/g)]
    .map((match) => match[1])
    .filter((id) => id !== "docs")
    // Only doc ids: every one is either a page at the root or a path under a
    // category directory. This also skips the config strings ("throw", "auto").
    .filter((id) => /^[a-z0-9-]+\/[a-z0-9-]+$/.test(id) || ["intro", "support"].includes(id));
  assert.ok(ids.length >= 21, `only ${ids.length} sidebar entries`);
  for (const id of ids) {
    const found = enPages.some((page) => page.replace(/\.mdx?$/, "") === id);
    assert.ok(found, `sidebar id "${id}" has no page`);
  }
});

test("theme strings are translated, not left in English", () => {
  const read = (...parts) =>
    JSON.parse(fs.readFileSync(path.join(SITE, "i18n", "vi", ...parts), "utf8"));

  const navbar = read("docusaurus-theme-classic", "navbar.json");
  assert.equal(navbar["item.label.Documentation"].message, "Tài liệu");
  assert.equal(navbar["item.label.Calculator"].message, "Máy tính");

  const footer = read("docusaurus-theme-classic", "footer.json");
  for (const [key, entry] of Object.entries(footer)) {
    assert.ok(entry.message && entry.description, `${key} is incomplete`);
  }
  assert.match(footer.copyright.message, /@nggkhaiz/);

  const code = read("code.json");
  const untranslated = ["theme.colorToggle.ariaLabel.mode.system", "theme.TOCCollapsible.toggleButtonLabel", "theme.CodeBlock.copy", "theme.SearchBar.label"];
  for (const key of untranslated) {
    assert.ok(code[key], `code.json is missing ${key}`);
    assert.notEqual(code[key].message, "", `${key} is empty`);
  }
});

test("the language switch and the theme switch are both configured", () => {
  const config = fs.readFileSync(path.join(SITE, "docusaurus.config.js"), "utf8");
  assert.match(config, /defaultLocale:\s*"en"/);
  assert.match(config, /locales:\s*\["en",\s*"vi"\]/);
  assert.match(config, /type:\s*"localeDropdown"/);
  assert.match(config, /colorMode:/);
  assert.match(config, /respectPrefersColorScheme:\s*true/);
  // The three-state toggle is the only thing that offers "system".
  const toggle = fs.readFileSync(
    path.join(SITE, "src", "theme", "ColorModeToggle", "index.js"),
    "utf8"
  );
  assert.match(toggle, /value:\s*null/);
  assert.match(toggle, /setColorMode\(option\.value\)/);
  assert.match(toggle, /Hệ thống/);
});
