# Product brief: ZMRIG

## Product
ZMRIG is an open-source, self-hostable mining toolchain: a native miner, a safe installer and live OS image, optional rig fleet control, pool/proxy components, and documentation. The product is for people who want transparent behavior and control over where mining runs—not a hosted mining service.

## People and primary jobs

1. **First-time individual miner:** choose a coin/pool, verify a public payout address, install safely, understand what changes and what the fee does.
2. **Experienced miner / system administrator:** select engine, threads, huge pages, network and thermal profile; inspect measurements and logs; reproduce a build.
3. **Rig/farm operator:** enroll machines, see honest online/stale/offline state, compare rigs by wallet, queue authorized configuration and recover from failure.
4. **Appliance operator:** boot v2/v3 media, provision via USB JSON/Wi-Fi, update safely, check status without touching disks.
5. **Pool/proxy developer:** run the components locally, validate shares and payouts, inspect protocols and test without requiring Docker.
6. **Contributor:** understand architecture, run tests and make a reproducible change.

## Product promises

- Installation and first successful run are the clearest paths through the website.
- Maximum throughput is the default where safe; thermal protections remain enabled. `watt`/eco settings are explicit tradeoffs.
- No made-up hashrate, earnings, live status, uptime, or customer proof. Show source, timestamp, assumptions and failure/stale state for dynamic data.
- Developer fee is disclosed before install, configurable, default 3% where applicable, never above 10%, and switchable off where implemented. Do not imply the C++ engine has a fee when it does not.
- No operator control is silently applied. Validate, authorize, queue, acknowledge, and audit rig commands.
- The optional fleet REST API has a versioned OpenAPI contract, explicit bearer-token authentication, bounded inputs and queues, and omits rig credentials from responses.
- No mandatory account or telemetry for local mining. Fleet data belongs to its operator.
- Attribute `@nggkhaiz`; keep English and Vietnamese experiences materially equivalent.
- Pool infrastructure in this repository is for self-hosted development/testing, not a promise of hosted mining.

## Boundaries

The docs website is static. The fleet service is an operator-controlled API/dashboard. Mining remains on user-owned rigs. Browser code must never call a sandbox/local loopback address. Deployment changes must preserve a no-secret local development path and must not pretend Cloudflare free quotas are unlimited.

## Success criteria

- A new user can identify their install route (host, USB appliance, or fleet) immediately and reach clear, safe instructions.
- Main routes and controls work at 375, 768, 1024 and 1440px with keyboard and reduced motion.
- EN and VI have the same navigation, important warnings, installation steps, and fee disclosure.
- API boundaries reject malformed/oversized requests without crashing or growing unbounded memory/state.
- Performance claims are supported by measurements; tests cover failure cases and regressions.
