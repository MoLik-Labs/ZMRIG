---
title: Bảng điều khiển trên trình duyệt
description: Cả fleet thành một trang web — một mật khẩu, không tài khoản, điều khiển từng rig, nhập rig và tải ISO hiện tại. Đặt FLEET_WEB_PASSWORD là nó xuất hiện trên cùng cổng với bot.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Bảng điều khiển trên trình duyệt

Bot là đường nhanh. Nhưng có lúc cần một trang: laptop trên ghế sofa, điện thoại
ở chỗ làm, một người không nằm trong chat của bạn. Cùng một fleet, cùng những
lệnh đó, hiển thị thành HTML — và **tắt cho đến khi bạn bật**.

```bash
FLEET_WEB_PASSWORD='at-least-twelve-characters'
```

Chỉ có vậy. Đặt biến đó thì `GET /` là trang tổng quan. Để trống thì không có
HTML nào cả: `/` vẫn là trang trạng thái chỉ đọc và mọi đường dẫn của dashboard
trả `404`. Một mật khẩu, một người vận hành. Không tài khoản, không email, không
lời mời — không có gì để lộ trên server của người khác.

## Có gì ở đó

| đường dẫn | |
| --- | --- |
| `/` | tổng của fleet: hashrate, số rig đang đào, số offline, máy nóng nhất, những gì cần để ý, và mỗi ví một dòng |
| `/rigs` | mỗi máy một dòng: trạng thái, hashrate, nhiệt độ, lần cuối |
| `/rig/<id>` | mọi thứ về một rig, kèm phần điều khiển |
| `/enrol` | ba bước nhập rig, URL của bạn đã điền sẵn |
| `/downloads` | ISO hiện tại và file checksum, lấy thẳng từ API releases |
| `/docs` | danh sách lệnh bot nhận, để tra |

Trang của một rig có đúng những gì chat có: **Start, Stop, Restart, Update, Lấy
log, Reboot**, form ví-và-pool, form coin / chế độ / giới hạn nhiệt / thread /
worker, đổi tên, và xoá. Tất cả đều được **xếp hàng** — rig áp dụng ở lần
check-in sau, mặc định 60 giây, rồi báo kết quả về cả trang và chat. Không có gì
đẩy xuống qua kết nối thường trực, nên một cú bấm trên trình duyệt không thể làm
kẹt miner giữa một share.

Hai điều dễ bất ngờ:

* Ô ví hay pool để trống nghĩa là **giữ nguyên**, không bao giờ là "xoá". Muốn
  đổi ví thì phải gõ ví khác.
* Rig nhập từ trình duyệt thuộc về admin chính trong chat, nên `/devices` trong
  Telegram liệt kê nó cùng mọi máy khác.

## Một ví, một con số

Trang tổng cộng hashrate theo **ví**, không theo máy. Mọi rig đào vào cùng một địa
chỉ là một con số ở pool, một số dư, một câu trả lời cho "mình đang chạy thế nào" —
nên ở đây nó là một dòng, kèm phần trăm trong tổng fleet đang tạo ra ngay lúc này.
Các rig chỉ là cách để tạo ra con số đó.

Một rig đã im lặng thì thôi không cộng vào tổng nữa: nó chưa chắc đã ngừng đào,
nhưng con số cuối cùng của nó không phải hiện tại, và một dashboard cộng số của
một tiếng trước vào số vừa báo là nói dối bằng cách bỏ sót. Nó vẫn được tính là
một rig của farm. Rig chưa báo ví sẽ thành một dòng riêng, nằm cuối bảng — máy
đang đào vào sai địa chỉ đúng là lỗi mà bảng này tồn tại để nhìn thấy.

## Nhập rig từ trang

Trên máy:

```bash
zmrig-os fleet --url https://your-fleet.onrender.com
zmrig-os id
```

```
  device      ZMR-1A2B-3C4D-5E6F
  enrol code  ABCD-1234
```

Rồi vào `/enrol`, hai ô, thêm một cái tên nếu muốn. Mã nhập sinh từ khoá của
chính rig và được kiểm ở phía server, nên một Device ID bị lộ cũng không nhập
được nếu không có người đứng ngay trước máy. `zmrig-os sync --now` để nó hiện ra
ngay thay vì chờ tối đa một phút.

## Vì sao nó rẻ

* Trang được render ở server từ đúng cái store mà bot ghi vào, rồi cache trong
  bộ nhớ cho tới khi bộ đếm revision của fleet nhích lên. Refresh mà không có
  check-in mới thì không chạm vào code template.
* 5,3 KB CSS, dưới 1 KB JS, đều `immutable` và cache một năm. Không font, không
  framework, không một request nào ra bên thứ ba.
* Brotli hoặc gzip khi trình duyệt yêu cầu và trang trên 512 byte, kèm `ETag`
  và `304 Not Modified` — điện thoại dùng dữ liệu di động refresh cả fleet
  chỉ tốn vài trăm byte.
* Cùng tiến trình Node với bot. Không phải host thêm, không phải trả thêm, và
  tắt dashboard không làm bot dừng.

## Bảo mật

* mật khẩu được so bằng `timingSafeEqual` với `FLEET_WEB_PASSWORD`;
* mười lần đăng nhập sai từ một địa chỉ trong mười lăm phút ⇒ `429` cho địa chỉ
  đó;
* mọi form mang một CSRF token gắn với phiên; form không có token là `403` và
  không đổi gì;
* cookie phiên là `HttpOnly`, `SameSite=Lax`, bảy ngày, và `Secure` khi request
  đến qua HTTPS;
* `Content-Security-Policy: default-src 'none'` — không script, font hay ảnh của
  bên thứ ba nào tải được, nên một CDN bị chiếm cũng không nhìn được fleet;
* mật khẩu nằm trong biến môi trường, không bao giờ trong repo, không bao giờ
  trong file trạng thái, và không in ra lúc khởi động.

Hãy chạy nó qua HTTPS. Trên Render là tự động; ở nơi khác thì đặt sau reverse
proxy, vì mật khẩu gõ vào HTTP thường là mật khẩu nằm trên dây.

## Lấy ISO mà không cần bot

`scripts/latest-iso.sh` hỏi API releases của GitHub rồi tải ảnh hiện tại cho CPU
của bạn:

```bash
./scripts/latest-iso.sh                 # bản stable mới nhất, đúng loại CPU
./scripts/latest-iso.sh --beta          # bản beta mới nhất
./scripts/latest-iso.sh --arch v3       # ép x86-64-v3
./scripts/latest-iso.sh --json          # chỉ dữ liệu, cho script khác
```

Nó in checksum và dung lượng, phần so sánh để `sha256sum -c` làm; cần `node` (rig
đã có sẵn) và nếu thiếu thì in đường dẫn trang releases. Bảng y hệt nằm ở
`/downloads` trong dashboard.

Sách vận hành đầy đủ — từng biến môi trường, định dạng trên dây, từng loại cảnh
báo — là [doc/FLEET.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/FLEET.md).
