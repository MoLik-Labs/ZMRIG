// Task-first documentation navigation. Installation stays near the top; users
// who are running hardware reach operations and fleet guidance without paging
// through contributor reference material.
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
        "install/quickstart",
        "install/builder",
        "install/setup",
        "install/installer",
        "install/engines",
        "install/docker",
      ],
    },
    {
      type: "category",
      label: "Operate",
      collapsible: true,
      collapsed: false,
      items: [
        "operate/monitoring",
        "operate/performance",
        "operate/networks",
        "operate/troubleshooting",
        "configure/config-file",
        "configure/cli",
      ],
    },
    {
      type: "category",
      label: "Fleet",
      collapsible: true,
      items: [
        "appliance/iso",
        "appliance/web",
        "fleet/dashboard",
        "fleet/api",
        "fleet/telegram",
        "fleet/proxy",
        "fleet/pool",
      ],
    },
    {
      type: "category",
      label: "Pools and economics",
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
