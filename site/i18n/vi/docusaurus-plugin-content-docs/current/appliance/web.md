---
title: Một service duy nhất — trang web, phần tải về và đội máy
description: Một tiến trình Node trả lời ba loại client — người đọc tài liệu, máy đào báo danh mỗi phút, và bot Telegram/Discord — trên một cổng, không phụ thuộc gì, không có bước build.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Một service duy nhất — trang web, phần tải về và đội máy

GitHub Pages đang phục vụ tài liệu này và GitHub phục vụ các file ISO, nên phần
này không bắt buộc. `host/` tồn tại vì bốn thứ tiện hơn khi nằm trên host của bạn:
một link không đổi khi phiên bản đổi, một trang tải về luôn liệt kê đúng file hiện
tại kèm checksum, một site chạy được ở nơi GitHub bị chặn hoặc chậm, và một chỗ để
đội máy đào báo danh.

Đó là một tiến trình Node, một cổng, không phụ thuộc gì, không có bước build:

| ai | hỏi gì | ai trả lời |
| --- | --- | --- |
| người đọc | `/`, `/vi/`, `/download`, `/iso/v3`, `/api/releases.json` | bản build đã commit trong `web/` |
| máy đào | `POST /v1/hello`, mỗi máy một lần một phút | giao thức thiết bị |
| các bot | không hỏi gì — chúng tự gọi ra Telegram và Discord | hai vòng long-poll |

## Vì sao một tiến trình chứ không phải ba

Một workspace Render free chỉ được **750 instance-hours mỗi tháng**, dùng chung
cho mọi service free, không cộng dồn. Tháng 31 ngày là 744 giờ, nên chỉ vừa đúng
một service chạy 24/7; service thứ hai sẽ vượt hạn mức và Render treo các service
free cho tới tháng sau. Đó không phải hóa đơn, đó là một lần sập.

Mọi thứ nằm gọn trong một tiến trình vì mọi thứ đều nhỏ: trang web là một thư mục
đọc vào bộ nhớ, giao thức thiết bị là một handler `POST`, và các bot là hai vòng
lặp. Tách chúng ra sẽ làm đội máy mất tháng free duy nhất.

Trong repository thì ba phần vẫn tách nhau, nên mỗi phần chạy và được kiểm thử
riêng:

```bash
node host/server.js    # cả ba, một cổng   <- thứ Render khởi động
cd serve && npm start  # chỉ trang web và phần tải về
cd fleet && npm start  # các bot, các máy đào và dashboard trên trình duyệt
```

## Chạy thử

```bash
node host/server.js             # http://localhost:8080
```

Các trang đến từ `web/`, bản build đã commit của `site/`. Nó được tạo lại một cách
có chủ ý, không bao giờ bởi lúc deploy:

```bash
npm run publish:site            # build site/ rồi thay web/
```

Mọi thiết lập là biến môi trường có mặc định, nên môi trường rỗng vẫn là một cấu
hình chạy được: `PORT`, `SITE_ROOT`, `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`,
`FLEET_ADMIN_IDS`, `FLEET_ROSTER`, `FLEET_PUBLIC_URL`, `GITHUB_REPO`,
`RELEASES_TTL`. Không có token và không có roster thì nó vẫn khởi động: phục vụ tài
liệu, nhận báo danh, và ghi vào log rằng chưa nối bot nào. Chỉ `PORT` sai mới làm
nó dừng.

## Nó trả lời những gì

| đường dẫn | |
| --- | --- |
| `/` | tài liệu, tiếng Anh |
| `/vi/` | tài liệu, tiếng Việt |
| `/download` | bản stable và beta kèm dung lượng, checksum, lệnh `dd` và `sha256sum` |
| `/api/releases.json` | đúng dữ liệu đó cho script |
| `/iso/v3` `.../v2` `.../beta` | 302 tới file mới nhất của kênh đó |
| `/healthz` | một câu trả lời cho cả ba công việc |
| `POST /v1/hello` | giao thức thiết bị: `401` khi không có key, `405` với `GET` |

```bash
curl -L -O https://your-host/iso/v3     # luôn là bản v3 mới nhất
```

Và script tải về có thể hỏi chính service này thay vì GitHub — đó mới là điểm
đáng giá trên mạng lưới chặn `api.github.com`:

```bash
./scripts/latest-iso.sh --host https://your-host          # bản stable mới nhất
./scripts/latest-iso.sh --host https://your-host --beta   # bản beta cuốn chiếu
```

`/iso/*` đọc feed releases đã cache, nên một lần chuyển hướng chỉ là tra Map rồi
trả `302`. Đó là toàn bộ ý tưởng: một script, một menu Ventoy hay một tờ giấy ghi
chú có thể dùng đúng một URL suốt cả năm.

`/healthz` báo cáo cả ba công việc, nên một lần deploy làm mất một trong số đó sẽ
lộ ra từ bên ngoài, chứ không phải từ người dùng:

```json
{"ok":true,"bots":{"telegram":true,"discord":false},
 "fleet":{"rigs":3,"known":4},
 "site":{"root":"/opt/render/project/src/web","files":244},
 "uptime_s":3600,"rss_mb":64}
```

