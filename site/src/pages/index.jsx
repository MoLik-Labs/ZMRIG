import React from "react";
import Head from "@docusaurus/Head";
import Layout from "@theme/Layout";
import Link from "@docusaurus/Link";
import useBaseUrl from "@docusaurus/useBaseUrl";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import { HOME_COPY } from "../lib/home-content.mjs";

function Home() {
  const { i18n } = useDocusaurusContext();
  const locale = i18n.currentLocale === "vi" ? "vi" : "en";
  const copy = HOME_COPY[locale];
  const logoLight = useBaseUrl("img/logo.svg");
  const logoDark = useBaseUrl("img/logo-dark.svg");
  const socialImage = useBaseUrl(`img/og-${locale}.png`);
  const installScript = "https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh";

  return (
    <Layout title="ZMRIG" description={copy.lede}>
      <Head>
        <meta property="og:type" content="website" />
        <meta property="og:image" content={socialImage} />
        <meta name="twitter:image" content={socialImage} />
        <meta name="twitter:card" content="summary_large_image" />
      </Head>
      <main className="zm-home">
        <section className="zm-home__hero" aria-labelledby="home-title">
          <div className="zm-home__copy">
            <h1 id="home-title">
              <img className="zm-home__mark zm-home__mark--light" src={logoLight} alt="" width="38" height="38" />
              <img className="zm-home__mark zm-home__mark--dark" src={logoDark} alt="" width="38" height="38" />
              {copy.title}
            </h1>
            <p className="zm-home__lede">{copy.lede}</p>
            <div className="zm-home__actions">
              <Link className="zm-action zm-action--primary" to={copy.primary.to}>{copy.primary.label}</Link>
              <Link className="zm-action zm-action--secondary" to={copy.secondary.to}>{copy.secondary.label}</Link>
            </div>
            <p className="zm-home__direct-install">
              {copy.directInstall}{" "}
              <a href={installScript} target="_blank" rel="noopener noreferrer">oneclick.sh</a>
            </p>
            <p className="zm-home__byline">
              {locale === "vi" ? "Phát triển bởi" : "Built by"}{" "}
              <a href="https://github.com/NggKhaiz">@nggkhaiz</a> ·{" "}
              <a href="https://github.com/MoLik-Labs/ZMRIG">{copy.source}</a>
            </p>
          </div>
        </section>

        <section className="zm-home__routes" aria-labelledby="routes-title">
          <div className="zm-section-head">
            <h2 id="routes-title">{copy.quickTitle}</h2>
            <p>{copy.quickIntro}</p>
          </div>
          <div className="zm-route-grid">
            {copy.paths.map((item) => (
              <article className="zm-route" key={item.id}>
                <h3>{item.title}</h3>
                <p>{item.body}</p>
                <Link to={item.to} className="zm-route__link">{item.action}</Link>
              </article>
            ))}
          </div>
        </section>

        <section className="zm-home__principles" aria-labelledby="principles-title">
          <div className="zm-principles__intro">
            <h2 id="principles-title">{copy.trustTitle}</h2>
            <p>{copy.trustIntro}</p>
            <Link to="/docs/reference/fee" className="zm-text-link">{copy.feeLink}</Link>
          </div>
          <div className="zm-facts">
            {copy.trustFacts.map((fact) => (
              <article className="zm-fact" key={fact.id}>
                <h3>{fact.label}</h3>
                <p>{fact.body}</p>
              </article>
            ))}
          </div>
        </section>
      </main>
    </Layout>
  );
}

export default Home;
