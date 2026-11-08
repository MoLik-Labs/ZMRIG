// Sidebar for the documentation. Every doc is listed by id, so a page can
// never be published without a place in the navigation — `onBrokenLinks:
// "throw"` then catches a link to a page that was renamed or removed.
//
// The Vietnamese translation mirrors these ids exactly; Docusaurus resolves
// each id against the current locale and falls back to English if a page is
// missing, which is why `npm run check:i18n` in the repository compares the
// two file trees.

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    "intro",
    {
      type: "category",
      label: "Install",
      collapsible: true,
      collapsed: false,
      items: [
        "install/setup",
        "install/quickstart",
        "install/builder",
        "install/installer",
        "install/engines",
        "install/docker",
      ],
    },
    {
      type: "category",
      label: "Appliance",
      collapsible: true,
      items: ["appliance/iso", "appliance/web"],
    },
    {
      type: "category",
      label: "Configure",
      collapsible: true,
      items: ["configure/config-file", "configure/cli"],
    },
    {
      type: "category",
      label: "Run",
      collapsible: true,
      items: [
        "operate/monitoring",
        "operate/networks",
        "operate/performance",
        "operate/troubleshooting",
      ],
    },
    {
      type: "category",
      label: "Pools and money",
      collapsible: true,
      items: [
        "pools/choosing",
        "pools/coins",
        "economics/profitability",
        "economics/report-codes",
      ],
    },
    {
      type: "category",
      label: "A whole fleet",
      collapsible: true,
      items: ["fleet/telegram", "fleet/dashboard", "fleet/proxy", "fleet/pool"],
    },
    {
      type: "category",
      label: "Reference",
      collapsible: true,
      items: ["reference/benchmarks", "reference/tool", "reference/fee"],
    },
    {
      type: "category",
      label: "Development",
      collapsible: true,
      items: ["development/architecture", "development/testing"],
    },
    "support",
  ],
};

module.exports = sidebars;
