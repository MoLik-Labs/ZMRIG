# CI

The repository ships `.github/workflows/test.yml` for Linux and macOS. The Linux
job builds the miner and runs the safe hash suite.

> Pasting the two job definitions below into `.github/workflows/` needs the
> `workflows` token scope, which a sandboxed token usually lacks. The
> step-by-step for doing it by hand in the web editor is in
> [`SETUP.md`](SETUP.md) §3 and §4a.

Two extra checks are worth adding; they are not in the workflow file because a
token needs the `workflows` scope to modify those files. Paste them into the
Linux job after `Run safe test subset`:

```yaml
      - name: Audit the developer fee
        run: |
          ./scripts/verify-fee.sh --binary zmrig/out/zmrig
          ./scripts/verify-fee-free.sh --binary build/xmrig

      - name: Run miner integration tests
        run: node run_tests.js --suite miner-integration --build-dir build
```

What they cover:

| Check | What it proves |
|---|---|
| `tests/oneclick/branch-switch.sh` | the installer's branch switching works in a `--depth 1` single-branch clone, and an unknown branch is a hard error instead of a silent no-op |
| `verify-fee.sh` | the Zig engine's fee is the documented 1 % of Monero time: one address, `--check` prints rate/address/cadence, `--donate-level=0` and `--no-donate` print `off`, `--donate-level=11` is rejected, no upstream donation endpoint in the binary |
| `verify-fee-free.sh` | the C++ engine still has no donation strategy, no developer wallet, and prints `DONATE 0%` even with `--donate-level=9` |
| `miner-integration` | the built binary talks stratum, accepts a job and submits a share for all 34 CPU algorithms (`tests/common/miner_harness.js` runs a fake pool) |

The documentation site and the donation guard run as their own job — small
enough to sit in front of the compilers:

```yaml
  site:
    name: Documentation site and donation guard
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v5
        with: { node-version: '22' }
      # package-lock.json is not committed, so `npm install`, not `npm ci`.
      - run: npm install --no-audit --no-fund --no-save jsdom
      - run: npm run test:web
```

| Check | What it proves |
|---|---|
| `test:web` | the command builder assembles the flags it promises, every docs page renders, raw HTML stays escaped, `javascript:` links are dropped, every copy of the donation address equals the wallet `pool/src/operator.js` decodes to, and every install URL points at `ALPHA`, `BETA` or `master` — never at a session branch |

For `zmrig`, the equivalent is the network suite (no CI privileges needed, it
starts its own pools and TLS shims):

```yaml
      - name: zmrig self test
        run: ./zmrig/out/zmrig --self-test

      - name: zmrig network suite
        run: ./zmrig/tests/net.sh --quick
```

Both run locally as well:

```bash
./scripts/verify-fee.sh --binary zmrig/out/zmrig
./scripts/verify-fee-free.sh --binary build/xmrig
node run_tests.js --suite miner-integration --build-dir build
node run_tests.js --safe --build-dir build
```