Host này không có dashboard. Cửa chính là tài liệu, và hai bề mặt HTML trên cùng
một origin là một bề mặt quá nhiều để giữ an toàn; `cd fleet && npm start` mang
dashboard trở lại, kèm `FLEET_WEB_PASSWORD` và CSRF trên mọi form.

## Triển khai trên Render

`render.yaml` là blueprint: một service, `node host/server.js`, health check
`/healthz`.
[Nút deploy](https://render.com/deploy?repo=https://github.com/MoLik-Labs/ZMRIG)
đọc đúng file đó; *New → Blueprint* rồi chọn repository là cùng một việc.

Không có bước build. `web/` đã được commit, nên một lần deploy không cài gì, không
tốn phút build, và không thể hỏng vì một thư viện tài liệu vừa phát hành bản lỗi.

Pool không nằm trong blueprint đó: nó chỉ cần khi có người đang đào, và
`deploy/render-pool.yaml` dành cho ai muốn chạy nó thay vào. Áp cả hai vào cùng một
workspace chính là cách làm cạn tháng free.

Không có gì trong đó là bí mật, trừ những giá trị Render hỏi một lần. API GitHub
được đọc ẩn danh và feed cache mười phút — tối đa 60 lần gọi mỗi giờ, thừa xa giới
hạn. Có đội máy báo danh mỗi phút thì service không bao giờ ngủ; với đội máy rỗng,
trỏ một uptime monitor miễn phí vào `/healthz` mỗi năm phút.

## Vì sao nó nhanh

Mọi thứ site phục vụ được đọc vào bộ nhớ một lần, lúc khởi động: 244 route,
6,84 MB, trong 17 ms. Sau đó một request là một lần tra Map và một lần `end()`.

- không `stat`, không `open`, không `readdir` cho từng request;
- Brotli và gzip được tạo **ở lần đầu có người hỏi file đó**, không phải lúc khởi
  động — nén cả một site bằng brotli trên một phần mười CPU mà instance free có
  chính là thứ biến một lần deploy thành một health check thất bại. Trình duyệt
  nhận Brotli thì không hề sinh ra bản gzip nào;
- mức nén theo dung lượng (11 tới 32 KB, 9 tới 256 KB, 6 ở trên), vì chi phí của
  brotli tăng nhanh hơn nhiều so với lợi ích;
- những trang dễ được mở đầu tiên được nén ngay sau khi socket mở, mỗi lượt một
  file, giữa các request;
- `ETag` trên mọi response, và request có điều kiện được trả `304` trước khi chạm
  vào body;
- asset có hash trong tên thì `immutable` một năm, HTML thì xác thực lại;
- một kết nối giữ mở 65 giây, nên một trang và các asset của nó dùng chung;
- feed releases lấy mỗi mười phút một lần, không phải mỗi lượt truy cập;
- bản nén cũ hơn file gốc bị bỏ qua, nên một file nén sót lại từ lần build trước
  không thể ghim site vào nội dung của tuần trước.

Hai trang do tiến trình này tự dựng (`/download` và feed JSON) mang
`Content-Security-Policy: default-src 'none'` — một file HTML, không có script.

Đo tại đây (2 vCPU, keep-alive, 60 request mỗi route):

| | request đầu | p50 | p95 |
| --- | ---: | ---: | ---: |
| `/` | 31,0 ms | 0,34 ms | 1,12 ms |
| `/docs/intro` | 33,5 ms | 0,31 ms | 0,45 ms |
| `/download` | 62,7 ms | 0,29 ms | 1,02 ms |
| `/vi/` | 22,1 ms | 0,26 ms | 0,49 ms |

Request đầu tiên cho một trang trả giá cho việc nén nó; mọi request sau là 0,3 ms.
Brotli đưa trang chủ từ 16 KB xuống 3,9 KB. Instance Render có CPU khác và có mạng
thật phía trước; chưa có số nào được đo trên đó.

## Khi GitHub sập

Feed giữ câu trả lời tốt cuối cùng và trang nói rõ điều đó — kèm việc cần sửa
(`name lookup failed`, `timed out`, `TLS certificate rejected`) thay vì câu
`fetch failed` của Node. Nếu từ lúc khởi động
GitHub chưa từng trả lời, trang cũng nói vậy, các link đang có vẫn dùng được, và
`/iso/*` trả `404` thay vì chuyển hướng vào hư không. Không có chỗ nào trả 500 chỉ
vì bên thứ ba không sẵn sàng, và không phần nào của đội máy phụ thuộc vào GitHub.

## Kiểm thử

```bash
node --test host/tests/*.test.js    # 7 kiểm tra: một cổng, ba công việc
cd serve && npm test                # 46 kiểm tra: bản thân trang web
cd fleet && npm test                # 84 kiểm tra: bot, giao thức, store
```

Bộ đầu tiên là bộ mà cách triển khai này cần: một máy đào và một trình duyệt trên
cùng một cổng phải được hai nửa khác nhau trả lời, `/healthz` phải báo cả ba công
việc, dashboard không được công bố, và một site thiếu không được làm dừng các máy
đào.

Ghi chú vận hành đầy đủ — từng biến môi trường, thời gian cache và cách chỉnh —
nằm trong
[doc/WEB.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/WEB.md).
