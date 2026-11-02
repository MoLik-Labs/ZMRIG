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
| Phí developer của miner | 1 % thời gian đào Monero ở engine Zig (`--donate-level=0` để tắt); engine C++ không lấy gì |
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

| Nơi | Cách chạy | Ghi chú |
| --- | --- | --- |
| Render | `render.yaml` (Docker) | một cổng, chỉ WebSocket; instance free ngủ sau 15 phút không có traffic |
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
- `--check` từ chối cấu hình không thể trả đúng: phí ngoài 0–10 %, mode lạ, cửa
  sổ PPLNS quá ngắn.

Payout qua `monero-wallet-rpc`, API và các lưu ý bảo mật nằm trong
`pool/README.md`; những bước bạn phải tự chạy khi deploy ở
[`doc/SETUP.md`](https://github.com/MoLik-Labs/ZMRIG/blob/master/doc/SETUP.md).
