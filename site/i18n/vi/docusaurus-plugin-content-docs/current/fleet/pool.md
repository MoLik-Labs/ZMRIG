---
title: Tự dựng pool
description: Một pool Monero bằng Node.js không dependency — phí 1 % đổi lấy gì, chạy thử trong năm phút, các lựa chọn hosting miễn phí, và quy tắc vận hành.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Tự dựng pool

Repo này có cả hai phía: miner (`zmrig`, `xmrig`) và một pool Monero viết bằng
Node.js, không dependency, nằm trong `pool/`. Dựng pool riêng nghĩa là phí pool ở
lại với bạn thay vì trả cho người khác — và miner của bạn trỏ vào đó chạy y như
mọi pool khác.

## Phí 1 %, và nó đổi lấy gì

| Khoản | Giá trị |
| --- | --- |
| Phí pool | **1.0 %** mỗi block, trừ trước khi chia, làm tròn **xuống** |
| Phí ẩn | không có |
| Phí developer của miner | 3 % thời gian đào Monero ở engine Zig (`--donate-level=0` để tắt); engine C++ không lấy gì |
| Ngưỡng trả | 0.01 XMR, cộng phí mạng |

Phí hiện ngay trong reply `login` mà miner in ra, trong `/api/config` và trên
trang trạng thái. Vì sao 1 %: các pool Monero lớn đang ở 0.6–1 %, và pool này làm
thêm một việc phần lớn pool không làm — **băm lại từng share** bằng
`zmrig --verify-share` trước khi trả tiền. Việc đó tốn CPU thật của người vận
hành, và là thứ duy nhất khiến miner biết chắc không ai được trả cho công việc
không làm.

## Chạy thử trong năm phút

```bash
# 1. một node Monero (testnet cũng được khi mới dựng)
monerod --data-dir ~/.bitmonero --rpc-bind-ip 127.0.0.1 --confirm-external-bind

# 2. pool
cd pool
node src/index.js --check --config config.json   # kiểm tra cấu hình rồi thoát
node src/index.js --config config.json           # stratum + HTTP

# 3. miner, ở terminal khác
zmrig -o 127.0.0.1:3333 -u 4YourMoneroAddress.rig1 -t 4
```

`http://127.0.0.1:8080/` là trang trạng thái; `curl -s 127.0.0.1:8080/api/stats`
trả cùng số đó ở dạng JSON.

## Cần gì

- **Node.js ≥ 18.17** — không `npm install`, không database.
- **`monerod`** với JSON-RPC truy cập được.
- **`zmrig` trong `PATH`** để băm lại share. Không có nó, pool từ chối share thay
  vì tin mù:

  ```bash
  ./zmrig/build.sh --jobs 2
  sudo install -m 0755 zmrig/out/zmrig /usr/local/bin/zmrig
  ```

## Chia thưởng và bằng chứng

- Share chỉ được nhận khi hash do pool tự tính trùng với hash miner gửi. Hash sai
  không chỉ bị từ chối: kết nối bị đóng.
- Trọng số share là **độ khó × thời gian**, không phải số share — máy chậm không
  bị phạt, chia một rig thành ba không được trả đôi.
- Mỗi block được ghi vào `audit.jsonl`: thưởng, phí, từng khoản trả cho miner, và
  phần lẻ (dust) ghi thành dòng riêng thay vì lặng lẽ cộng vào phí.

```bash
curl -s 127.0.0.1:8080/api/audit?limit=5 | python3 -m json.tool
curl -s 127.0.0.1:8080/api/worker/4YourMoneroAddress
```

## Hosting miễn phí

Blueprint ở gốc repo deploy **fleet và tài liệu** — bot, các lần báo danh và các
trang trên một cổng — không phải pool này. Một workspace free chỉ được **750 instance-hours mỗi tháng** cho tất cả
các service cộng lại, và một service chạy 24/7 đã dùng khoảng 744 giờ; thêm một
service nữa là vượt hạn mức và Render treo các service free tới tháng sau. Vì thế
blueprint của pool nằm ở `deploy/render-pool.yaml`: áp nó vào một workspace khác,
hoặc vào chính workspace này nếu bot không chạy ở đây.

