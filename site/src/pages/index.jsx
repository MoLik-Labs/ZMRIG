import React from "react";
import Head from "@docusaurus/Head";
import Layout from "@theme/Layout";
import Link from "@docusaurus/Link";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import CopyButton from "../components/CopyButton";

const RAW = "https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh";

const COMMAND = `curl -fsSL ${RAW} \\
  | sudo bash -s -- --wallet 4YourMoneroAddress`;

const COPY = {
  en: {
    eyebrow: "RandomX miner · 1 % developer fee, switchable off",
    lede: "One command installs a miner that needs a wallet address and nothing else: it detects the CPU, reserves huge pages, measures the real thread count, writes a systemd unit, and prints the 1 % developer fee it takes — with the flag that removes it. The documentation below is the whole manual — installation, pools, networks that only allow 443, measured benchmarks and a calculator that costs nothing to run.",
    cta: "Read the documentation",
    cta2: "Build a command",
    copy: "Copy",
    copied: "Copied",
    partsTitle: "Four parts, one repository",
    parts: [
      [
        "Miner",
        "XMRig 6.26.0 with every line of donation code removed, plus a complete Zig miner on the same RandomX engine. Never takes a percentage.",
        "Read about the engines",
        "/docs/install/engines",
      ],
      [
        "Installer",
        "One flag. Detects the machine, tunes the host, writes the service, audits the fee, and can be removed without leaving anything behind.",
        "Install",
        "/docs/install/quickstart",
      ],
      [
        "Proxy",
        "One pool connection for a whole farm: an extranonce per rig, per-rig difficulty, tunnels for rigs in another building.",
        "Farm setup",
        "/docs/fleet/proxy",
      ],
      [
        "Pool",
        "Self-hosted Monero pool: stratum over TCP and WebSocket, PPLNS, every share re-hashed before it is paid.",
        "Run a pool",
        "/docs/fleet/pool",
      ],
    ],
    numbers: "Numbers, with the method",
    numbersBody:
      "About 815 H/s on two vCPUs of a Xeon at 2.6 GHz, 634 H/s with huge pages off, 76 H/s in light mode. Ratios are stable; absolute hashrate is not, which is why every figure in these pages comes with the command that produced it.",
    numbersCta: "See the benchmarks",
    moneyCta: "Open the calculator",
  },
  vi: {
    eyebrow: "Miner RandomX · phí 1 %, tắt được",
    lede: "Một lệnh cài xong miner chỉ cần địa chỉ ví: nó tự nhận CPU, tự đặt huge pages, tự đo số thread thật, viết systemd unit, và in ra khoản phí 1 % nó lấy kèm cờ để bỏ. Phần tài liệu bên dưới là toàn bộ sách hướng dẫn — cài đặt, pool, mạng chỉ mở 443, benchmark đo được, và bảng tính chạy miễn phí ngay trong trình duyệt.",
    cta: "Đọc tài liệu",
    cta2: "Tự ghép lệnh",
    copy: "Copy",
    copied: "Đã copy",
    partsTitle: "Bốn phần, một repo",
    parts: [
      [
        "Miner",
        "XMRig 6.26.0 đã bỏ toàn bộ code donate, cộng thêm miner Zig hoàn chỉnh trên cùng engine RandomX. Phí 1 % thời gian Monero ở engine Zig, in ra rõ và tắt được; engine C++ không có mã phí.",
        "Đọc về hai engine",
        "/docs/install/engines",
      ],
      [
        "Installer",
        "Một cờ. Tự nhận máy, chỉnh hệ thống, viết service, kiểm tra phí, và gỡ được mà không để lại gì.",
        "Cài đặt",
        "/docs/install/quickstart",
      ],
      [
        "Proxy",
        "Một kết nối pool cho cả farm: mỗi rig một extranonce, difficulty riêng, có tunnel cho rig ở nơi khác.",
        "Dựng farm",
        "/docs/fleet/proxy",
      ],
      [
        "Pool",
        "Pool Monero tự dựng: stratum TCP và WebSocket, PPLNS, mỗi share được hash lại trước khi trả.",
        "Tự dựng pool",
        "/docs/fleet/pool",
      ],
    ],
    numbers: "Số đo, kèm cách đo",
    numbersBody:
      "Khoảng 815 H/s trên 2 vCPU Xeon 2,6 GHz, 634 H/s khi tắt huge pages, 76 H/s ở chế độ light. Tỉ lệ thì ổn định, hashrate tuyệt đối thì không — nên mọi con số trong tài liệu đều đi kèm lệnh tạo ra nó.",
    numbersCta: "Xem benchmark",
    moneyCta: "Mở bảng tính",
  },
};

export default function Home() {
  const { i18n } = useDocusaurusContext();
  const locale = i18n.currentLocale === "vi" ? "vi" : "en";
  const c = COPY[locale];
  const socialImage = `https://molik-labs.github.io/ZMRIG/img/og-${locale}.png`;

  return (
    <Layout title="ZMRIG" description={c.lede}>
      <Head>
        <meta property="og:type" content="website" />
        <meta property="og:image" content={socialImage} />
        <meta name="twitter:image" content={socialImage} />
        <meta name="twitter:card" content="summary_large_image" />
      </Head>
      <header className="zm-hero">
        <div className="zm-wrap">
          <p className="zm-eyebrow">
            {c.eyebrow} · by <a href="https://github.com/NggKhaiz">@nggkhaiz</a>
          </p>
          <h1>
            <img
              className="zm-mark zm-mark--light"
              src="/ZMRIG/img/logo.svg"
              alt=""
              width="44"
              height="44"
            />
            <img
              className="zm-mark zm-mark--dark"
              src="/ZMRIG/img/logo-dark.svg"
              alt=""
              width="44"
              height="44"
            />
            ZMRIG
          </h1>
          <p className="zm-lede">{c.lede}</p>

          <div className="zm-term">
            <pre>
              <code>{COMMAND}</code>
            </pre>
            <CopyButton
              text={COMMAND}
              label={c.copy}
              copiedLabel={c.copied}
              className="zm-btn zm-btn--dark"
            />
          </div>

          <div className="zm-btn-row">
            <Link className="zm-btn zm-btn--primary" to="/docs/intro">
              {c.cta}
            </Link>
            <Link className="zm-btn" to="/docs/install/builder">
              {c.cta2}
            </Link>
          </div>
        </div>
      </header>

      <main className="zm-wrap">
        <h2 className="zm-section-title">{c.partsTitle}</h2>
        <div className="zm-parts">
          {c.parts.map(([title, body, link, to]) => (
            <article className="zm-part" key={title}>
              <h3>{title}</h3>
              <p>{body}</p>
              <Link to={to}>{link} →</Link>
            </article>
          ))}
        </div>

        <section className="zm-band">
          <div>
            <h2>{c.numbers}</h2>
            <p>{c.numbersBody}</p>
          </div>
          <div className="zm-btn-row">
            <Link className="zm-btn" to="/docs/reference/benchmarks">
              {c.numbersCta}
            </Link>
            <Link className="zm-btn" to="/docs/economics/profitability">
              {c.moneyCta}
            </Link>
          </div>
        </section>
      </main>
    </Layout>
  );
}
