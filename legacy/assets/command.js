// Turning a set of choices into the exact command oneclick.sh will receive.
//
// Pure on purpose: no DOM, no storage, no clock. The home-page builder and the
// wizard both call `build()`, and the tests call it directly with the same
// states the pages produce, so the two UIs cannot generate different commands
// for the same answers.
//
// Rules encoded here (each one was a bug or a near miss at some point):
//   * `--engine auto` and `--profile auto` mean "let the installer decide", and
//     the installer decides only when the flag is absent. So: no flag.
//   * The C++ engine has no WebSocket client and no proxy support. Asking for
//     either forces zmrig instead of writing a config nothing can run.
//   * A TLS pool is `tls://host:port`; the scheme is part of the value, not a
//     separate flag, because that is what `oneclick.sh` parses.
//   * Everything user-supplied goes through shellQuote. A rig name is typed by
//     a human and pasted into a root shell.

(function (root) {
  "use strict";

  var RAW_URL = "https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh";

  function pools() {
    return root.zmrigPools;
  }

  function shellQuote(value) {
    if (value === "") return "''";
    if (/^[A-Za-z0-9._:\/@%+=,-]+$/.test(value)) return value;

    return "'" + String(value).replace(/'/g, "'\\''") + "'";
  }

  // Monero addresses: 95 characters (4… primary, 8… subaddress) or 106 for an
  // integrated address. Base58 excludes 0, O, I and l.
  function walletState(value) {
    if (!value) {
      return {
        ok: false,
        empty: true,
        message: "Ví chính bắt đầu bằng 4, subaddress bằng 8. Không nhập seed hay private key.",
      };
    }

    if (!/^[48][1-9A-HJ-NP-Za-km-z]+$/.test(value)) {
      return {
        ok: false,
        empty: false,
        message: "Ký tự không hợp lệ — địa chỉ Monero dùng base58 (không có 0, O, I, l).",
      };
    }

    if (value.length === 95) return { ok: true, empty: false, message: "Địa chỉ hợp lệ (95 ký tự)." };
    if (value.length === 106 && value[0] === "4") {
      return { ok: true, empty: false, message: "Địa chỉ tích hợp (106 ký tự)." };
    }

    return {
      ok: false,
      empty: false,
      message: "Độ dài " + value.length + " — địa chỉ thường dài 95 ký tự.",
    };
  }

  // host:port, with an optional scheme. Rejects spaces and anything that would
  // need escaping, because the value ends up in a URL and in a JSON file.
  function hostState(value) {
    var text = String(value || "").trim();
    if (!text) return { ok: false, empty: true, message: "Nhập host:port của pool, ví dụ pool.example.com:3333." };

    // `host:port`, with an optional scheme in front — a pool URL pasted from a
    // provider's page is `stratum+tcp://host:3333`, and rejecting that would be
    // a needless round trip.
    var match = /^(?:(?:tls|stratum\+ssl|stratum\+tcp|stratum|wss?):\/\/)?([^\s:\/]+):(\d{1,5})\/?([^\s]*)$/i.exec(text);
    if (!match) {
      return {
        ok: false,
        empty: false,
        message: "Chưa đúng dạng host:port (tỉ dụ pool.example.com:3333). Dán URL đầy đủ cũng được.",
      };
    }

    var port = Number(match[2]);
    if (!(port > 0 && port < 65536)) {
      return { ok: false, empty: false, message: "Port " + port + " không hợp lệ." };
    }

    return { ok: true, empty: false, message: "Đích: " + match[1] + ":" + port };
  }

  function normalise(state) {
    var s = state || {};
    return {
      wallet: String(s.wallet || "").trim(),
      rig: String(s.rig || "").trim().slice(0, 32),
      engine: s.engine === "xmrig" || s.engine === "zmrig" ? s.engine : "auto",
      profile: s.profile === "free" || s.profile === "watt" ? s.profile : "auto",
      pool: String(s.pool || "moneroocean"),
      host: String(s.host || "").trim(),
      failover: (s.failover || []).filter(Boolean),
      tls: Boolean(s.tls),
      cloudflare: Boolean(s.cloudflare),
      wsPath: String(s.wsPath || "/stratum").trim() || "/stratum",
      proxy: Boolean(s.proxy),
      proxyUrl: String(s.proxyUrl || "").trim(),
      connectTo: String(s.connectTo || "").trim(),
      msr: Boolean(s.msr),
      nicehash: Boolean(s.nicehash),
      notune: Boolean(s.notune),
      autotuneOff: Boolean(s.autotuneOff),
      noHealthRestart: Boolean(s.noHealthRestart),
      force: Boolean(s.force),
      clone: Boolean(s.clone),
      cpu: Number(s.cpu),
    };
  }

  function build(state) {
    var s = normalise(state);
    var table = pools();
    var pool = table ? table.find(s.pool) : null;
    var isCustom = !pool;

    var host = s.host || (pool ? pool.host : "");
    var wallet = walletState(s.wallet);
    var hostCheck = hostState(host);

    var notes = [];
    var warnings = [];
    var blocked = null;

    // --- what the pool endpoint becomes -----------------------------------
    var endpoint = "";
    if (!isCustom && s.tls && pool && pool.tlsPort) {
      endpoint = "tls://" + pool.tlsPort;
      notes.push("TLS trên cổng 443: giống HTTPS với tường lửa, chậm hơn TCP trực tiếp một chút.");
    } else if (!isCustom && s.tls && pool && !pool.tlsPort) {
      endpoint = "tls://" + pool.host;
      warnings.push(pool.name + " không công bố cổng TLS riêng — dùng TLS trên cổng mặc định có thể bị từ chối. Bỏ chọn TLS hoặc hỏi pool.");
    } else if (isCustom) {
      endpoint = s.host;
      if (/^tls:\/\//i.test(s.host)) endpoint = s.host;
    } else {
      endpoint = pool.host;
    }

    var failover = [];
    for (var i = 0; i < s.failover.length; i += 1) {
      var other = table ? table.find(s.failover[i]) : null;
      var value = other ? other.host : s.failover[i];
      if (value && value !== endpoint) failover.push(value);
    }

    // --- engine and flags --------------------------------------------------
    var engine = s.engine;
    if ((s.cloudflare || s.proxy || s.connectTo) && engine === "xmrig") {
      engine = "zmrig";
      warnings.push("Engine C++ không nói được WebSocket/proxy, nên lệnh dùng zmrig.");
    }

    if (pool && pool.switching && engine === "zmrig") {
      warnings.push(
        "Bạn chọn zmrig cho pool chuyển thuật toán: rig chỉ nhận họ RandomX, mất phần lợi thế lớn nhất của pool này. Để engine auto nếu không có lý do cụ thể."
      );
    }

    var args = ["install"];
    args.push("--wallet", s.wallet || "YOUR_WALLET");
    if (s.rig) args.push("--rig-id", s.rig);
    if (engine !== "auto") args.push("--engine", engine);
    args.push("--pool", endpoint || "YOUR_POOL_HOST");
    if (failover.length) args.push("--failover", failover.join(","));

    if (s.cloudflare) {
      args.push("--cloudflare");
      var wsPath = s.wsPath;
      if (wsPath[0] !== "/") wsPath = "/" + wsPath;
      args.push("--ws-path", wsPath);
    }

    if (s.profile !== "auto") args.push("--profile", s.profile);
    if (s.proxy) args.push("--proxy", s.proxyUrl || "socks5://127.0.0.1:9050");
    if (s.connectTo) args.push("--connect-to", s.connectTo);
    // MSR is on by default for a root install; this switch exists for hosts
    // that refuse the write (most VMs and containers).
    if (s.msr) args.push("--no-msr");
    if (s.nicehash) args.push("--nicehash");
    if (Number.isFinite(s.cpu) && s.cpu > 0 && s.cpu < 100) args.push("--cpu-hint", String(Math.round(s.cpu)));
    if (s.autotuneOff) args.push("--no-autotune");
    if (s.notune) args.push("--no-tune");
    if (s.noHealthRestart) args.push("--no-health-restart");
    if (s.force) args.push("--force");
    args.push("--yes");

    var quoted = args
      .map(function (arg) {
        return /^--/.test(arg) ? arg : shellQuote(arg);
      })
      .join(" ");

    var install = s.clone
      ? "sudo ./oneclick.sh " + quoted
      : "curl -fsSL " + RAW_URL + " \\\n  | sudo bash -s -- " + quoted;

    // A preview that touches nothing: same pool resolution, same config, no
    // build and no service. This is the honest "what will happen" button.
    var planArgs = ["plan"];
    if (s.wallet) planArgs.push("--wallet", s.wallet);
    planArgs.push("--pool", endpoint || "YOUR_POOL_HOST");
    if (failover.length) planArgs.push("--failover", failover.join(","));
    if (engine !== "auto") planArgs.push("--engine", engine);
    if (s.profile !== "auto") planArgs.push("--profile", s.profile);

    var planQuoted = planArgs
      .map(function (arg) {
        return /^--/.test(arg) ? arg : shellQuote(arg);
      })
      .join(" ");

    var plan = s.clone
      ? "sudo ./oneclick.sh " + planQuoted
      : "curl -fsSL " + RAW_URL + " \\\n  | sudo bash -s -- " + planQuoted;

    // --- state that must block the copy button ----------------------------
    if (!wallet.ok) blocked = wallet.empty ? "empty-wallet" : "bad-wallet";
    else if (isCustom && !hostCheck.ok) blocked = "bad-host";
    else if (s.cloudflare && isCustom && !hostCheck.ok) blocked = "bad-host";
    else if (s.proxy && !s.proxyUrl) blocked = "no-proxy";

    if (s.notune) notes.push("Bỏ tune hệ thống: mất khoảng 20–30 % hashrate vì không có huge pages.");
    if (s.autotuneOff) notes.push("Bỏ autotune: giữ số thread mặc định, có thể chậm hơn vài % trên CPU lạ.");
    if (s.noHealthRestart) notes.push("Không tự khởi động lại khi pool từ chối mọi share — chỉ nên dùng khi có giám sát riêng.");
    if (s.profile === "watt") notes.push("Chế độ watt: giữ governor tiết kiệm điện, bớt thread SMT — hashrate thấp hơn vài % nhưng H/W cao hơn.");
    if (s.profile === "free") notes.push("Chế độ free: dùng hết CPU, chỉ hợp với máy dùng điện free.");

    return {
      args: args,
      flags: args.filter(function (arg) { return /^--/.test(arg); }),
      wallet: wallet,
      host: hostCheck,
      pool: {
        id: isCustom ? "custom" : pool.id,
        name: isCustom ? "pool tự nhập" : pool.name,
        endpoint: endpoint,
        fee: pool ? pool.fee : null,
        switching: pool ? pool.switching : null,
      },
      failover: failover,
      engine: engine,
      profile: s.profile,
      install: install,
      plan: plan,
      commands: {
        install: install,
        plan: plan,
        after: [
          "# trạng thái dịch vụ và log — cần cho mọi lần gỡ lỗi",
          "sudo systemctl status zmrig --no-pager -l",
          "sudo journalctl -u zmrig -n 40 --no-pager",
          "",
          "# đo lại máy và in mã báo cáo cho bảng tính",
          "zmrig --report --power 0",
        ].join("\n"),
        remove: [
          "# xem trước rồi mới xoá",
          "sudo ./oneclick.sh purge --dry-run",
          "sudo ./oneclick.sh purge",
        ].join("\n"),
      },
      notes: notes,
      warnings: warnings,
      blocked: blocked,
    };
  }

  root.zmrigCommand = {
    RAW_URL: RAW_URL,
    build: build,
    walletState: walletState,
    hostState: hostState,
    shellQuote: shellQuote,
  };

  if (typeof module === "object" && module.exports) module.exports = root.zmrigCommand;
})(typeof globalThis !== "undefined" ? globalThis : this);
