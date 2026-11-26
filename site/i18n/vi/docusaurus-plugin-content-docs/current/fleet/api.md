---
title: API JSON cho người vận hành
description: REST API có phiên bản và xác thực để đọc trạng thái rig, gửi lệnh fleet đã kiểm tra.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# API JSON cho người vận hành

Dùng Fleet API từ tác vụ tự động hoặc ứng dụng riêng. API bị tắt nếu chưa cấu
hình `FLEET_API_TOKEN`; token này tách biệt với mật khẩu dashboard, phải lưu như
secret và chỉ gửi qua HTTPS. Hãy tạo giá trị ngẫu nhiên dài ít nhất 32 ký tự.
Không đưa token vào mã trình duyệt, URL, log hay repository.

Hợp đồng OpenAPI 3.1 có thể đọc tại `/api/v1/openapi.json`. Hợp đồng mô tả định
dạng request/response và có thể dùng để sinh client. API dùng JSON và xác thực
Bearer; không bật truy cập trình duyệt khác origin.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FLEET_API_TOKEN" \
  'https://fleet.example.com/api/v1/devices?limit=50'

curl --fail-with-body -X POST \
  -H "Authorization: Bearer $FLEET_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"command":"setup","args":{"mode":"safe","maxtemp":72,"threads":8} }' \
  'https://fleet.example.com/api/v1/devices/ZMR-1A2B-3C4D-5E6F/commands'
```

## Endpoint

| Phương thức và đường dẫn | Chức năng |
| --- | --- |
| `GET /api/v1/devices?limit=50&after=<id>` | Liệt kê rig đã enroll theo ID ổn định; `limit` từ 1–100, dùng `next_cursor` để lấy trang tiếp. |
| `GET /api/v1/devices/{id}` | Đọc trạng thái rig đã enroll và độ dài hàng đợi. |
| `GET /api/v1/audit?limit=50` | Xem các thao tác gần đây mà không lộ payload lệnh. |
| `POST /api/v1/devices/{id}/commands` | Kiểm tra và xếp hàng một lệnh hoặc thay đổi cấu hình. |
| `GET /api/v1/openapi.json` | Đọc hợp đồng API; endpoint này công khai nhưng không chứa dữ liệu fleet. |

Mọi lệnh điều khiển trả `202 Accepted`: lệnh được xếp hàng và chỉ áp dụng khi
rig check-in lần tới, không chạy ngay tức thì. Response có command ID. API nhận
`start`, `stop`, `restart`, `update`, `reboot`, `log` và `setup`. `setup` chỉ
nhận các trường được tài liệu hóa (`wallet`, `pool`, `coin`, `mode`, `threads`,
`worker`, `maxtemp`) và kiểm tra trước khi xếp hàng. `maxtemp` yêu cầu safe mode.
Lệnh không hỗ trợ, trường thừa, ví sai hoặc hàng đợi đầy sẽ bị từ chối mà không
thay đổi rig.

```json
{"command":"setup","args":{"mode":"safe","maxtemp":72,"threads":"auto"} }
```

Kết quả danh sách được phân trang bằng cursor; dữ liệu rig không bao giờ chứa
key, mã enroll hoặc nội dung lệnh đang chờ. Trạng thái có thể bao gồm thiết lập
mà người vận hành đã xác thực cần kiểm tra. Request bị giới hạn 16 KiB, có giới
hạn tần suất theo client và lỗi JSON có cấu trúc. Lệnh API đi vào cùng hàng đợi
có giới hạn và nhật ký audit như lệnh từ dashboard/chat.

## Bảo mật và giới hạn vận hành

- Dùng secret riêng cho mỗi deployment; thay đổi token bằng cách cập nhật biến
  môi trường và khởi động lại dịch vụ. Hiện API dùng một token người vận hành,
  chưa có scope cho từng người; ai có token có thể đọc và điều khiển mọi rig đã
  enroll.
- Chỉ nhận xác thực qua header `Authorization`. Không chấp nhận token trong
  query parameter hoặc cookie.
- Dịch vụ không thêm header CORS. Gọi API từ backend đáng tin cậy, không gọi
  trực tiếp từ website công khai.
- JSON state store và lịch sử command/audit có giới hạn phù hợp fleet tự host
  quy mô nhỏ, không phải dịch vụ đa tenant. Với triển khai lớn hơn, cần database
  bền vững và phân quyền tường minh trước khi cho thêm người dùng truy cập.
- Pool và hạ tầng mining vẫn là công cụ phát triển tự host; API không phải dịch
  vụ mining hoặc pool hosting.
