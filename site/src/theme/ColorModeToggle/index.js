import React, { useEffect, useState } from "react";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import { useColorMode } from "@docusaurus/theme-common";
import PRESETS from "../theme-presets.json";

const presetById = new Map(PRESETS.themes.map((preset) => [preset.id, preset]));

function readChoice() {
  try {
    const saved = window.localStorage.getItem(PRESETS.storageKey);
    return presetById.has(saved) ? saved : PRESETS.default;
  } catch {
    return PRESETS.default;
  }
}

function applyChoice(id, setColorMode, persist = true) {
  const preset = presetById.get(id) || presetById.get(PRESETS.default);
  const root = document.documentElement;

  if (preset.palette) root.setAttribute("data-palette", preset.palette);
  else root.removeAttribute("data-palette");

  if (persist) {
    try {
      window.localStorage.setItem(PRESETS.storageKey, preset.id);
    } catch {
      // The selection still works for this page when storage is unavailable.
    }
  }

  setColorMode(preset.mode === "system" ? null : preset.mode);
  return preset.id;
}

export default function ColorModeToggle() {
  const { setColorMode } = useColorMode();
  const { i18n } = useDocusaurusContext();
  const vi = i18n.currentLocale === "vi";
  const [choice, setChoice] = useState(PRESETS.default);

  useEffect(() => {
    setChoice(readChoice());
  }, []);

  function handleChange(event) {
    setChoice(applyChoice(event.target.value, setColorMode));
  }

  return (
    <label className="zm-theme-picker navbar__item" data-theme-picker>
      <span className="sr-only">{vi ? "Chọn giao diện" : "Choose a theme"}</span>
      <select
        aria-label={vi ? "Giao diện màu" : "Colour theme"}
        value={choice}
        onChange={handleChange}
      >
        {PRESETS.themes.map((preset) => (
          <option key={preset.id} value={preset.id}>
            {preset.label[vi ? "vi" : "en"]}
          </option>
        ))}
      </select>
    </label>
  );
}
