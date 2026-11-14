// Every string the interactive components render, in both locales.
//
// Kept out of the components so the two language versions cannot drift: a key
// that exists in `en` and not in `vi` fails site/tests/messages.test.mjs, which
// also rejects a key declared twice — JavaScript would accept that silently and
// the last value would win.

export const messages = {
  en: {
    "builder.intro":
      "Every switch below maps to one flag. What you see is exactly what the installer receives — nothing is added later.",
    "builder.coin": "Coin",
    "builder.coinHint":
      "The seven algorithms both engines hash. Pool presets exist for Monero only, so the other coins ask you for the endpoint.",
    "builder.coinNoPools":
      "{coin} has no preset here. Paste the endpoint your pool publishes — host:port, and the TLS port if it has one.",
    "builder.wallet": "Wallet address",
    "builder.rig": "Rig name (optional)",
    "builder.rigHint": "Shown on the pool dashboard to tell machines apart.",
    "builder.pool": "Pool",
    "builder.poolCustom": "Custom — I will type the host",
    "builder.host": "Pool host:port",
    "builder.failover": "Backup pools",
    "builder.failoverHint":
      "Used only when the primary cannot be reached or refuses this IP. Pick a different operator.",
    "builder.engine": "Engine",
    "builder.engineAuto": "Automatic (recommended)",
    "builder.engineZmrig":
      "zmrig — Zig, the RandomX family, WebSocket and proxies",
    "builder.engineXmrig": "xmrig — C++, every algorithm",
    "builder.engineAutoHint":
      "Switching pool → C++ engine. RandomX-only pool → zmrig.",
    "builder.profile": "Power profile",
    "builder.profileAuto": "Automatic (same as max hashrate)",
    "builder.profileFree": "Maximum hashrate (default)",
    "builder.profileWatt": "Optional: maximum hashes per watt",
    "builder.network": "Network",
    "builder.tls": "TLS to the pool",
    "builder.cloudflare": "Only 443 out — WebSocket over TLS",
    "builder.wsPath": "WebSocket path",
    "builder.proxy": "Through an HTTP/SOCKS5 proxy",
    "builder.proxyUrl": "Proxy URL",
    "builder.connectTo": "Dial a different address (--connect-to)",
    "builder.connectToHint":
      "host:port. Keeps the pool's hostname for SNI and the Host header, which is how a filtered DNS name is worked around. Leave it empty unless the name does not resolve here.",
    "builder.plan": "The same command, with plan",
    "builder.planHint":
      "Resolves the pool, the engine, the profile, the huge pages and the thread search, prints all of it, and writes nothing.",
    "builder.msr": "Host refuses MSR writes (VM, container)",
    "builder.nicehash": "Rented hash / NiceHash",
    "builder.notune": "Do not tune the host",
    "builder.autotune": "Do not search for the best thread count",
    "builder.noHealth": "Do not restart when earnings stop",
    "builder.force": "Overwrite an existing config",
    "builder.clone": "I already cloned the repository",
    "builder.output": "Your command",
    "builder.copy": "Copy command",
    "builder.copied": "Copied",
    "builder.copyPlan": "Copy preview",
    "builder.after": "After the install",
    "builder.remove": "Remove it again",
    "builder.notes": "What this changes",
    "builder.blocked.wallet-empty": "Paste a wallet address to get a command.",
    "builder.blocked.wallet-invalid": "That does not look like a {coin} address.",
    "builder.blocked.pool-empty":
      "{coin} needs a pool endpoint — this site does not know one, so it will not invent it.",
    "builder.blocked.host-invalid": "Enter the pool as host:port.",
    "builder.blocked.proxy-invalid":
      "The proxy must look like socks5://host:port or http://user:pass@host:port.",
    "builder.blocked.connect-to-invalid":
      "Dial address must be host:port, for example 203.0.113.10:3333.",
    "builder.blocked.proxy-missing": "Enter the proxy URL.",
    "builder.wallet.empty": "Not entered yet.",
    "builder.wallet.valid": "Valid Monero address: checksum verified (95 characters).",
    "builder.wallet.integrated": "Integrated address: checksum verified (106 characters).",
    "builder.wallet.checksum":
      "One character is wrong: the checksum does not match. Copy the address again — this is the typo that costs a week of hashing.",
    "builder.wallet.network":
      "This is a valid address on another network (stagenet or testnet). A mainnet pool cannot pay it.",
    "builder.wallet.plausible":
      "Base58 address, {n} characters. The pool checks the checksum — this page does not.",
    "builder.wallet.prefix":
      "Length is plausible, but {coin} addresses start with {prefixes}. Look again before installing — a wrong address mines for somebody else.",
    "builder.wallet.charset":
      "Invalid character — CryptoNote addresses are base58 (no 0, O, I, l).",
    "builder.wallet.length":
      "Length {n}: {coin} addresses are 95 characters, 106 integrated.",
    "builder.host.empty":
      "Enter the pool as host:port, e.g. pool.example.com:3333.",
    "builder.host.shape":
      "Not host:port yet. A full URL pasted from the pool's own page is fine.",
    "builder.host.port": "Port {n} is not valid.",
    "builder.host.ok": "Target: {host}:{port}",
    "builder.note.tls443":
      "TLS on 443 looks like HTTPS to a firewall; slightly slower than plain TCP.",
    "builder.note.noTlsPort":
      "{pool} publishes no separate TLS port — TLS on the default port may be refused. Uncheck TLS or ask the pool.",
    "builder.note.notune":
      "Skipping host tuning costs about 20–30 % hashrate: no huge pages.",
    "builder.note.autotuneOff":
      "Skipping the thread search keeps the default thread count, which can be a few percent slower on an unusual CPU.",
    "builder.note.noHealthRestart":
      "No restart when the pool rejects every share — only with your own monitoring.",
    "builder.note.profileWatt":
      "Metered profile: keeps the powersave governor and fewer SMT threads — a few percent less hashrate, more hashes per watt.",
    "builder.note.profileFree":
      "Maximum-hashrate profile: uses every logical CPU, on mains or battery. The miner still targets 80 C by default and backs off if the CPU overheats.",
    "builder.note.algoPinned":
      "Pinned with --algo {algo}: {coin} is only mined with that algorithm, so both engines give the same shares.",
    "builder.warn.engineForced":
      "The C++ engine has no WebSocket client and no proxy support, so the command uses zmrig.",
    "builder.warn.switchingPool":
      "zmrig on a switching pool: the rig only ever gets the RandomX family, which gives up the largest advantage of {pool}. Leave the engine on automatic unless you have a reason.",
    "builder.warn.noTlsPort":
      "This pool has no TLS port. Traffic to {pool} is plain text, which is fine for a pool that only reads your address.",
    "calc.intro":
      "Paste one ZMRIG1. code per machine. Everything runs in this page — no code is sent anywhere.",
    "calc.paste": "Machine codes",
    "calc.pasteHint":
      "Get one with sudo ./oneclick.sh report, or let the miner keep a file fresh with --report-file.",
    "calc.add": "Add machines",
    "calc.sample": "Load sample data",
    "calc.import": "Import JSON",
    "calc.export": "Export JSON",
    "calc.clear": "Clear all",
    "calc.empty":
      "No machines yet. Paste a code above, or load the sample data.",
    "calc.errors": "Codes that could not be read",
    "calc.settings": "Assumptions",
    "calc.price": "Electricity price (per kWh)",
    "calc.psu": "PSU efficiency (%)",
    "calc.base": "System overhead (W)",
    "calc.xmrPrice": "XMR price",
    "calc.payout": "Revenue model",
    "calc.payoutPool": "Per kH/s per day (pool rate)",
    "calc.payoutNetwork": "From network hashrate",
    "calc.xmrPerKhsDay": "XMR per kH/s per day",
    "calc.networkHash": "Network hashrate (GH/s)",
    "calc.blockReward": "Block reward (XMR)",
    "calc.poolFee": "Pool fee (%)",
    "calc.window": "Hashrate window",
    "calc.w10": "10 s",
    "calc.w60": "60 s",
    "calc.w15": "15 min",
    "calc.wBest": "Session best",
    "calc.machine": "Machine",
    "calc.hashrate": "Hashrate",
    "calc.kwh": "kWh/day",
    "calc.cost": "Power cost/day",
    "calc.xmr": "XMR/day",
    "calc.revenue": "Revenue/day",
    "calc.profit": "Profit/day",
    "calc.override": "Wall power (W)",
    "calc.remove": "Remove",
    "calc.totalHashrate": "Total hashrate",
    "calc.machines": "machines",
    "calc.totalWatts": "Wall power",
    "calc.totalRevenue": "Revenue per day",
    "calc.totalProfit": "Profit per day",
    "calc.perMonth": "per month",
    "calc.efficiency": "Hashes per watt",
    "calc.breakEven": "Break-even electricity price",
    "calc.breakEvenSub":
      "$/kWh where the power bill equals what this hardware mines. Below it, running costs less than it earns.",
    "calc.unknownPower":
      "{n} machine(s) report no power; they are excluded from the power totals, not guessed.",
    "calc.note":
      "Every figure is an estimate. Network difficulty, coin price and share luck move constantly; the miner's own measurements are the only hard numbers here.",

    "coins.title": "Coin comparison",
    "coins.lead":
      "One rig, seven algorithms. Fill in a coin's own numbers and the table ranks what it actually pays per day — with your figures, not with mine.",
    "coins.hashrate": "Rig hashrate (H/s)",
    "coins.hashrateHint":
      "Used for every coin that has no figure of its own. The fleet total fills it in when machines are loaded above.",
    "coins.prices": "Fetch prices (CoinGecko)",
    "coins.pricesLoading": "Asking CoinGecko…",
    "coins.pricesOk": "Updated {n} price(s) from CoinGecko.",
    "coins.pricesError":
      "CoinGecko did not answer — offline, blocked or rate-limited. Prices are unchanged; type them yourself if you want them now.",
    "coins.pricesHint":
      "Nothing is fetched until you press that button, so this page works offline and no request leaves your browser before you ask for one.",
    "coins.best": "Best coin at this hashrate",
    "coins.bestLine":
      "{coin} pays about {revenue} per day for {hashrate} — {coinDay} {symbol}.",
    "coins.bestEmpty":
      "No coin has every number yet, so there is nothing honest to recommend. Enter the rig’s hashrate, then reward, block time and network hashrate for one coin below.",
    "coins.build": "Build the {coin} command",
    "coins.tableCoin": "Coin",
    "coins.tableRevenue": "Revenue/day",
    "coins.tableCoinDay": "Coin/day",
    "coins.tableStatus": "Numbers",
    "coins.ready": "complete",
    "coins.needs": "missing {fields}",
    "coins.edit": "The numbers used",
    "coins.fieldReward": "Block reward",
    "coins.fieldBlockTime": "Block time (s)",
    "coins.fieldNetwork": "Network hashrate (H/s)",
    "coins.fieldPrice": "Price (USD)",
    "coins.fieldRig": "This rig (H/s)",
    "coins.reset": "Forget my numbers",
    "coins.note":
      "Every field is yours to fill. A coin with a blank field shows why it cannot be ranked instead of a zero that looks like an answer, and no pool endpoint is invented for a coin this repository does not know.",
    "coins.source":
      "Reward, block time and network hashrate come from the coin's own explorer; prices from CoinGecko on request. The numbers stay in this browser.",
    "coins.missingReward": "reward",
    "coins.missingBlockTime": "block time",
    "coins.missingNetwork": "network hashrate",
    "coins.missingPrice": "price",
    "coins.missingHashrate": "rig hashrate",

    "pooltable.pool": "Pool",
    "pooltable.fee": "Fee",
    "pooltable.min": "Minimum payout",
    "pooltable.endpoint": "Endpoint",
    "pooltable.tls": "TLS on 443",
    "pooltable.note": "Why",
    "pooltable.no": "no",
    "pooltable.checked": "Fees and minimums checked October 2026.",

    "common.manualCopy": "Press Ctrl+C",
  },

  vi: {
    "builder.intro":
      "Mỗi ô dưới đây ứng với đúng một cờ. Lệnh hiện ra là đúng thứ installer nhận — không có gì được thêm vào sau.",
    "builder.coin": "Đồng coin",
    "builder.coinHint":
      "Bảy thuật toán mà cả hai engine đều băm được. Preset pool chỉ có cho Monero, các đồng khác sẽ hỏi endpoint.",
    "builder.coinNoPools":
      "{coin} không có preset ở đây. Dán endpoint mà pool của bạn công bố — host:port, và cổng TLS nếu có.",
    "builder.wallet": "Địa chỉ ví",
    "builder.rig": "Tên máy (tuỳ chọn)",
    "builder.rigHint": "Hiện trên dashboard của pool để phân biệt các máy.",
    "builder.pool": "Pool",
    "builder.poolCustom": "Tự nhập — tôi sẽ gõ địa chỉ",
    "builder.host": "Host:port của pool",
    "builder.failover": "Pool dự phòng",
    "builder.failoverHint":
      "Chỉ dùng khi pool chính không tới được hoặc từ chối IP này. Chọn nhà vận hành khác.",
    "builder.engine": "Engine",
    "builder.engineAuto": "Tự nhận diện (khuyến nghị)",
    "builder.engineZmrig": "zmrig — Zig, họ RandomX, WebSocket và proxy",
    "builder.engineXmrig": "xmrig — C++, mọi thuật toán",
    "builder.engineAutoHint":
      "Pool chuyển thuật toán → engine C++. Pool chỉ RandomX → zmrig.",
    "builder.profile": "Chế độ điện",
    "builder.profileAuto": "Tự động (giống tối đa hashrate)",
    "builder.profileFree": "Hashrate tối đa (mặc định)",
    "builder.profileWatt": "Tùy chọn: tối đa hash trên mỗi watt",
    "builder.network": "Mạng",
    "builder.tls": "TLS tới pool",
    "builder.cloudflare": "Chỉ ra ngoài được 443 — WebSocket qua TLS",
    "builder.wsPath": "Đường dẫn WebSocket",
    "builder.proxy": "Đi qua proxy HTTP/SOCKS5",
    "builder.proxyUrl": "Địa chỉ proxy",
    "builder.connectTo": "Nối tới địa chỉ khác (--connect-to)",
    "builder.connectToHint":
      "host:port. Giữ hostname của pool cho SNI và header Host — cách xử lý khi tên miền bị lọc DNS. Để trống nếu tên phân giải được bình thường.",
    "builder.plan": "Đúng lệnh đó, nhưng dùng plan",
    "builder.planHint":
      "Phân giải pool, engine, profile, huge pages và bước dò thread, in ra rồi không ghi gì.",
    "builder.msr": "Máy không cho ghi MSR (VM, container)",
    "builder.nicehash": "Thuê hash / NiceHash",
    "builder.notune": "Không chỉnh hệ thống",
    "builder.autotune": "Không dò số thread tốt nhất",
    "builder.noHealth": "Không tự khởi động lại khi mất doanh thu",
    "builder.force": "Ghi đè config đang có",
    "builder.clone": "Tôi đã clone repo",
    "builder.output": "Lệnh của bạn",
    "builder.copy": "Copy lệnh",
    "builder.copied": "Đã copy",
    "builder.copyPlan": "Copy lệnh xem trước",
    "builder.after": "Sau khi cài",
    "builder.remove": "Gỡ cài đặt",
    "builder.notes": "Lệnh này thay đổi gì",
    "builder.blocked.wallet-empty": "Dán địa chỉ ví để có lệnh.",
    "builder.blocked.wallet-invalid": "Chuỗi này không giống địa chỉ {coin}.",
    "builder.blocked.pool-empty":
      "{coin} cần endpoint pool — trang này không biết endpoint nào nên sẽ không tự bịa.",
    "builder.blocked.host-invalid": "Nhập pool dạng host:port.",
    "builder.blocked.proxy-invalid":
      "Proxy phải có dạng socks5://host:port hoặc http://user:pass@host:port.",
    "builder.blocked.connect-to-invalid":
      "Địa chỉ dial phải là host:port, ví dụ 203.0.113.10:3333.",
    "builder.blocked.proxy-missing": "Nhập địa chỉ proxy.",
    "builder.wallet.empty": "Chưa nhập gì.",
    "builder.wallet.valid": "Địa chỉ Monero hợp lệ: đã xác minh checksum (95 ký tự).",
    "builder.wallet.integrated": "Địa chỉ tích hợp: đã xác minh checksum (106 ký tự).",
    "builder.wallet.checksum":
      "Sai một ký tự: checksum không khớp. Sao chép lại địa chỉ — đây đúng là kiểu gõ nhầm làm mất một tuần đào.",
    "builder.wallet.network":
      "Đây là địa chỉ hợp lệ nhưng ở mạng khác (stagenet hoặc testnet). Pool mainnet không trả được cho nó.",
    "builder.wallet.plausible":
      "Địa chỉ base58, {n} ký tự. Pool kiểm tra checksum — trang này thì không.",
    "builder.wallet.prefix":
      "Độ dài hợp lý, nhưng địa chỉ {coin} bắt đầu bằng {prefixes}. Xem lại trước khi cài — sai địa chỉ là đào cho người khác.",
    "builder.wallet.charset":
      "Ký tự không hợp lệ — địa chỉ CryptoNote dùng base58 (không có 0, O, I, l).",
    "builder.wallet.length":
      "Dài {n} ký tự: địa chỉ {coin} dài 95, địa chỉ tích hợp 106.",
    "builder.host.empty": "Nhập host:port, ví dụ pool.example.com:3333.",
    "builder.host.shape":
      "Chưa đúng dạng host:port. Dán URL đầy đủ từ trang của pool cũng được.",
    "builder.host.port": "Port {n} không hợp lệ.",
    "builder.host.ok": "Đích: {host}:{port}",
    "builder.note.tls443":
      "TLS trên 443 trông như HTTPS với tường lửa, chậm hơn TCP trực tiếp một chút.",
    "builder.note.noTlsPort":
      "{pool} không công bố cổng TLS riêng — TLS trên cổng mặc định có thể bị từ chối. Bỏ chọn TLS hoặc hỏi pool.",
    "builder.note.notune":
      "Bỏ chỉnh hệ thống mất khoảng 20–30 % hashrate: không có huge pages.",
    "builder.note.autotuneOff":
      "Bỏ dò thread thì giữ số thread mặc định, có thể chậm hơn vài % trên CPU lạ.",
    "builder.note.noHealthRestart":
      "Không khởi động lại khi pool từ chối mọi share — chỉ dùng khi có giám sát riêng.",
    "builder.note.profileWatt":
      "Chế độ trả điện: giữ governor tiết kiệm điện và bớt thread SMT — hashrate thấp hơn vài %, H/W cao hơn.",
    "builder.note.profileFree":
      "Chế độ hashrate tối đa: dùng mọi CPU logic, dù cắm điện hay dùng pin. Miner vẫn đặt mục tiêu 80 °C và giảm thread nếu CPU quá nóng.",
    "builder.note.algoPinned":
      "Ghim bằng --algo {algo}: {coin} chỉ đào bằng thuật toán đó, nên cả hai engine cho share như nhau.",
    "builder.warn.engineForced":
      "Engine C++ không nói được WebSocket và không qua proxy, nên lệnh dùng zmrig.",
    "builder.warn.switchingPool":
      "zmrig trên pool chuyển thuật toán: rig chỉ nhận họ RandomX, mất phần lợi thế lớn nhất của {pool}. Để engine tự nhận diện nếu không có lý do cụ thể.",
    "builder.warn.noTlsPort":
      "Pool này không có cổng TLS. Dữ liệu gửi tới {pool} là văn bản thường — chấp nhận được với pool chỉ đọc địa chỉ ví.",
    "calc.intro":
      "Dán mỗi máy một mã ZMRIG1. Mọi phép tính chạy trong trang này — không mã nào được gửi đi đâu.",
    "calc.paste": "Mã máy",
    "calc.pasteHint":
      "Lấy mã bằng sudo ./oneclick.sh report, hoặc để miner tự cập nhật file với --report-file.",
    "calc.add": "Thêm máy",
    "calc.sample": "Dùng dữ liệu mẫu",
    "calc.import": "Nhập JSON",
    "calc.export": "Xuất JSON",
    "calc.clear": "Xoá tất cả",
    "calc.empty": "Chưa có máy nào. Dán mã ở trên, hoặc dùng dữ liệu mẫu.",
    "calc.errors": "Mã không đọc được",
    "calc.settings": "Giả định",
    "calc.price": "Giá điện (mỗi kWh)",
    "calc.psu": "Hiệu suất PSU (%)",
    "calc.base": "Điện nền hệ thống (W)",
    "calc.xmrPrice": "Giá XMR",
    "calc.payout": "Cách tính doanh thu",
    "calc.payoutPool": "Theo kH/s mỗi ngày (tỉ lệ pool)",
    "calc.payoutNetwork": "Theo hashrate mạng",
    "calc.xmrPerKhsDay": "XMR mỗi kH/s mỗi ngày",
    "calc.networkHash": "Hashrate mạng (GH/s)",
    "calc.blockReward": "Thưởng mỗi block (XMR)",
    "calc.poolFee": "Phí pool (%)",
    "calc.window": "Cửa sổ hashrate",
    "calc.w10": "10 giây",
    "calc.w60": "60 giây",
    "calc.w15": "15 phút",
    "calc.wBest": "Cao nhất phiên",
    "calc.machine": "Máy",
    "calc.hashrate": "Hashrate",
    "calc.kwh": "kWh/ngày",
    "calc.cost": "Tiền điện/ngày",
    "calc.xmr": "XMR/ngày",
    "calc.revenue": "Doanh thu/ngày",
    "calc.profit": "Lợi nhuận/ngày",
    "calc.override": "Công suất ổ cắm (W)",
    "calc.remove": "Xoá",
    "calc.totalHashrate": "Tổng hashrate",
    "calc.machines": "máy",
    "calc.totalWatts": "Công suất (wall)",
    "calc.totalRevenue": "Doanh thu mỗi ngày",
    "calc.totalProfit": "Lợi nhuận mỗi ngày",
    "calc.perMonth": "mỗi tháng",
    "calc.efficiency": "Hash mỗi watt",
    "calc.breakEven": "Giá điện hoà vốn",
    "calc.breakEvenSub":
      "$/kWh mà tại đó tiền điện đúng bằng tiền đào được. Thấp hơn mức này là chạy có lãi.",
    "calc.unknownPower":
      "{n} máy không báo công suất; chúng bị loại khỏi tổng điện chứ không được đoán.",
    "calc.note":
      "Mọi con số đều là ước lượng. Độ khó mạng, giá coin và may mắn share thay đổi liên tục; chỉ số đo của miner là số thật.",

    "coins.title": "So sánh coin",
    "coins.lead":
      "Một rig, bảy thuật toán. Nhập số của từng đồng và bảng xếp hạng theo số tiền thật mỗi ngày — bằng số của bạn, không phải số của tôi.",
    "coins.hashrate": "Hashrate của rig (H/s)",
    "coins.hashrateHint":
      "Dùng cho mọi đồng không có số riêng. Tổng hashrate của fleet tự điền khi có máy ở trên.",
    "coins.prices": "Lấy giá (CoinGecko)",
    "coins.pricesLoading": "Đang hỏi CoinGecko…",
    "coins.pricesOk": "Đã cập nhật {n} giá từ CoinGecko.",
    "coins.pricesError":
      "CoinGecko không trả lời — mất mạng, bị chặn hoặc bị giới hạn tần suất. Giá giữ nguyên; cần thì tự nhập.",
    "coins.pricesHint":
      "Không có gì được tải cho tới khi bạn bấm nút này, nên trang chạy được cả khi offline và không request nào rời trình duyệt trước đó.",
    "coins.best": "Coin tốt nhất ở hashrate này",
    "coins.bestLine":
      "{coin} trả khoảng {revenue} mỗi ngày cho {hashrate} — {coinDay} {symbol}.",
    "coins.bestEmpty":
      "Chưa đồng nào có đủ số, nên không có gì để giới thiệu một cách trung thực. Nhập hashrate của rig, rồi phần thưởng, thời gian block và hashrate mạng cho một đồng ở dưới.",
    "coins.build": "Tạo lệnh cho {coin}",
    "coins.tableCoin": "Đồng",
    "coins.tableRevenue": "Doanh thu/ngày",
    "coins.tableCoinDay": "Coin/ngày",
    "coins.tableStatus": "Số liệu",
    "coins.ready": "đủ",
    "coins.needs": "thiếu {fields}",
    "coins.edit": "Số đang dùng",
    "coins.fieldReward": "Thưởng mỗi block",
    "coins.fieldBlockTime": "Thời gian block (giây)",
    "coins.fieldNetwork": "Hashrate mạng (H/s)",
    "coins.fieldPrice": "Giá (USD)",
    "coins.fieldRig": "Rig này (H/s)",
    "coins.reset": "Xoá số tôi đã nhập",
    "coins.note":
      "Mọi ô là của bạn. Đồng còn thiếu số sẽ hiện lý do không xếp hạng được thay vì số 0 trông như câu trả lời, và không endpoint pool nào bị bịa ra cho đồng mà repo này không biết.",
    "coins.source":
      "Phần thưởng, thời gian block và hashrate mạng lấy từ explorer của chính đồng đó; giá từ CoinGecko khi bạn yêu cầu. Các số ở lại trong trình duyệt này.",
    "coins.missingReward": "phần thưởng",
    "coins.missingBlockTime": "thời gian block",
    "coins.missingNetwork": "hashrate mạng",
    "coins.missingPrice": "giá",
    "coins.missingHashrate": "hashrate rig",

    "pooltable.pool": "Pool",
    "pooltable.fee": "Phí",
    "pooltable.min": "Trả tối thiểu",
    "pooltable.endpoint": "Endpoint",
    "pooltable.tls": "TLS trên 443",
    "pooltable.note": "Vì sao",
    "pooltable.no": "không",
    "pooltable.checked": "Phí và minimum kiểm tra tháng 10/2026.",

    "common.manualCopy": "Nhấn Ctrl+C",
  },
};

/** Translate a key, filling {placeholders}. Unknown keys return the key. */
export function translate(locale, key, params) {
  const table = messages[locale] || messages.en;
  const template = table[key] ?? messages.en[key] ?? key;
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name) =>
    Object.prototype.hasOwnProperty.call(params, name)
      ? String(params[name])
      : whole,
  );
}
