---
title: Kiểm thử
description: Các bộ test trong repo, mỗi bộ chứng minh điều gì, chạy mất bao lâu, và những lỗi thường là do máy chứ không phải do mã.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Kiểm thử

Mọi bộ test ở đây chạy được mà không cần pool thật, và không bộ nào cần ví.

## Engine hash

```bash
./zmrig/out/zmrig --self-test          # đầy đủ: cần 2 GiB RAM
./zmrig/out/zmrig --self-test=light    # bỏ qua kiểm tra dataset
./zmrig/tests/run.sh                   # self-test cộng kiểm tra API
```

`--self-test` kiểm tra vector tham chiếu `rx/0`, hashing có pipelining, và việc
dataset dựng từ cache cho cùng kết quả với bản dựng full-memory. `oneclick.sh
verify` gọi nó trước khi kiểm tra phí.

## Watchdog, hai case với pool thật

`zmrig/tests/health.sh` chạy miner với pool giả hai lần, để chứng minh cả hai
chiều:

| Case | Kỳ vọng |
| --- | --- |
| Pool tử tế | health ở `ok`, không ghi lỗi, không tự khởi động lại |
| Pool từ chối mọi share | health thành `rejected`, process thoát **mã 3** để systemd khởi động lại, và log nói cách tắt |

Cộng bảy unit test cho máy trạng thái (`health.zig`): tạm dừng không phải lỗi,
một hai share stale là bình thường, và một cú tụt phải kéo dài mới tính là
`degraded`.

## Bộ test mạng — 29 case

Nó dựng pool giả, TLS shim, proxy HTTP và SOCKS5 và server WebSocket ngay trên
máy, rồi bắt miner nói chuyện với tất cả:

```bash
./zmrig/tests/net.sh --quick      # 10 s mỗi case
./zmrig/tests/net.sh              # 18 s mỗi case
./zmrig/tests/net.sh --soak       # thêm soak 4 phút
./zmrig/tests/net.sh --only api,tcp
```

| Nhóm | Case | Chứng minh |
| --- | --- | --- |
| Transport | `tcp`, `tls`, `ws`, `wss` | login, job, submit share |
| | `ws path` | server nhận đúng `/miner` |
| | `wss via socks5` | WebSocket qua TLS xuyên SOCKS5 |
| CDN | `cloudflare` | `wss` trên 443 với header `Host` đúng |
| Proxy | `http proxy`, `socks5 proxy` | `CONNECT` và auth tới đúng đích |
| API | `http api`, `http api token`, `http api 404` | summary, ép token, đường dẫn lạ |
| Lỗi | `login rejected`, `idle watchdog`, `pool failover` | lỗi hiện ra; reconnect và failover chạy |
| | `hostile pool` | rác không ngăn được việc submit share |
| Seed | `seed change` | bốn lần dựng lại dataset, vẫn đào tiếp |
| Soak | `soak` | 4 phút đổi seed, đổi thuật toán và rớt mạng |

Một lần chạy đầy đủ mất 12–15 phút trên 2 vCPU, vì mỗi case phải sinh một share
và bộ test chạy `--mode light` (50–70 H/s). Lần chạy gần nhất trên máy đó:

```text
29 passed, 0 failed, 0 skipped
```

Log từng case nằm trong `/tmp/zmrig-net.XXXXXX/`, in ra ở cuối. Khi một case
fail, đọc log của case đó trước (`cloudflare.log`, `shim-cf.log`, `pool.log`).

### Bẫy

- **Cổng.** Bộ test dùng 4800 cho pool và 4801–4813 cho shim. Một process còn
  giữ 4800 làm case `cloudflare` fail với `accepted=0` trong khi log miner ghi
  `login ok`. Script giết process lạ và từ chối chạy nếu cổng bị chiếm.
- **Tải CPU.** Đừng chạy benchmark song song — sẽ OOM hoặc làm hỏng số đo.
- **Huge pages.** Chế độ `light` nghĩa là không cần đặt 2 GiB; 50–70 H/s là bình
  thường, không phải thoái hoá.

## Kiểm tra phí

```bash
sudo ./oneclick.sh verify
```

Với engine Zig, nó chạy self-test rồi `scripts/verify-fee.sh`: đọc mức phí, địa
chỉ ví và công tắc `--donate-level=0` từ binary, fail nếu xuất hiện ví thứ hai
hay endpoint donate của upstream. Với engine C++, nó chạy
`scripts/verify-fee-free.sh`, script này kiểm tra thêm việc binary in `DONATE 0%`
khi bị truyền `--donate-level=9`.

Phần kiểm tra grep **endpoint và địa chỉ**, không grep chữ `donate`: API giám sát
trả `"donate_level": 0` một cách hợp pháp, và một lệnh grep ngây thơ sẽ báo động
giả. Chuyện đó đã từng xảy ra, và đã sửa.

## Bộ test API, CLI và cấu hình

```bash
./zmrig/tests/cli.sh      # phân tích cờ, văn bản help, mã thoát
./zmrig/tests/unit.sh     # unit test các module Zig
node --test pool/tests/*.test.js
bash tests/oneclick/plan.sh && bash tests/oneclick/config.sh && bash tests/oneclick/governor.sh
```

`plan.sh` là bộ quan trọng nhất sau mỗi lần sửa installer: nó khẳng định đúng
lệnh mà người dùng sẽ chép cho hàng chục tổ hợp cờ.

## Trang web

```bash
cd site && npm test      # unit test cho máy tính và bộ dựng lệnh
cd site && npm run build # lỗi nếu có link nội bộ hỏng hoặc component sai
```

Phần kiểm tra link là điểm chính của `npm run build`: `onBrokenLinks` và
`onBrokenMarkdownLinks` đều đặt `throw`, nên một trang bị đổi tên không thể phát
hành thành 404.

## Container, không cần daemon

```bash
node --test 'deploy/docker/tests/*.test.js'
sh -n deploy/docker/zmrig-docker-update
```

Mọi quyết định của image đều là hàm thuần của môi trường, nên container được test
mà không cần Docker: ánh xạ biến môi trường sang cờ (bốn chế độ, mức donate 11 %
bị từ chối, `EXTRA_ARGS` không bao giờ đi qua shell), hạn mức cgroup chặn số luồng
ở cả hai phiên bản cgroup, bộ kiểm tra registry chạy với một registry giả đòi
token, và script cập nhật trên host chạy với `docker` giả — đang mới thì không
pull, pull hỏng thì không dựng lại.

Bản thân image được CI dựng ở mỗi pull request (`Published image`), vì lỗi ở đó
chỉ image thật mới lộ ra: thiếu `lib/`, một nhãn không được đặt, entrypoint không
chuyển tiếp SIGTERM.

## Chạy test trên máy đang đào

Bộ test mạng dùng cổng riêng và pool giả, nên không đụng miner thật. Nhưng nếu
miner thật đang giữ huge pages, `--self-test` bản đầy đủ có thể không đủ RAM cho
dataset — dùng `--self-test=light`, hoặc `sudo ./oneclick.sh stop` trước.
