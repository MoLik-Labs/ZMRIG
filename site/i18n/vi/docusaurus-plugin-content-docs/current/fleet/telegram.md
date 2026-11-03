---
title: Điều khiển bằng Telegram và Discord
description: Nhập Device ID để nhận rig, đặt ví, pool, coin và chế độ từ cửa sổ chat, nhận cảnh báo khi một máy im lặng. Bot không phụ thuộc gì, chạy trên host của bạn.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Điều khiển bằng Telegram và Discord

Mỗi rig in ra một **Device ID** và một **mã nhập** trên console. Nhập chúng vào
bot một lần, từ đó cấu hình máy đó ngay trong chat: ví, pool, coin, chế độ đào,
giới hạn nhiệt, số thread, tên worker. Máy báo lại hashrate, nhiệt độ, thời gian
chạy, log khi bạn hỏi — và cảnh báo khi nó im lặng.

```bash
# trên rig, một lần
zmrig-os fleet --url https://your-fleet.onrender.com
zmrig-os id
```

```
  device      ZMR-1A2B-3C4D-5E6F
  enrol code  ABCD-1234
```

```
# trong chat
/enroll ZMR-1A2B-3C4D-5E6F ABCD-1234 basement
/wallet ZMR-1A2B-3C4D-5E6F 4YourMoneroAddress...
```

Đó là toàn bộ phần khởi tạo. Ví nhập một lần, trong chat, cho bao nhiêu rig cũng
được.

## Bot làm được gì

| Lệnh | |
| --- | --- |
| `/enroll <id> <code> [tên]` | gắn rig vào bạn |
| `/devices` | mọi rig: trạng thái, hashrate, nhiệt độ, lần cuối |
| `/status` | một màn hình: số rig, tổng hashrate, máy nóng nhất, số offline |
| `/device <rig>` | một rig, kèm nút bấm |
| `/wallet <rig> 4…` | đặt ví, kiểm tra trước khi xếp hàng |
| `/pool <rig> host:port` | đặt pool |
| `/coin <rig> xmr\|wow\|arq\|graft\|sfx\|yada\|xla` | đặt coin |
| `/mode <rig> max\|balanced\|eco\|light\|safe [C]` | độ "gắt", và giới hạn nhiệt |
| `/threads <rig> 8\|auto` | ghim số thread |
| `/worker <rig> tên` | tên pool nhìn thấy |
| `/update <rig>` | miner mới nhất; OS vào slot A/B còn trống |
| `/log <rig> [n]` | log của rig, về cùng lần check-in sau |
| `/reboot <rig>` `/rename` `/remove` | phần còn lại |

`<rig>` là ID đầy đủ, một phần duy nhất của nó (`3C4D`), hoặc tên bạn đã đặt.

Thay đổi được **xếp hàng**, không phải đẩy xuống: rig đang offline vẫn nhận được
khi nó trở lại, và mọi kết quả — áp dụng hay bị từ chối — đều báo trong chat.
`zmrig-os` kiểm tra lại mọi thứ trên máy, nên một request tự dựng gửi thẳng tới
control plane cũng không lừa được rig dùng ví mà nó sẽ từ chối.

## Cảnh báo

* rig không check-in trong năm phút;
* rig vừa trở lại;
* nhiệt độ từ 85 °C trở lên;
* miner dừng khi đang đào;
* hashrate dưới một nửa lần check-in trước;
* hashrate dưới một nửa mức rig tự đo được trên chính nó — bắt được cái máy đã
  tụt dần cả tuần, chứ không phải cái vừa ngã trong một phút;
* mọi kết quả lệnh, kể cả bị từ chối.

Mỗi loại có thời gian chờ riêng cho từng rig, nên máy nóng không hét lên mỗi
phút. Luật hashrate thứ hai là luật chậm, và nó nói rõ nó so với cái gì:

```
🐌 rig-2 is at 640.0 H/s, 45% of the 1.4 kH/s it measured itself
```

## Tự host

Một tiến trình Node, **không phụ thuộc gì**, trạng thái là một file JSON.

```bash
cd fleet
cp config.example.env .env      # TELEGRAM_BOT_TOKEN, FLEET_ADMIN_IDS
set -a; . ./.env; set +a
npm run check                   # in cấu hình, không mở socket
npm start
```

`fleet/render.yaml` là blueprint cho Render. Gói free sẽ ngủ sau 15 phút không có
traffic, nên trỏ một uptime monitor miễn phí vào `/healthz` mỗi 5 phút — bot ngủ
thì không trả lời, nhưng rig vẫn đào và bắt kịp khi bot tỉnh.

Token nằm trong biến môi trường, không bao giờ trong file của repo. Chỉ id của
bạn được bot trả lời cho đến khi bạn thêm người khác vào `FLEET_ADMIN_IDS`.

## Danh tính hoạt động thế nào

```
ZMR-XXXX-XXXX-XXXX   sha256(key)[0..6), chữ hoa
mã nhập XXXX-XXXX    sha256("enroll:" + key)[0..4), chữ hoa
```

Khóa 32 byte được tạo trên rig và không rời khỏi đó. Server tính lại cả hai chuỗi
từ khóa mà rig trình ra ở mỗi lần check-in, nên không máy nào nhận được ID không
thuộc về nó, và mã nhập chứng minh máy đang ở ngay trước mặt bạn. Không có gì kết
nối *vào* rig: rig gọi ra, mỗi phút một lần, mọi thứ khác chờ lần gọi đó.

Trên USB live, khóa nằm trong RAM — cài lên ổ, hoặc tạo phân vùng `ZMRIGDATA`
bằng `zmrig-os persist`, nếu không rig sẽ báo ID mới sau khi khởi động lại.

## Khi không dùng fleet

Để trống `FLEET_URL` thì không có gì thay đổi: rig không liên lạc với ai, và
`zmrig-os setup` vẫn là cách cấu hình. Control plane là phần thêm vào, không phải
phụ thuộc.

Chi tiết mức vận hành — từng biến môi trường, định dạng trên dây, các kiểu lỗi —
nằm trong [doc/FLEET.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/FLEET.md).
