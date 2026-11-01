# Setup: what still has to be done by hand

Everything in this repository works from a terminal. A handful of things do not:
they live in GitHub settings, in cloud dashboards that need an account of your
own, or they need a token scope this development environment does not have.
This page lists them, in the order worth doing, with the exact values to paste.

Each section says **why** it cannot be automated from here, and **how to check**
that it worked. If a step is already done, the check prints the expected value
and you move on.

| # | Task | Time | Needs |
|---|---|---|---|
| 1 | Branch layout (`ALPHA`/`BETA`/`master`) | 2 min | nothing — already done, verify only |
| 2 | Repository description, topics, homepage | 2 min | GitHub **Settings** access |
| 3 | CI for the site (`site.yml`) | 5 min | GitHub **Actions** write (token scope `workflows`) |
| 4 | Publish the documentation site | 10 min | GitHub Pages, or Cloudflare/Vercel account |
| 5 | Deploy the pool | 15 min | a `monerod` you control + Render/Fly account |
| 5b | Mine a different coin | 10 min | that coin's wallet + a pool endpoint it publishes |
| 6 | Point one miner at it | 5 min | a Linux box with root |
| 7 | Optional: releases, custom domain, protection | 10 min | — |

---

## 1. Branch layout

Three branches, one direction of travel:

```
ALPHA  ──►  BETA  ──►  master
newest      default,    upstream base,
work        release     stable tags
```

| Branch | Role | Who uses it | Rule |
|---|---|---|---|
| `ALPHA` | next-release work, may break | anyone who wants the newest thing | never the default; features arrive here first |
| `BETA` | **default branch**, the release state | everyone: the one-liner installs from here, the site links here | only fast-forwards; what a release tag is cut from |
| `master` | upstream `6.26.0-mo5` plus merge commits | nobody installs from it | receives `BETA` by PR; history is the audit trail of what shipped when |

Practically:

* `BETA` is the default branch, so `curl …/raw.githubusercontent.com/NggKhaiz/ZMRIG/BETA/oneclick.sh`
  and a plain `git clone` both give the stable tree. Nothing in the repository
  hard-codes any other branch name — `oneclick.sh` defaults to `BETA` and honours
  `MINER_BRANCH` for everything else.
* Trying `ALPHA` is one flag, no reinstall:

  ```bash
  MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install --wallet 4YourAddress...
  # back to stable
  sudo ./oneclick.sh update
  ```

* A release is `BETA` → `master`, then a tag:

  ```bash
  gh pr create --base master --head BETA --title "Release 6.26.0-mo9"
  gh pr merge --merge
  git tag -a v6.26.0-mo9 -m "6.26.0-mo9" && git push origin v6.26.0-mo9
  ```

Check the invariants at any time:

```bash
gh api repos/NggKhaiz/ZMRIG --jq .default_branch        # BETA
git ls-remote --heads origin                            # ALPHA, BETA, master
git diff --stat origin/BETA origin/master               # empty after a release
grep -rn "arena/" --include='*.md' --include='*.sh' --include='*.js' --include='*.html' . \
  | grep -v node_modules                                # must be empty (no session branch names)
```

That last line is not a suggestion: `web/tests/branches.test.js` fails the build
if a session branch name (or any branch other than `ALPHA`/`BETA`/`master`)
reappears in an install command, a link or a script default. The installer used
to point at a short-lived branch, and the failure mode was silent — `update`
fetched nothing, checked out nothing and still printed a commit hash.

## 2. Repository settings

