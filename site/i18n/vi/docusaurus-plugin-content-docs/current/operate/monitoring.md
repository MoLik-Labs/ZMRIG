---
title: Giám sát
description: API HTTP chỉ đọc, watchdog sức khoẻ, và mã báo cáo ZMRIG1. — mỗi thứ cho bạn gì và dùng khi nào.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Giám sát

Hai cách lấy số liệu ra khỏi miner:

| | API HTTP | Mã báo cáo |
| --- | --- | --- |
| Dùng khi | máy nằm trong mạng của bạn hoặc qua VPN, hoặc script cần đọc | máy nằm sau NAT, hoặc bạn muốn con số vào bảng tính |
| Bảo mật | bind `127.0.0.1`, Bearer token tuỳ chọn | không mở cổng; bạn tự chép mã |
| Dữ liệu | mọi thứ, cập nhật mỗi giây | ảnh chụp tại thời điểm ghi |
| Nhiều máy | mỗi máy một endpoint | dán nhiều mã cùng lúc |

## API HTTP

Bật bằng `--http-port`; installer bật ở 18080.

```bash
curl -s 127.0.0.1:18080/1/summary
curl -s 127.0.0.1:18080/2/summary | python3 -m json.tool
```

| Đường dẫn | Nội dung |
| --- | --- |
| `/1/summary`, `/summary` | JSON một dòng gọn, cùng hình dạng XMRig |
| `/1/status` | trạng thái kết nối |
| `/2/summary`, `/2/status` | cùng dữ liệu, in đẹp |
| `/json_rpc` | như `/1/summary`, cho client cũ |

```bash
zmrig ... --http-port 18080 --http-access-token "$TOKEN"
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:18080/1/summary
```

Thiếu token trả `401` kèm JSON, đường dẫn lạ trả `404` kèm JSON, `HEAD` chạy
được cho health check, và mọi response đều có `Cache-Control: no-store`.

```json
{"id":"zmrig","worker_id":"vps-sg-02","uptime":3600,"version":"6.32.1",
 "kind":"miner","ua":"zmrig/6.32.1","algo":"rx/0","paused":false,
 "donate_level":0,
 "connection":{"pool":"wss://relay.example.com:443","uptime":3600,"failures":0,"tls":true},
 "hashrate":{"total":[814.2,810.5,805.1],"highest":902.7},
 "hugepages":[1168,1168],"cpu":{"threads":2},
 "results":{"shares_good":42,"shares_total":42,"hashes_total":2931842,"error_log":[]}}
```

API là **chỉ đọc**: không có endpoint nào đổi ví hay khởi động lại thứ gì. Dù
vậy, đừng bind vào `0.0.0.0` khi không có token và firewall — nó để lộ tên
worker, pool và địa chỉ của bạn.

## Sức khoẻ: còn chạy, hay còn kiếm ra tiền?

Đó là câu hỏi khác với "service còn active không", và là chỗ tiền biến mất lặng
lẽ: pool từ chối mọi share để lại một miner vẫn chạy, vẫn kết nối, vẫn in
hashrate, và không kiếm được gì.

Miner tự đánh giá mỗi giây và báo một trong năm trạng thái:

| Trạng thái | Nghĩa | Chuyện gì xảy ra |
| --- | --- | --- |
| `warming` | đang dựng dataset, hoặc bị tạm dừng | không gì cả (tạm dừng là tính năng) |
| `ok` | hashrate gần mức tốt nhất phiên này, share được nhận | không gì cả |
| `degraded` | dưới 80 % đỉnh 10 phút (nóng, máy khác tranh CPU) | cảnh báo |
| `stalled` | process còn sống nhưng không hash | lỗi |
| `rejected` | đã gửi share và không share nào được nhận | lỗi |

```bash
sudo ./oneclick.sh status
#   hashrate: 1042.6 H/s (10s/60s/15m)
#   shares:   184/0/0 accepted
#   health:   ok
```

`stalled` hoặc `rejected` kéo dài **15 phút** làm process thoát với mã 3, và
`Restart=always` biến nó thành một lần khởi động sạch. Đánh đổi rất rõ: mất 16–30
giây hashrate thay vì hàng giờ kiếm số không.

```bash
zmrig ... --no-health-restart     # không bao giờ tự thoát
zmrig ... --health-restart=1800   # chờ lâu hơn trước khi bỏ (giây)
zmrig ... --health-warmup=300     # bỏ qua 5 phút đầu
```

Trạng thái này cũng nằm trong trường `health` của mã báo cáo, nên một bảng fleet
hiện được những máy đang chạy mà không kiếm ra gì.

## Mã báo cáo

Một lần đo, một dòng:

```bash
$ sudo ./oneclick.sh report --power 45
ZMRIG1.eyJ2IjoxLCJpZCI6InZwc…     # khoảng 380–520 ký tự
```

Mất 25–30 giây: 15–20 s dựng dataset, 10 s warm-up, 15 s đo, rồi lấy mẫu công
suất. `oneclick.sh report` dừng service trước — miner đang chạy giữ huge pages,
dataset thứ hai không vừa.

| Trường | Ý nghĩa |
| --- | --- |
| `id`, `cpu`, `cores`, `thr` | tên máy, model CPU, core vật lý, thread đào |
| `algo`, `mode` | thuật toán, `auto`/`fast`/`light` |
| `hs[0..3]` | hashrate 10 s, 60 s, 15 phút, tốt nhất phiên |
| `hp` | huge pages được cấp / cần |
| `shares`, `hash`, `up` | nhận, từ chối, lỗi; tổng hash; uptime (giây) |
| `pw`, `pwsrc` | watt và nguồn: `rapl`/`hwmon` (package CPU), `user` (ổ đo), `none` |
| `pool`, `ts`, `ver` | pool, thời điểm, phiên bản miner |

Mã **không chứa địa chỉ ví, không token pool, không IP công khai**. Nó là JSON
mã hoá base64url và bạn tự đọc được:

```bash
cut -d. -f2 report.txt | tr '_-' '/+' | base64 -d | python3 -m json.tool
```

Trong lúc đào, để miner tự cập nhật file:

```bash
--report-file /var/lib/zmrig/report.txt --report-interval 60
```

Installer bật sẵn cho engine `zmrig`, nên sau đó chỉ cần `sudo cat
/var/lib/zmrig/report.txt`.

## Từ một mã đến cả fleet

1. Cho mỗi máy một `--report-id` riêng (hoặc `--rig-id`).
2. Để miner ghi file báo cáo.
3. Dán các mã vào [máy tính lợi nhuận](/docs/economics/profitability), mỗi dòng
   một mã.
4. Máy tính cộng hashrate, watt, kWh, tiền điện, doanh thu và lợi nhuận, và xuất
   được JSON.

Không có server trung gian nào. Muốn giám sát 24/7 thì scrape API vào Prometheus
hoặc Netdata qua VPN của bạn; đừng mở nó ra internet.
