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
| `tests/releases/version-consistency.test.sh` | four files carry the release number — `zmrig/src/main.zig`, `package.json`, `os/overlay/usr/local/bin/zmrig-os` and the fleet's fallback constant — and all four equal it, and `CHANGELOG.md` has a section for it. Two of them drifted in consecutive releases and the fourth was wrong for four; this is cheaper than reading the log again |
| `verify-fee.sh` | the Zig engine's fee is the documented 3 % of Monero time: one address, `--check` prints rate/address/cadence, `--donate-level=0` and `--no-donate` print `off`, `--donate-level=11` is rejected, no upstream donation endpoint in the binary |
| `verify-fee-free.sh` | the C++ engine still has no donation strategy, no developer wallet, and prints `DONATE 0%` even with `--donate-level=9` |
| `miner-integration` | the built binary talks stratum, accepts a job and submits a share for all 34 CPU algorithms (`tests/common/miner_harness.js` runs a fake pool) |
| `zmrig/tests/switch.sh` | an algorithm switch back reuses the mapped dataset *and* a share submitted after it recomputes to the same digest; the same test with `--no-dataset-cache` proves the off switch is real |
| `zmrig/tests/targets.sh` | the target comparison submits exactly `hashes / difficulty` shares at difficulty 1 000 (26 of 26 884 hashes, measured) and nothing at 1 000 000, with no duplicate nonces, no unknown jobs and no rejections — and the shares themselves are recomputed and checked against the 256-bit rule a pool applies, which is what proves the miner is comparing the right eight bytes |
| `zmrig/tests/duty.sh` | a pool that drops the socket every 5 s costs no hashing time (6–7 reconnects, 0 s lost) and a pool that never answers is reported as time without a job — the two directions of the ability to say how much of the run was hashing |

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