| Nơi | Cách chạy | Ghi chú |
| --- | --- | --- |
| Render | `deploy/render-pool.yaml` (Docker) | một cổng, chỉ WebSocket; instance free ngủ sau 15 phút không có traffic |
| Fly.io | `fly.toml` + volume 1 GB | có TCP thật ở 3333; `monerod` không vừa máy 256 MB |
| Cloudflare Workers | `pool/worker/` | cầu WebSocket ⇄ TCP, không cần Durable Object |
| Vercel | chỉ trang tĩnh | function không giữ được kết nối stratum |

```bash
fly launch --no-deploy --copy-config --dockerfile deploy/Dockerfile
fly volumes create pool_data --size 1
fly secrets set DAEMON=https://node.example:18081
fly deploy
```

Trỏ miner vào qua WebSocket (cần engine `zmrig`), hoặc qua TCP khi host mở cổng
3333:

```bash
zmrig -o wss://pool.example.com/stratum -u 4YourMoneroAddress.rig1 -t 4
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress.rig1 -t 4
```

## Vận hành

- Giữ `state_file` trên volume. Không có nó, restart là mất số dư của mọi miner.
- `/metrics` xuất Prometheus; `/healthz` trả 503 cho tới khi có template từ
  `monerod`.
- Log audit chỉ ghi thêm — xoay vòng bằng `logrotate`, đừng sửa.
- Đổi ví phí bằng `OPERATOR_ADDRESS`; mặc định nằm trong `pool/src/operator.js`.
  Địa chỉ được giải mã lúc khởi động (base58, byte mạng, checksum Keccak-256),
  không chỉ so hình dạng: sai một ký tự vẫn "trông giống" địa chỉ, mà ví phí thì
  không bao giờ đăng nhập nên không chỗ nào khác phát hiện được.
- `--check` từ chối cấu hình không thể trả đúng: phí ngoài 0–10 %, mode lạ, cửa
  sổ PPLNS quá ngắn, ví phí không giải mã được.
- Mỗi share đều được pool băm lại trước khi trả (`verify_shares`), dùng một tiến
  trình `zmrig --verify-share` sống lâu cho mỗi core để cache 256 MB chỉ dựng một
  lần mỗi round. `pool/tests/bench-verify.mjs` đo trên chính máy bạn; trên một
  máy thử 2 vCPU với hai verifier và 200 share mỗi round: share đầu 0,58 s (dựng
  cache), trạng thái ổn định **39 share/giây** — một rig 1 kH/s ở độ khó 300 gửi
  khoảng 3,3 share/giây, nên máy đó verify được chừng một tá rig.
- `VERIFIER_MODE=fast` dựng dataset 2 GiB một lần rồi đọc lại cho từng share:
  **2,9 ms một share thay vì 22 ms** (349 share/giây mỗi verifier), đo trên cùng
  máy đó, đổi lại 2336 MB RAM *cho mỗi tiến trình verifier* và 21 s khởi động.
  Đây là lựa chọn phải bật, và pool cộng số đó với `/proc/meminfo` lúc khởi động
  — `fast` với hai verifier mặc định là 4,6 GiB, một VPS 4 GB không có. Verifier
  không lấy được dataset sẽ tự lùi về cache nhẹ và ghi lý do vào log. Bảng đầy đủ
  nằm trong `pool/README.md`.
- Muốn verify nhiều share cùng lúc thì dùng `VERIFIER_THREADS` (nhiều thread
  trong một tiến trình, chung một dataset) chứ không phải `VERIFIER_CONCURRENCY`
  (nhiều tiến trình, mỗi tiến trình một dataset). Đo khi đã ấm trên cùng máy đó:
  một tiến trình hai thread được **87 share/giây ở chế độ light và 626 ở fast**,
  so với 74 share/giây và hoá đơn 4,6 GiB nếu chạy hai tiến trình.
- `/stratum` là mặt tiếp xúc internet, nên khung truyền có giới hạn: khung quá
  1 MiB thì đóng kết nối, **tin nhắn** quá 256 KiB cũng vậy (chỉ giới hạn từng
  khung thì client vẫn gửi khung nối tiếp mãi được), và một khung dữ liệu thứ hai
  xuất hiện khi tin nhắn còn mở là lỗi giao thức.

Payout qua `monero-wallet-rpc`, API và các lưu ý bảo mật nằm trong
`pool/README.md`; những bước bạn phải tự chạy khi deploy ở
[`doc/SETUP.md`](https://github.com/MoLik-Labs/ZMRIG/blob/master/doc/SETUP.md).
