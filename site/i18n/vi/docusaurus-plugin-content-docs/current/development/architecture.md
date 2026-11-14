---
title: Kiến trúc
description: Ba engine, bản đồ module của miner Zig, đường đi của một job từ pool tới CPU và ngược lại, và những thread tồn tại lúc chạy.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Kiến trúc

Cây mã này có ba engine đào thay thế được cho nhau, sau một installer, một file
config và một API HTTP:

| Engine | Đường dẫn | Ngôn ngữ | Vì sao có |
| --- | --- | --- | --- |
| `zmrig` | `zmrig/` | Zig | mặc định: một binary, không phụ thuộc runtime, cùng mã RandomX |
| `xmrig` | `src/` | C++ | bản tham chiếu, GPL-3.0, phủ thuật toán và phần cứng rộng nhất |
| `proxy` | `proxy/` | Node.js | đầu tiên của farm; không băm, chỉ định tuyến |

`/etc/zmrig/engine` ghi engine mà installer đã chọn, nên mọi lệnh `oneclick.sh`
sau đó tác động đúng engine mà không cần nói lại.

## Engine Zig

```text
zmrig/src/
├── main.zig        khởi động, signal, vòng đào, ghi báo cáo
├── options.zig     toàn bộ CLI, phân tích config và kiểm tra hợp lệ
├── stratum.zig     login, phân tích job, submit share, từ chối, cooldown
├── transport.zig   TCP, TLS, WebSocket, proxy SOCKS5/HTTP, DNS
├── job.zig         ghép blob, xử lý extranonce, so sánh target
├── miner.zig       thread pool, chia nonce, cửa sổ hashrate, đếm share
├── api.zig         tài liệu JSON cho API HTTP
├── api_http.zig    bản thân server HTTP
├── report.zig      mã báo cáo ZMRIG1.
├── health.zig      máy trạng thái của watchdog
├── hugepages.zig   đặt trước và kiểm tra trang 2 MiB
├── topology.zig    phát hiện core, chia sẻ cache, đặt thread
├── autotune.zig    chọn số thread và affinity cho host
├── verify.zig      băm lại share cho người vận hành pool
├── log.zig         định dạng log, mức và thời gian
└── util.zig        base64, hex, thời gian, helper nhỏ
```

Không link gì ngoài libc. Không allocator trong vòng hash, không GC nền, và không
dependency nào có thể đổi hành vi giữa các lần build.

## Chuyện gì xảy ra lúc khởi động

1. Phân tích cờ, rồi `config.json`, rồi file marker engine — theo đúng thứ tự đó,
   nên cờ trên dòng lệnh luôn thắng.
2. Phát hiện CPU: core, SIB của SMT, kích thước L3, node NUMA.
3. Đặt trước huge pages; nếu thất bại, ghi đúng lệnh có thể sửa vào log và chạy
   tiếp thay vì từ chối khởi động.
4. Dựng cache RandomX (256 MiB) và, ở chế độ fast, dataset (2 GiB). Đây là chi
   phí khởi động 15–25 s; chế độ `light` bỏ qua dataset.
5. Khởi động các thread worker với affinity do `autotune.zig` chọn.
6. Mở kết nối stratum: DNS, transport, login, job đầu tiên.
7. Khởi động API HTTP (mặc định `127.0.0.1:18080`) và, nếu được yêu cầu, phần ghi
   file báo cáo.

## Đường nóng

Một job đến dưới dạng blob 76 byte kèm target. Miner ghi nonce vào byte 39–43,
băm, so kết quả với target, và khi trúng thì gửi `submit` lên pool. Không có gì
trên đường đó cấp phát bộ nhớ, và không có gì khoá: mỗi thread sở hữu một lát liền
mạch của không gian nonce 32 bit, và vị trí của nó tiến theo bước sao cho hai
thread không bao giờ đụng nhau.

Scratchpad nằm trong huge pages suốt phiên chạy. Đó là khác biệt giữa 814 H/s và
634 H/s trên máy tham chiếu — xem [Hiệu năng đo được](/docs/reference/benchmarks).

## Proxy

`proxy/src/` là một đường ống nhỏ: `server.js` nhận kết nối từ rig,
`downstream.js` mô hình hoá từng rig, `extranonce.js` cấp prefix, `vardiff.js` đặt
độ khó mỗi rig, `target.js` so sánh hash, `upstream.js` giữ kết nối pool duy nhất,
`tunnel.js` xử lý WireGuard/Tailscale/Cloudflare, và `access.js` áp luật CIDR và
token. `blob.js` là nơi duy nhất biết bố cục một job Monero — đọc file đó trước.

## Pool

`pool/src/` nhận share, băm lại từng share bằng `zmrig --verify-share`, giữ trọng
số PPLNS là độ khó × thời gian, và ghi mọi block vào `audit.jsonl`. Payout đi qua
`monero-wallet-rpc`. `pool/worker/` là một Cloudflare Worker bắc cầu WebSocket
sang TCP để pool chạy được trên nền tảng chỉ nói HTTP.

## Tìm X ở đâu

| Câu hỏi | File |
| --- | --- |
| Vì sao kết nối lỗi? | `zmrig/src/stratum.zig`, `zmrig/src/transport.zig` |
| Vì sao số thread này? | `zmrig/src/autotune.zig`, `zmrig/src/topology.zig` |
| Vì sao hashrate thấp? | `zmrig/src/miner.zig`, `zmrig/src/hugepages.zig` |
| Trường API này nghĩa gì? | `zmrig/src/api.zig` |
| Vì sao service restart? | `zmrig/src/health.zig` |
| Vì sao rig không được trả tiền? | `pool/src/`, rồi `audit.jsonl` |
| Vì sao rig không submit? | `proxy/src/vardiff.js`, `proxy/src/target.js` |

Bản đồ C++ dài hơn — mọi thư mục trong `src/`, danh sách thread và pipeline
RandomX — nằm ở
[`doc/ARCHITECTURE.md`](https://github.com/MoLik-Labs/ZMRIG/blob/master/doc/ARCHITECTURE.md).
