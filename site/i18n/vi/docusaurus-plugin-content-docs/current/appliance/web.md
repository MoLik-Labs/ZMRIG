---
title: Tự host trang web và phần tải về
description: Một tiến trình Node phục vụ tài liệu, trang tải về dựng từ GitHub releases, feed JSON và các link cố định trỏ tới bản ISO mới nhất — không phụ thuộc gì, không có bước build riêng.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Tự host trang web và phần tải về

GitHub Pages đang phục vụ tài liệu này và GitHub phục vụ các file ISO, nên phần
này không bắt buộc. `serve/` tồn tại vì ba thứ tiện hơn khi nằm trên host của bạn:
một link không đổi khi phiên bản đổi, một trang tải về luôn liệt kê đúng file hiện
tại kèm checksum, và một site chạy được ở nơi GitHub Pages bị chặn hoặc chậm.

Một tiến trình Node, không phụ thuộc gì, không có bước build riêng.

```bash
cd site && npm install && npm run build && cd ..
cd serve && cp .env.example .env && npm start   # http://localhost:8080
```

Mọi thiết lập đều có mặc định, nên `.env.example` là để tra chứ không bắt buộc:
nó liệt kê cổng, thư mục site, repository lấy release, thời gian cache của feed và
URL công khai mà `/download` in ra.

## Nó trả lời những gì

| đường dẫn | |
| --- | --- |
| `/` | tài liệu, tiếng Anh |
| `/vi/` | tài liệu, tiếng Việt |
| `/download` | bản stable và beta kèm dung lượng, checksum, lệnh `dd` và `sha256sum` |
| `/api/releases.json` | đúng dữ liệu đó cho script |
| `/iso/v3` `.../v2` `.../beta` | 302 tới file mới nhất của kênh đó |
| `/healthz` | số file, số byte, RSS, thời gian chạy |

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

## Triển khai trên Render

`render.yaml` là blueprint gồm hai service — pool và host này.
[Nút deploy](https://render.com/deploy?repo=https://github.com/MoLik-Labs/ZMRIG)
đọc đúng file đó; *New → Blueprint* rồi chọn repository là cùng một việc. Render sẽ:

1. build tài liệu với `SITE_BASE_URL=/`, vì host này phục vụ từ gốc tên miền của
   nó chứ không phải từ `/ZMRIG/`;
2. ghi bản nén một lần, ngay lúc deploy;
3. chạy `node serve/server.js`.

Không có gì trong đó là bí mật. API GitHub được đọc ẩn danh và feed cache mười
phút — tối đa 60 lần gọi mỗi giờ, thừa xa giới hạn.

Gói free sẽ ngủ sau mười lăm phút không có traffic và tỉnh lại sau khoảng một
giây ở request kế tiếp. Nếu chưa đủ, trỏ một uptime monitor miễn phí vào
`/healthz` mỗi năm phút.

## Vì sao nó nhanh

Mọi thứ site phục vụ được đọc vào bộ nhớ một lần, lúc khởi động: 238 route,
6,31 MB gốc, 1,63 MB sau nén. Sau đó một request là một lần tra Map và một lần
`end()`.

- không `stat`, không `open`, không `readdir` cho từng request;
- Brotli và gzip ghi một lần lúc deploy (hoặc lúc khởi động nếu thiếu file nén);
- `ETag` trên mọi response, và request có điều kiện được trả `304` trước khi chạm
  vào body;
- asset có hash trong tên thì `immutable` một năm, HTML thì xác thực lại;
- một kết nối giữ mở 65 giây, nên một trang và các asset của nó dùng chung;
- feed releases lấy mỗi mười phút một lần, không phải mỗi lượt truy cập;
- bản nén cũ hơn file gốc bị bỏ qua, nên một file nén sót lại từ lần build trước
  không thể ghim site vào nội dung của tuần trước.

Hai trang do tiến trình này tự dựng (`/download` và feed JSON) mang
`Content-Security-Policy: default-src 'none'` — một file HTML, không có script.

Đo tại đây (2 vCPU, keep-alive, cache ấm): `/` 0,25 ms p50 và 0,81 ms p95,
`/docs/intro` 0,19 ms, một asset 0,35 ms, tám request đồng thời 0,89 ms p50.
Brotli đưa trang chủ từ 16 KB xuống 3,9 KB. Instance Render có CPU khác và có
mạng thật phía trước; chưa có số nào được đo trên đó.

## Khi GitHub sập

Feed giữ câu trả lời tốt cuối cùng và trang nói rõ điều đó — kèm việc cần sửa
(`name lookup failed`, `timed out`, `TLS certificate rejected`) thay vì câu
`fetch failed` của Node. Nếu từ lúc khởi động
GitHub chưa từng trả lời, trang cũng nói vậy, các link đang có vẫn dùng được, và
`/iso/*` trả `404` thay vì chuyển hướng vào hư không. Không có chỗ nào trả 500 chỉ
vì bên thứ ba không sẵn sàng.

## Kiểm thử

```bash
cd serve && npm test      # 45 kiểm tra
```

Bảng file, thương lượng nén, đường `304`, thử đi ngược thư mục, escape mọi thứ đến
từ GitHub — kể cả một URL `javascript:` trong asset của release — ba lần chuyển
hướng, feed lỗi và tự giải thích lý do, một file nén cũ sót lại, `q=0` trong
`Accept-Encoding`, policy trên các trang tự dựng, và tiến trình thật khởi động rồi
dừng trên socket.

Ghi chú vận hành đầy đủ — từng biến môi trường, thời gian cache và cách chỉnh —
nằm trong
[doc/WEB.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/WEB.md).