Nothing in the tree can change these, and the API call needs *Administration*
permission (this session's token gets `403`). Paste them in **Settings → General**:

* **Description**
  `Monero (RandomX) miner with a 1% developer fee you can see and switch off, a Zig frontend, one-click install, and a self-hosted pool.`
  The current description is upstream's algorithm list and does not match what
  this repository is.
* **Topics**
  `monero` `randomx` `miner` `xmrig` `stratum` `zig` `cpu-mining`
* **Website**
  `https://nggkhaiz.github.io/ZMRIG/` — already set, and correct once step 4 is
  done. Change it if you use a custom domain.

The **Sponsor** button needs no setting: `.github/FUNDING.yml` points it at the
donation section of the README. It renders once the file exists on the default
branch (`BETA`), which it now does.

Check: open the repository page — a Sponsor button, the new description and the
topics are visible.

---

## 3. CI: the installer job (add it by hand, 15 lines)

The installer tests are ready and run locally with `npm run test:oneclick`
(41 checks, about ten seconds, no build needed). They are **not** in
`.github/workflows/test.yml` yet: adding a job means editing a file under
`.github/workflows/`, which needs the `workflows` token scope, and this
environment cannot push that (the same reason the site job below is manual).
The push is rejected with *"refusing to allow a GitHub App to create or update
workflow"*.

Add this job to `.github/workflows/test.yml` yourself:

```yaml
  installer:
    name: Installer tests (zero-flag rules, purge, governor)
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v5
      - name: Shell syntax
        run: |
          bash -n oneclick.sh
          bash -n scripts/tune-linux.sh
          for f in tests/oneclick/*.sh; do bash -n "$f"; done
      - name: Zero-flag decisions, config, governor, purge
        run: |
          sudo bash tests/oneclick/plan.sh
          sudo bash tests/oneclick/config.sh
          sudo bash tests/oneclick/governor.sh
          sudo bash tests/oneclick/purge.sh
```

It needs no secrets and no setup: a stock `ubuntu-24.04` runner has the
passwordless sudo the tests expect. Worth the 15 lines — a shell bug in the
installer is cheap to catch here and expensive to ship, because it only shows up
on a user's machine.

## 3b. CI: the docs-site job (still manual)

`site.yml` exists and runs the previous site's tests (`npm run test:web`). It does
not run the Docusaurus suite, and adding a job means editing a file under
`.github/workflows/`, which needs the `workflows` token scope — this environment
does not have it, so the push is rejected. Everything else is ready; the job is
twenty lines of YAML.

Add this job to **`.github/workflows/site.yml`** next to the existing one:

```yaml
  docs:
    name: Documentation site
    runs-on: ubuntu-24.04
    timeout-minutes: 20

    steps:
      - name: Checkout code
        uses: actions/checkout@v5

      - name: Set up Node
        uses: actions/setup-node@v5
        with:
          node-version: '22'

      # site/package-lock.json is not committed, so this is install, not ci.
      - name: Install
        run: cd site && npm install --no-audit --no-fund

      - name: Unit tests (builder, calculator, pools, i18n)
        run: cd site && npm test

      - name: Build both locales
        run: cd site && npm run build

      - name: The committed site is current
        run: ./scripts/publish-site.sh --check

      - name: Published tree
        run: bash tests/docs/pages.sh && bash tests/docs/links.sh
```

What it proves: the command builder assembles the flags it promises, the
calculator's arithmetic matches hand-computed numbers, the pool table agrees with
`oneclick.sh` and `doc/POOLS.md`, every English page has a Vietnamese
counterpart, both locales build with no broken link, and the copy committed at the
repository root is the one that was just built — so a content change cannot ship
without being published.

`publish-site.sh --check` runs `npm run build` again inside itself; on a cold
runner that is the slowest step, and it can be dropped if the two builds ever
disagree.

The donation guard it used to run still matters: every published copy of the
address must equal the wallet `pool/src/operator.js` decodes to. That check lives
in `web/tests/donate.test.js` and stays in the existing job.

### Optional: the release workflow

`.github/workflows/deploy.yml` triggers on tags `v*`, builds Windows/Linux/macOS
artifacts and publishes a GitHub release. Its last two steps push into
`MoneroOcean/xmrig_setup` and `MoneroOcean/hiveos` using the secret
`xmrig_setup_key`. **Leave that secret unset**: the steps detect it is missing,
print `xmrig_setup_key is not configured; skipping`, and the release is still
created. Only set it if you really do own those upstream repositories.

Do not delete the workflow — Windows/macOS artifacts are the only way most users
get a prebuilt binary.

---

## 4. Publish the documentation site

The site is Docusaurus, in `site/`. Two locales, 21 pages each, and three
calculators that run entirely in the browser. `doc/DOCS-SITE.md` describes the
project; this section is only about publishing it.

```bash
cd site && npm install && npm run build     # writes site/build
cd .. && ./scripts/publish-site.sh          # copies it into the repository root
```

`publish-site.sh` replaces only the paths Docusaurus owns (`index.html`,
`404.html`, `search.html`, `search-index.json`, `sitemap.xml`, `assets/`,
`docs/`, `vi/`, `img/`) and never deletes `web/`. `--check` fails when the
committed copy is older than `site/build`, which is what CI runs.

### 4a. GitHub Pages (the live site)

Two deployments point at the same URL, and whichever finishes last decides what
a visitor sees:

| Deployment | Reads | Why it exists |
| --- | --- | --- |
| `Deploy site` (`.github/workflows/pages.yml`) | the `web/` directory, uploaded as the Pages artifact | this is the intended path |
| `pages build and deployment` | the branch root | because **Settings → Pages → Source** is still *Deploy from a branch* |

Neither can be changed from here: the workflow file needs the `workflows`
permission, and the Pages setting needs repository administration. So
`scripts/publish-site.sh` writes the same build to both places and
`./scripts/publish-site.sh --check` (plus `tests/docs/pages.sh`) fails the
moment they disagree. A visitor gets the documentation site either way.

To simplify later — one setting, no code change:

1. **Settings → Pages → Build and deployment → Source: GitHub Actions**.
2. Then a publish only has to write `web/`: delete the root copy from
   `scripts/publish-site.sh` and the `OWNED_FILES` / `OWNED_DIRS` loops become
   unnecessary.

What the script does now:

```bash
./scripts/publish-site.sh            # build in site/, copy to web/ and the root
./scripts/publish-site.sh --check    # fail if either copy is stale
```

`web/` is replaced whole, so an asset from a previous build cannot survive and
serve a stale page. In the repository root only the paths Docusaurus owns are
replaced — `index.html`, `404.html`, `search.html`, `search-index.json`,
`sitemap.xml`, `robots.txt`, `assets/`, `docs/`, `vi/`, `img/` — so nothing a
human wrote there can be lost, and `legacy/`, `doc/`, `site/` and the source
trees are never touched.

`.nojekyll` is written by the script (Docusaurus only emits it when it deploys
with `gh-pages` itself) and stops Jekyll from eating `assets/`, whose files start
with `_`. `404.html` is generated with the site's own navigation, so a wrong URL
is a useful page rather than a dead end.

| URL | What |
| --- | --- |
| `https://nggkhaiz.github.io/ZMRIG/` | home page (English) |
| `https://nggkhaiz.github.io/ZMRIG/docs/intro` | documentation |
| `https://nggkhaiz.github.io/ZMRIG/vi/docs/intro` | the same page in Vietnamese |
| `https://nggkhaiz.github.io/ZMRIG/docs/install/builder` | command builder |
| `https://nggkhaiz.github.io/ZMRIG/docs/economics/profitability` | profitability calculator |
| `https://nggkhaiz.github.io/ZMRIG/wizard.html` | redirect into the builder, for links from the previous site |
| `https://nggkhaiz.github.io/ZMRIG/docs.html` | redirect into the documentation, same reason |

Verify after a publish:

```bash
./scripts/publish-site.sh --check                                 # both copies current
bash tests/docs/pages.sh                                          # 21 checks
curl -sI https://nggkhaiz.github.io/ZMRIG/docs/intro | head -1     # 200
curl -s  https://nggkhaiz.github.io/ZMRIG/robots.txt | tail -1     # Sitemap: …
```

### 4b. Cloudflare Pages

Same build, different host, and real response headers:

| Field | Value |
| --- | --- |
| Root directory | `site` |
| Framework preset | Docusaurus |
| Build command | `npm ci && npm run build` |
| Build output directory | `build` |

Set `ALGOLIA_APP_ID`, `ALGOLIA_API_KEY` and `ALGOLIA_INDEX_NAME` as environment
variables if DocSearch is approved. On a custom domain, change `url` in
`site/docusaurus.config.js` first — `baseUrl` stays `/` only for a root domain.

### 4c. Vercel

Root directory `site`, framework *Docusaurus*, build `npm run build`, output
`build`. Or from a terminal:

```bash
cd site && npx vercel deploy --prod
```

### After choosing a domain

`site/docusaurus.config.js` holds `url` and `baseUrl`, and every canonical link,
sitemap entry and `og:url` is derived from them. Change those two values, then:

```bash
cd site && npm run build && cd ..
./scripts/publish-site.sh
sed -i "s#https://nggkhaiz.github.io/ZMRIG#https://your.domain#g" robots.txt
bash tests/docs/pages.sh
```

`tests/docs/pages.sh` derives its expectations from `baseUrl`, so a forgotten
path fails there rather than in a browser.

---

## 5. Deploy the pool

The pool needs what a VPS is good at: a long-lived TCP socket and a Monero node.
It does **not** need a domain of its own if you use WebSocket mode.

**Before anything else you need `DAEMON`** — the URL of a `monerod` you control
(`http://127.0.0.1:18081` on the same box, or an `https://` node elsewhere). A
public node will rate-limit a pool into uselessness. `monerod` wants ~100 GB of
disk; that is the one real cost of running a pool.

### 5a. Render (free tier, WebSocket only)

`render.yaml` in the repository root is a blueprint: *New → Blueprint → point at
this repository*. Then in the service's **Environment** tab set the one value
marked `sync: false`:

```
DAEMON = https://your-node.example:18081
```

Leave `OPERATOR_ADDRESS` empty to use the wallet in `pool/src/operator.js`, or
set your own (the fee goes to whoever is listed at `/api/config`). `POOL_FEE_PERCENT=1`
is already in the blueprint.

Miners then connect with:

```bash
zmrig -o wss://<service>.onrender.com/stratum -u 4YourAddress.rig1 -t 2
```

Free instances sleep after 15 minutes without traffic, and a sleeping pool earns
nothing and loses its in-memory ledger. Fine for a test; use the paid instance or
Fly for real miners.

Check: `curl -s https://<service>.onrender.com/healthz` → `{"ok":true,…}`.

### 5b. Fly.io (raw TCP stratum, persistent ledger)

```bash
fly launch --no-deploy --dockerfile deploy/Dockerfile --copy-config
fly volumes create pool_data --size 1
fly secrets set DAEMON=https://your-node.example:18081
fly deploy
curl -s https://<app>.fly.dev/healthz
```

`fly.toml` maps `3333/tcp` (stratum), `8080/tcp` (HTTP + WS) and mounts the
volume at `/data`, which is where `STATE_FILE` and `AUDIT_FILE` live. Without the
volume the PPLNS ledger is lost on every restart.

### 5c. Cloudflare Worker bridge (only if your miners cannot reach the pool)

A stateless WebSocket ⇄ TCP bridge, free Workers plan:

```bash
cd pool/worker
npx wrangler deploy --var POOL_HOST:pool.example.com --var POOL_PORT:3333
# or edit [vars] in wrangler.toml and run: npx wrangler deploy
```

Miners then use `wss://zmrig-pool-bridge.<account>.workers.dev/stratum`. The
Worker cannot reach a private address, so `POOL_HOST` must be publicly routable.

### 5d. Never commit pool money data

`pool/data/` (ledger + `audit.jsonl`) is gitignored on purpose. Keep it that way:
a ledger in git is a payout history in public, and a bad merge is a wrong payout.

---

## 5b. Mine a different coin

Seven coins, one installer. Both engines implement the whole RandomX family plus
Panthera, which is the honest limit: a coin outside this table has no algorithm
in this repository, and no configuration makes it mine one.

| Coin | `--coin` | Algorithm | Notes |
| --- | --- | --- | --- |
| Monero | `xmr` | `rx/0` | the default, and the only coin with pool presets |
| Wownero | `wow` | `rx/wow` | Monero fork, much smaller network |
| ArQmA | `arq` | `rx/arq` | RandomARQ; a switching pool may send work here |
| Graft | `graft` | `rx/graft` | RandomGRAFT |
| Safex Cash | `sfx` | `rx/sfx` | RandomSFX |
| YadaCoin | `yada` | `rx/yada` | RandomYada |
| Scala | `xla` | `panthera` | not RandomX, still CPU work |

Nothing needs installing for this: the same binary hashes all seven. What you
supply by hand is the wallet and the pool endpoint, because neither can be
guessed:

1. **A wallet address for that coin.** Copy it from the coin's own wallet, not
   from a screenshot. `oneclick.sh` checks the shape — the base58 alphabet and a
   plausible length, plus a prefix warning where this repository knows one — and
   the pool verifies the checksum. A wrong address mines for somebody else, and
   nothing on a screen can prove an address is yours.
2. **The pool endpoint.** The seven presets in the builder are Monero pools;
   the smaller coins' endpoints and fees change too often to ship. Take
   `host:port` from the coin's own community page or pinned message. `--coin wow`
   with no `--pool` is an error, not a guess, and that is deliberate.
3. **TLS or 443, if that is your network.** If the pool publishes a TLS port, add
   `--tls`. If the machine can only reach 443, `--cloudflare=host:port` gives
   WebSocket over TLS on the Zig engine.

Plan first — it prints the coin, the algorithm, the engine and why:

```bash
sudo ./oneclick.sh plan --wallet YOUR_ADDRESS --coin wow --pool pool.example.org:3333
```

```text
engine         zmrig  (RandomX family, 1% dev fee)
pool           pool.example.org:3333
algo           rx/wow
coin           Wownero
```

Then install by replacing `plan` with `install` and adding `--yes`. The engine
follows the algorithm: `rx/*` and `panthera` are the Zig engine's territory
(1 % of Monero time, `--donate-level=0` to remove it), and `--engine xmrig` is
for debugging rather than for speed.

Verify it the same way as Monero:

```bash
sudo ./oneclick.sh status                 # service, hashrate, accepted shares
sudo ./oneclick.sh verify                 # self-test + developer-fee audit
sudo ./oneclick.sh report --power 95      # ZMRIG1. code for the calculator
```

A name that is not in the table is refused with the list, and an algorithm name
that could break `config.json` is refused before anything is written — both are
checked in `tests/oneclick/plan.sh`.

### What the site does with these coins

The builder and the wizard offer the same seven coins, and the calculator ranks
them. The ranking is arithmetic, not an opinion:

```text
share       = rig H/s ÷ network H/s
blocks/day  = 86400 ÷ block time
coin/day    = share × blocks/day × block reward
$/day       = coin/day × price
```

The numbers that go in are yours: block reward, block time and network hashrate
from the coin's explorer. Prices come from CoinGecko only when you press the
button, so the page works offline and no request leaves the browser before you
ask for one. Only Monero ships defaults (120 s, 0.6 XMR, 4.5 GH/s, $300); every
other coin starts blank, and a blank row says which field is missing instead of
showing a zero that would look like an answer.

Two things the table cannot see, and both are real money on one machine: pool
luck on a small network (a rig holding 0.1 % of it waits days for a payout), and
whether an exchange will buy the coin you mined.

### Keeping it current

There is no cron job and no build-time fetch to keep alive. Prices are pulled on
demand; everything else you paste. Re-check the figures when the answer surprises
you — a coin that leads by ten times is usually a stale network hashrate, not a
tenfold opportunity.

To add a coin to the site later, one file holds the list and the wording:
`site/src/lib/coins.mjs`, plus a page under `site/docs/pools/` and its
Vietnamese mirror. `site/tests/coins.test.mjs` fails if a coin claims an
algorithm no engine hashes, if a non-Monero coin ships a pool preset or a default
price, or if a missing number is silently treated as zero.

---

## 6. Put one miner on it

On the box that mines, as a user with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- install --wallet 4YourMoneroAddress... --engine zmrig
```

Then:

```bash
sudo ./oneclick.sh status      # service, hashrate, accepted shares
sudo ./oneclick.sh verify      # self-test + fee audit (1% of Monero time, switchable off)
sudo ./oneclick.sh report --power 95   # ZMRIG1. code for the fleet calculator
```

Restrictive egress (only 443 out) needs one extra flag:

```bash
sudo ./oneclick.sh config --wallet 4YourMoneroAddress... \
  --pool wss://pool.example.com/stratum --cloudflare --force
sudo ./oneclick.sh restart
```

Check the first share lands: `sudo ./oneclick.sh logs | grep -m1 accepted`.

Mining something other than Monero — Wownero, ArQmA, Graft, Safex Cash, YadaCoin,
Scala — is §5b: the same installer with `--coin` and the pool endpoint that coin's
community publishes.

---

## 7. Optional, once it works

* **Branch protection** on `BETA`: require the *Site tests* and build checks
  before merge. Settings → Branches → Add rule. Keep it off `master`, the PR
  flow already covers it.
* **Custom domain**: Cloudflare Pages → Custom domains, then run the `sed`
  command in §4 to update the sitemap.
* **A tag** for a real release: `git tag v6.26.0-mo9 && git push origin v6.26.0-mo9`
  runs `deploy.yml` and publishes prebuilt binaries.
* **Delete merged PR branches.** Session and feature branches are temporary; the
  three branches in §1 are the only ones that stay. Turn on *Settings → General
  → Pull Requests → Automatically delete head branches* and GitHub removes them
  for you, which also keeps the branch list free of names that a script could
  accidentally start pointing at.

  ```bash
  git ls-remote --heads origin        # expect exactly ALPHA, BETA, master
  git push origin --delete <stale-branch>
  ```

---

## What this environment cannot do, and why

| Blocked | Reason | Workaround |
|---|---|---|
| Editing `.github/workflows/*` | the token has no `workflows` scope; pushes are rejected | paste the two YAML files above in the web editor (§3, §4a) |
| Repository description, topics, Pages, branch protection | API returns `403` for repository administration | Settings UI (§2, §4) |
| DNS, custom domains | no access to your registrar or Cloudflare account | §4, §7 |
| Render / Fly / Vercel deploys | need your account and billing | §5 |
| Publishing a prebuilt binary | would need the release workflow, which is workflow-scope | tag from your own machine (§7) |
| `raw.githubusercontent.com` smoke test | unreachable from the sandbox | run the one-liner yourself (§6) |
| MSR / 1 GiB page measurements | the sandbox has no MSR access and cannot reserve a 1 GiB page | measured on bare metal by whoever has one; docs say so instead of guessing |

Everything else — the miner, the pool, the installer, the tests, the docs, the
site — is in the tree and runs locally:

```bash
./zmrig/tests/run.sh && ./zmrig/tests/unit.sh && ./zmrig/tests/cli.sh
./zmrig/tests/net.sh --quick
npm run test:web && npm run test:pool
./scripts/verify-fee.sh --source-only
./scripts/verify-fee-free.sh --source-only
python3 -m http.server -d web 8080
```
