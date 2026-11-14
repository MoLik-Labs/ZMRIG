import React, { useEffect, useMemo, useState } from "react";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import { useLocation } from "@docusaurus/router";
import { POOLS, feeLabel, minLabel } from "../lib/pools.mjs";
import { COINS, coinOrDefault, findCoin } from "../lib/coins.mjs";
import { build } from "../lib/command.mjs";
import { translate } from "../lib/messages.mjs";
import CopyButton from "./CopyButton";

const INITIAL = {
  coin: "xmr",
  wallet: "",
  rig: "",
  pool: "moneroocean",
  host: "",
  failover: [],
  engine: "auto",
  profile: "free",
  tls: false,
  cloudflare: false,
  wsPath: "/stratum",
  proxy: false,
  proxyUrl: "",
  connectTo: "",
  msr: false,
  nicehash: false,
  notune: false,
  autotuneOff: false,
  noHealthRestart: false,
  force: false,
  clone: false,
};

export default function InstallBuilder() {
  const { i18n } = useDocusaurusContext();
  const locale = i18n.currentLocale === "vi" ? "vi" : "en";
  const t = (key, params) => translate(locale, key, params);

  const [state, setState] = useState(INITIAL);
  const result = useMemo(() => build(state), [state]);

  // Links from elsewhere carry the pool as `?pool=c3pool` — the old wizard did
  // this, so the pool table can keep pointing at the builder. Only a known id is
  // accepted: the value is used as a key, never echoed into the command.
  // The coin is first: the calculator links here with `?coin=wow` after it says
  // which coin pays best, so the builder opens on the coin the advice was about.
  // `useLocation` rather than `window.location` because a link to this same page
  // with a different coin is a route change, not a reload — the effect has to run
  // again, or the page sits on the previous coin.
  const { search } = useLocation();
  useEffect(() => {
    const params = new URLSearchParams(search);
    const coin = params.get("coin");
    const pool = params.get("pool");
    setState((prev) => {
      const next = { ...prev };
      if (coin && findCoin(coin)) {
        next.coin = coin;
        next.pool = findCoin(coin).pools.length > 0 ? "moneroocean" : "custom";
      }
      if (pool && POOLS.some((item) => item.id === pool)) {
        next.pool = pool;
      }
      return next;
    });
  }, [search]);

  const set = (key) => (event) => {
    const target = event.target;
    const value = target.type === "checkbox" ? target.checked : target.value;
    setState((prev) => ({ ...prev, [key]: value }));
  };

  const toggleFailover = (id) => {
    setState((prev) => ({
      ...prev,
      failover: prev.failover.includes(id)
        ? prev.failover.filter((x) => x !== id)
        : [...prev.failover, id],
    }));
  };

  // Changing the coin resets what belonged to the old one: a Wownero address in a
  // Monero pool preset would produce a command that looks certain and is wrong.
  const setCoin = (event) => {
    const coin = coinOrDefault(event.target.value);
    setState((prev) => ({
      ...prev,
      coin: coin.id,
      pool: coin.pools.length > 0 ? prev.pool : "custom",
      host: coin.pools.length > 0 ? "" : prev.host,
      failover: coin.pools.length > 0 ? prev.failover : [],
    }));
  };

  const coin = coinOrDefault(state.coin);
  const walletMessage = t("builder.wallet." + result.wallet.status, {
    n: result.wallet.length,
    coin: coin.name,
    prefixes: (coin.address.prefixes || []).join(", "),
  });
  const hostMessage =
    result.host.status === "ok"
      ? t("builder.host.ok", { host: result.host.host, port: result.host.port })
      : t("builder.host." + result.host.status);

  const blockedMessage = result.blocked
    ? t("builder.blocked." + result.blocked, { coin: coin.name })
    : null;
  const selectedPool = POOLS.find((pool) => pool.id === state.pool);
  const isCustom = !selectedPool;

  return (
    <div className="zm-builder" id="zm-builder">
      <form className="zm-builder__form" onSubmit={(e) => e.preventDefault()}>
        <p className="zm-caption">{t("builder.intro")}</p>

        <fieldset className="zm-fieldset">
          <legend>{t("builder.coin")}</legend>
          <select className="zm-input" value={state.coin} onChange={setCoin}>
            {COINS.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name} ({item.symbol}) — {item.algo}
              </option>
            ))}
          </select>
          <p className="zm-hint">{coin.why[locale]}</p>
          <p className="zm-caption">{t("builder.coinHint")}</p>
        </fieldset>

        <fieldset className="zm-fieldset">
          <legend>{t("builder.wallet")}</legend>
          <input
            type="text"
            className="zm-input"
            value={state.wallet}
            onChange={set("wallet")}
            spellCheck="false"
            autoComplete="off"
            placeholder={(coin.address.prefixes || [])[0] || "…"}
            aria-describedby="zm-wallet-hint"
          />
          <p
            id="zm-wallet-hint"
            className={
              result.wallet.ok
                ? "zm-hint is-ok"
                : state.wallet
                  ? "zm-hint is-bad"
                  : "zm-hint"
            }
          >
            {walletMessage}
          </p>
          <input
            type="text"
            className="zm-input"
            value={state.rig}
            onChange={set("rig")}
            placeholder={t("builder.rig")}
            aria-label={t("builder.rig")}
            spellCheck="false"
            autoComplete="off"
          />
          <p className="zm-hint">{t("builder.rigHint")}</p>
        </fieldset>

        <fieldset className="zm-fieldset">
          <legend>{t("builder.pool")}</legend>
          {coin.pools.length > 0 ? (
            <select
              className="zm-input"
              value={state.pool}
              onChange={set("pool")}
            >
              {POOLS.map((pool) => (
                <option key={pool.id} value={pool.id}>
                  {pool.name} — {feeLabel(pool, locale)} ·{" "}
                  {minLabel(pool, locale)}
                </option>
              ))}
              <option value="custom">{t("builder.poolCustom")}</option>
            </select>
          ) : (
            <p className="zm-caption">
              {t("builder.coinNoPools", { coin: coin.name })}
            </p>
          )}

          {isCustom ? (
            <>
              <input
                type="text"
                className="zm-input"
                value={state.host}
                onChange={set("host")}
                placeholder="pool.example.com:3333"
                aria-label={t("builder.host")}
                spellCheck="false"
                autoComplete="off"
              />
              <p className={result.host.ok ? "zm-hint is-ok" : "zm-hint"}>
                {hostMessage}
              </p>
            </>
          ) : (
            <p className="zm-hint">
              {selectedPool.why[locale]} <code>{result.pool.endpoint}</code>
            </p>
          )}

          {coin.pools.length > 0 ? (
            <>
              <span className="zm-label">{t("builder.failover")}</span>
              <div className="zm-chips">
                {POOLS.filter((pool) => pool.id !== state.pool).map((pool) => (
                  <label
                    key={pool.id}
                    className={
                      state.failover.includes(pool.id)
                        ? "zm-chip is-active"
                        : "zm-chip"
                    }
                  >
                    <input
                      type="checkbox"
                      checked={state.failover.includes(pool.id)}
                      onChange={() => toggleFailover(pool.id)}
                    />
                    <span>{pool.name}</span>
                  </label>
                ))}
              </div>
              <p className="zm-hint">{t("builder.failoverHint")}</p>
            </>
          ) : null}

          <label className="zm-check">
            <input type="checkbox" checked={state.tls} onChange={set("tls")} />
            <span>{t("builder.tls")}</span>
          </label>
        </fieldset>

        <fieldset className="zm-fieldset">
          <legend>{t("builder.engine")}</legend>
          <select
            className="zm-input"
            value={state.engine}
            onChange={set("engine")}
          >
            <option value="auto">{t("builder.engineAuto")}</option>
            <option value="zmrig">{t("builder.engineZmrig")}</option>
            <option value="xmrig">{t("builder.engineXmrig")}</option>
          </select>
          <p className="zm-hint">{t("builder.engineAutoHint")}</p>

          <select
            className="zm-input"
            value={state.profile}
            onChange={set("profile")}
          >
            <option value="auto">
              {t("builder.profile")} — {t("builder.profileAuto")}
            </option>
            <option value="free">{t("builder.profileFree")}</option>
            <option value="watt">{t("builder.profileWatt")}</option>
          </select>

          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.autotuneOff}
              onChange={set("autotuneOff")}
            />
            <span>{t("builder.autotune")}</span>
          </label>
          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.nicehash}
              onChange={set("nicehash")}
            />
            <span>{t("builder.nicehash")}</span>
          </label>
        </fieldset>

        <fieldset className="zm-fieldset">
          <legend>{t("builder.network")}</legend>
          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.cloudflare}
              onChange={set("cloudflare")}
            />
            <span>{t("builder.cloudflare")}</span>
          </label>
          {state.cloudflare ? (
            <input
              type="text"
              className="zm-input"
              value={state.wsPath}
              onChange={set("wsPath")}
              aria-label={t("builder.wsPath")}
              spellCheck="false"
            />
          ) : null}

          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.proxy}
              onChange={set("proxy")}
            />
            <span>{t("builder.proxy")}</span>
          </label>
          {state.proxy ? (
            <input
              type="text"
              className="zm-input"
              value={state.proxyUrl}
              onChange={set("proxyUrl")}
              placeholder="socks5://127.0.0.1:9050"
              aria-label={t("builder.proxyUrl")}
              spellCheck="false"
            />
          ) : null}

          <span className="zm-label">{t("builder.connectTo")}</span>
          <input
            type="text"
            className="zm-input"
            value={state.connectTo}
            onChange={set("connectTo")}
            placeholder="203.0.113.10:3333"
            aria-label={t("builder.connectTo")}
            spellCheck="false"
            autoComplete="off"
          />
          <p className="zm-hint">{t("builder.connectToHint")}</p>

          <label className="zm-check">
            <input type="checkbox" checked={state.msr} onChange={set("msr")} />
            <span>{t("builder.msr")}</span>
          </label>
          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.notune}
              onChange={set("notune")}
            />
            <span>{t("builder.notune")}</span>
          </label>
          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.noHealthRestart}
              onChange={set("noHealthRestart")}
            />
            <span>{t("builder.noHealth")}</span>
          </label>
          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.force}
              onChange={set("force")}
            />
            <span>{t("builder.force")}</span>
          </label>
          <label className="zm-check">
            <input
              type="checkbox"
              checked={state.clone}
              onChange={set("clone")}
            />
            <span>{t("builder.clone")}</span>
          </label>
        </fieldset>
      </form>

      <div className="zm-builder__result">
        <div className="zm-builder__output zm-copy-scope">
          <div className="zm-builder__head">
            <h3>{t("builder.output")}</h3>
            <CopyButton
              text={result.install}
              label={t("builder.copy")}
              copiedLabel={t("builder.copied")}
              manualLabel={t("common.manualCopy")}
              className="zm-btn zm-btn--primary"
              disabled={Boolean(result.blocked)}
            />
          </div>
          <pre>
            <code>{result.install}</code>
          </pre>
          {blockedMessage ? (
            <p className="zm-hint is-bad">{blockedMessage}</p>
          ) : null}
        </div>

        {result.warnings.length > 0 || result.notes.length > 0 ? (
          <section className="zm-notes">
            <h4>{t("builder.notes")}</h4>
            <ul>
              {result.warnings.map((item) => (
                <li key={item.key} className="is-warn">
                  {t("builder.warn." + item.key, item.params)}
                </li>
              ))}
              {result.notes.map((item) => (
                <li key={item.key}>
                  {t("builder.note." + item.key, item.params)}
                </li>
              ))}
            </ul>
          </section>
        ) : null}

        <section className="zm-notes">
          <h4>{t("builder.after")}</h4>
          <div className="zm-copy-scope">
            <pre>
              <code>{result.commands.after}</code>
            </pre>
          </div>
          <h4>{t("builder.remove")}</h4>
          <div className="zm-copy-scope">
            <pre>
              <code>{result.commands.remove}</code>
            </pre>
          </div>
          <h4>{t("builder.plan")}</h4>
          <div className="zm-copy-scope">
            <pre>
              <code>{result.plan}</code>
            </pre>
          </div>
          <p className="zm-hint">{t("builder.planHint")}</p>
          <CopyButton
            text={result.plan}
            label={t("builder.copyPlan")}
            copiedLabel={t("builder.copied")}
            manualLabel={t("common.manualCopy")}
            className="zm-btn"
          />
        </section>
      </div>
    </div>
  );
}
