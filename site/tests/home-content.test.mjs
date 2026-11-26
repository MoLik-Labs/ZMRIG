import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { HOME_COPY } from "../src/lib/home-content.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requiredLocales = ["en", "vi"];

function routeExists(route) {
  if (!route.startsWith("/docs/")) return false;
  const id = route.slice("/docs/".length);
  const base = path.join(root, "docs");
  return [".md", ".mdx"].some((ext) => existsSync(path.join(base, `${id}${ext}`)));
}

test("home copy has the same complete install and audience paths in both locales", () => {
  assert.deepEqual(Object.keys(HOME_COPY).sort(), requiredLocales);
  const en = HOME_COPY.en;
  const vi = HOME_COPY.vi;
  for (const key of ["title", "lede", "primary", "secondary", "directInstall", "quickTitle", "quickIntro", "paths", "trustTitle", "trustFacts", "feeLink"]) {
    assert.ok(en[key], `English home is missing ${key}`);
    assert.ok(vi[key], `Vietnamese home is missing ${key}`);
  }
  assert.equal(en.paths.length, 5);
  assert.equal(vi.paths.length, en.paths.length);
  assert.deepEqual(vi.paths.map((item) => item.id), en.paths.map((item) => item.id));
  assert.deepEqual(vi.trustFacts.map((item) => item.id), en.trustFacts.map((item) => item.id));
});

test("every homepage action points to a published docs page", () => {
  for (const [locale, copy] of Object.entries(HOME_COPY)) {
    for (const route of [copy.primary.to, copy.secondary.to, ...copy.paths.map((item) => item.to), "/docs/reference/fee"]) {
      assert.ok(routeExists(route), `${locale}: no docs page for ${route}`);
    }
  }
});

test("home assets respect Docusaurus baseUrl and sections are accessible", () => {
  const page = readFileSync(path.join(root, "src/pages/index.jsx"), "utf8");
  const css = readFileSync(path.join(root, "src/css/custom.css"), "utf8");
  assert.match(page, /useBaseUrl\("img\/logo\.svg"\)/);
  assert.match(page, /useBaseUrl\("img\/logo-dark\.svg"\)/);
  assert.doesNotMatch(page, /src="\/ZMRIG\//);
  assert.match(page, /aria-labelledby="home-title"/);
  assert.match(page, /aria-labelledby="routes-title"/);
  assert.match(page, /aria-labelledby="principles-title"/);
  assert.match(page, /oneclick\.sh/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(css, /:focus-visible/);
  assert.match(css, /@media \(max-width: 700px\)/);
});

test("home disclosures describe the real fee model without performance claims", () => {
  for (const locale of requiredLocales) {
    const copy = HOME_COPY[locale];
    const disclosure = copy.trustFacts.find((item) => item.id === "fee");
    assert.ok(disclosure, `${locale}: missing fee disclosure`);
    assert.match(disclosure.body, /3\s*%/);
    assert.match(disclosure.body, /10\s*%/);
    assert.doesNotMatch(copy.lede, /\b\d+\s*(?:H\/s|hash(?:rate)?|XMR\/day)\b/i);
  }
});
