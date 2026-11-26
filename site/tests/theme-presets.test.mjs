import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const presets = JSON.parse(readFileSync(path.join(root, "src/theme/theme-presets.json"), "utf8"));
const css = readFileSync(path.join(root, "src/css/custom.css"), "utf8");
const toggle = readFileSync(path.join(root, "src/theme/ColorModeToggle/index.js"), "utf8");
const config = readFileSync(path.join(root, "docusaurus.config.js"), "utf8");

test("theme presets are named, bilingual, unique and use supported color modes", () => {
  const ids = presets.themes.map(({ id }) => id);
  assert.equal(new Set(ids).size, ids.length);
  assert.ok(ids.includes("forest"));
  assert.ok(ids.includes("catppuccin-mocha"));
  assert.ok(ids.includes("nord"));
  assert.ok(ids.includes("dracula"));
  assert.ok(ids.includes("tokyo-night"));
  assert.equal(presets.default, "forest");
  for (const preset of presets.themes) {
    assert.match(preset.mode, /^(dark|light|system)$/);
    assert.ok(preset.label.en, `${preset.id} needs an English label`);
    assert.ok(preset.label.vi, `${preset.id} needs a Vietnamese label`);
    if (preset.palette) assert.match(css, new RegExp(`data-palette=[\\\"']${preset.id}[\\\"']`));
  }
});

function token(block, name) {
  const match = new RegExp(`--${name}:\\s*(#[0-9a-fA-F]{6})`).exec(block);
  assert.ok(match, `missing --${name}`);
  return match[1];
}

function contrast(a, b) {
  const luminance = (hex) => {
    const values = hex.slice(1).match(/../g).map((part) => parseInt(part, 16) / 255);
    const [r, g, blue] = values.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * r + 0.7152 * g + 0.0722 * blue;
  };
  const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

test("every named palette keeps text and primary controls at WCAG AA contrast", () => {
  for (const preset of presets.themes.filter((item) => item.palette)) {
    const blocks = [...css.matchAll(new RegExp(`html\\[data-palette="${preset.id}"\\]\\s*\\{([^}]+)\\}`, "g"))].map((match) => match[1]);
    const block = blocks.find((candidate) => candidate.includes("--zm-paper: #"));
    assert.ok(block, `${preset.id} needs its own token block`);
    const paper = token(block, "zm-paper");
    const ink = token(block, "zm-ink");
    const muted = token(block, "zm-ink-muted");
    const accent = token(block, "zm-accent");
    const onAccent = token(block, "zm-on-accent");
    assert.ok(contrast(ink, paper) >= 7, `${preset.id}: primary text contrast`);
    assert.ok(contrast(muted, paper) >= 4.5, `${preset.id}: secondary text contrast`);
    assert.ok(contrast(accent, paper) >= 4.5, `${preset.id}: links and controls contrast`);
    assert.ok(contrast(onAccent, accent) >= 4.5, `${preset.id}: primary button label contrast`);
  }
});

test("palette selection is a native, keyboard-accessible control and persists with system reset", () => {
  assert.match(toggle, /<select/);
  assert.match(toggle, /aria-label=/);
  assert.match(toggle, /localStorage/);
  assert.match(toggle, /setColorMode\(.*mode/s);
  assert.match(toggle, /data-palette/);
});

test("the palette is applied before first paint and is covered by page theme metadata", () => {
  assert.match(config, /theme-presets\.json/);
  assert.match(config, /innerHTML:/);
  assert.equal(presets.storageKey, "zmrig-palette");
  assert.match(config, /respectPrefersColorScheme:\s*true/);
  assert.match(css, /html\[data-palette=/);
  assert.match(css, /color-scheme:\s*dark/);
});
