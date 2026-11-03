---
title: File cấu hình
description: Thứ tự ưu tiên, một config.json đầy đủ do installer ghi, và mọi khoá mà engine Zig hiểu.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# File cấu hình

Thứ tự ưu tiên, cao nhất trước:

1. cờ trên dòng lệnh
2. file truyền qua `-c/--config`
3. giá trị mặc định của miner

Chỉ những cờ bạn thực sự gõ mới ghi đè file. `zmrig -c config.json --verbose`
không làm mất `"mode": "light"` hay `"huge-pages": false`. (Trước `6.26.0-mo9`
thì có; xem changelog.)

## Một file do installer ghi

```json
{
  "api": { "id": null, "worker-id": "vps-sg-02" },
  "http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 18080,
    "access-token": null,
    "restricted": true
  },
  "autosave": true,
  "background": false,
  "colors": false,
  "randomx": {
    "mode": "auto",
    "rdmsr": true,
    "wrmsr": true,
    "numa": true,
    "scratchpad_prefetch_mode": 1
  },
  "cpu": {
    "huge-pages": true,
    "huge-pages-jit": true,
    "priority": 5,
    "max-threads-hint": 100,
    "asm": true
  },
  "donate-level": 0,
  "pools": [
    {
      "algo": null,
      "url": "gulf.moneroocean.stream:10001",
      "user": "YOUR_WALLET",
      "pass": "x",
      "rig-id": "vps-sg-02",
      "keepalive": true,
      "enabled": true,
      "tls": false,
      "transport": "wss",
      "ws-path": "/pool"
    }
  ],
  "print-time": 60,
  "retries": 5,
  "retry-pause": 5,
  "idle-timeout": 300,
  "keepalive-interval": 60,
  "report": { "enabled": true, "file": "/var/lib/zmrig/report.txt", "interval": 60 },
  "power": 45
}
```

`transport`, `ws-path`, `ws-origin`, `proxy`, `connect-to`, `tls-ca`,
`idle-timeout`, `keepalive-interval`, `report` và `power` do engine Zig hiểu.
Engine C++ bỏ qua những khoá nó không biết, nên cùng một file dùng được cho cả
hai.

## Các khoá

| Khoá | Kiểu | Mặc định | Ghi chú |
| --- | --- | --- | --- |
| `algo` | string | tự động | `rx/0`, `rx/wow`, `panthera`, … hoặc `auto` |
| `print-time` | number | 60 | giây giữa các dòng hashrate, 0 = tắt |
| `retries` | number | 5 | số lần thử mỗi pool trước khi chuyển dự phòng |
| `retry-pause` | number | 5 | giây giữa các lần thử, lệch ±20 % |
| `idle-timeout` | number | 300 | ngắt kết nối im lặng, 0 = tắt |
| `keepalive-interval` | number | 60 | giây giữa các keepalive |
| `colors` | bool | true | màu log; file log luôn là văn bản thường |
| `background` | bool | false | fork xuống nền |
| `log-file` | string | null | ghi log ra file nữa |
| `power` | number | — | watt tại ổ cắm, đưa vào mã báo cáo |
| `report.file` | string | null | nơi ghi mã báo cáo |
| `report.interval` | number | 60 | giây giữa các lần ghi |
| `report.id` | string | `rig-id` | tên máy trong báo cáo |
| `http.enabled` | bool | false | API giám sát |
| `http.port` / `http.host` | number / string | 18080 / 127.0.0.1 | |
| `http.access-token` | string | null | bắt buộc Bearer token |
| `randomx.mode` | `auto`/`fast`/`light` | auto | `fast` dựng dataset 2 GiB |
| `cpu.threads` | number hoặc mảng | theo cache | mảng là mỗi thread một phần tử |
| `cpu.huge-pages` | bool | true | |
| `cpu.huge-pages-jit` | bool | true | |
| `cpu.asm` | bool | true | JIT; tắt đi thì chậm khoảng sáu lần |
| `cpu.priority` | number | -1 | thang XMRig 1..5, hoặc giá trị nice thô |

Object pool nhận `url`, `user`, `pass`, `rig-id`, `algo`, `keepalive`, `tls`,
`transport`, `ws-path`, `ws-origin`, `host-header`, `connect-to`, `tls-ca`,
`proxy`, `enabled`.

## Sửa an toàn

```bash
sudo systemctl stop zmrig
sudo cp /etc/zmrig/config.json /etc/zmrig/config.json.bak
sudo -e /etc/zmrig/config.json
zmrig --check -c /etc/zmrig/config.json    # phân tích và kiểm tra, không đào
sudo systemctl start zmrig
```

`--check` thoát với mã khác 0 và in ra khoá sai, nhanh hơn là đọc journal sau
khi service đã restart bốn lần.

:::note Autosave
`"autosave": true` cho phép miner ghi lại file khi nó đổi thứ thuộc về nó (ví dụ
số thread đã dò được). Muốn một file mà miner không bao giờ đụng vào thì đặt
`false` và khởi động lại, đừng sửa config đang chạy.
:::
