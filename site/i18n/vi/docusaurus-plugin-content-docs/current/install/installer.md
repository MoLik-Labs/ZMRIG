---
title: Tham chiếu installer
description: Mọi lệnh con và cờ của oneclick.sh, các file nó cài, unit systemd nó ghi, cách nó chuyển từ bản cài cũ và cách tự gỡ.
image: https://nggkhaiz.github.io/ZMRIG/img/og-vi.png
---

# Tham chiếu installer

```text
oneclick.sh [subcommand] [options]
```

Lệnh con mặc định là `install` khi có ví và `status` khi không có.

## Lệnh con

| Lệnh con | Việc nó làm |
| --- | --- |
| `install` | phụ thuộc, build, tune, config, service, tự kiểm tra (mặc định) |
| `build` | chỉ biên dịch; giữ binary cũ cho tới khi bản mới link xong |
| `tune` | huge pages, THP, governor, MSR — chỉ root |
| `config` | tạo lại `/etc/zmrig/config.json` mà không đụng service |
| `start`, `stop`, `restart`, `status`, `logs` | điều khiển service |
| `bench` | đo RandomX lặp lại được (`--bench=20000`) |
| `report` | đo và in mã `ZMRIG1.` cho máy tính |
| `verify` | self-test, rồi kiểm tra phí developer (mức, địa chỉ, công tắc tắt) |
| `plan` | in mọi quyết định tự động, không thay đổi gì |
| `update` | lấy nhánh đã cấu hình, build lại, khởi động lại |
| `uninstall` | dừng, xoá service và binary, giữ config |
| `purge` | xoá mọi thứ công cụ từng tạo |

## Tuỳ chọn

### Pool và danh tính

| Cờ | Ý nghĩa |
| --- | --- |
| `--wallet ADDR` | địa chỉ ví hoặc login pool (sẽ hỏi nếu thiếu) |
| `--pass VALUE` | mật khẩu pool, mặc định `x` |
| `--rig-id NAME` | tên worker trên dashboard pool và trong mã báo cáo |
| `--pool HOST:PORT` | endpoint; dùng được tên sẵn: `moneroocean`, `supportxmr`, `c3pool`, `herominers`, `xmrpool`, `p2pool`, `p2pool-nano` |
| `--failover LIST` | pool dự phòng cách nhau bằng dấu phẩy, ghi vào `config.json` |
| `--algo NAME` | ghim một thuật toán; `auto` khai báo cả họ RandomX |
| `--engine xmrig\|zmrig` | engine C++ hoặc engine Zig |

### Mạng

| Cờ | Ý nghĩa |
| --- | --- |
| `--tls` | TLS cho kết nối pool |
| `--cloudflare[=HOST[:PORT]]` | pool qua `wss://` trên 443; tự chuyển sang `zmrig` |
| `--transport tcp\|tls\|ws\|wss` | ép giao thức |
| `--ws-path PATH` | đường dẫn WebSocket (mặc định `/stratum`) |
| `--ws-origin URL` | header `Origin` cho lúc nâng cấp |
| `--proxy URL` | `http://user:pass@host:port` hoặc `socks5://host:port` |
| `--connect-to HOST:PORT` | dial địa chỉ khác, giữ SNI và `Host` của pool |
| `--tls-ca FILE` | tin CA riêng, hoặc ghim chứng chỉ relay |
| `--idle-timeout N` | ngắt kết nối sau N giây im lặng (0 = tắt) |
| `--ban-cooldown N` | số giây để yên một pool sau khi nó ban IP (mặc định 900) |

### Máy

| Cờ | Ý nghĩa |
| --- | --- |
| `--profile free\|watt` | hashrate tối đa, hoặc hash trên watt tối đa |
| `--mode fast\|light\|auto` | kích thước dataset; `light` cần khoảng 300 MB |
| `--cpu-hint N` | phần trăm `max-threads-hint` (mặc định 100) |
| `--no-autotune` | giữ số thread mặc định |
| `--no-tune` | không đụng huge pages, THP, governor hay MSR |
| `--msr`, `--no-msr` | ép hoặc cấm ghi MSR |
| `--nicehash` | che nonce cho pool cho thuê hash |
| `--http-port PORT` | cổng API giám sát (mặc định 18080) |
| `--http-token TOKEN` | bắt buộc `Authorization: Bearer TOKEN` |
| `--no-http` | tắt API giám sát |
| `--power W` | công suất tại ổ cắm của máy này, dùng trong mã báo cáo |

### Hành vi

| Cờ | Ý nghĩa |
| --- | --- |
| `--force` | ghi đè config đang có |
| `--yes` | không hỏi gì (cài không người trực) |
| `--no-service` | cài và cấu hình, không tạo unit |
| `--all-backends` | build thêm hỗ trợ OpenCL/CUDA |
| `--build-dir DIR` | nơi biên dịch (mặc định `/usr/local/src/zmrig-build`) |

## Nó cài những gì

| Đường dẫn | Nội dung |
| --- | --- |
| `/usr/local/bin/zmrig` | miner Zig |
| `/usr/local/bin/xmrig` | miner C++, khi chọn engine đó |
| `/usr/local/bin/zmrig-tune` | tinh chỉnh host (`--status`, `--hugepages 1G`, `--algo panthera` đặt mức theo coin đó, …) |
| `/usr/local/bin/zmrig-bench` | đo hashrate lặp lại được |
| `/usr/local/bin/zmrig-verify` | kiểm tra phí developer |
| `/etc/zmrig/config.json` | cấu hình, quyền 600 |
| `/var/lib/zmrig/` | trạng thái và file báo cáo |
| `zmrig.service` | miner: `Restart=always`, `RestartSec=5`, `Nice=-10`, `LimitMEMLOCK=infinity`, `PrivateTmp=true` |
| `zmrig-tune.service` | tuner oneshot, chạy trước miner khi khởi động |
| `http://127.0.0.1:18080/1/summary` | API giám sát chỉ đọc |

## Chuyển từ tên cũ

Tới installer 1.2, công cụ cài chính nó dưới tên `xmrig-ocean`. Bản cài mới
không lặng lẽ để bản cũ nằm lại:

1. `/etc/xmrig-ocean/config.json` được chép sang `/etc/zmrig/config.json`
   (quyền 600) nếu đường dẫn mới chưa có.
2. `/var/lib/xmrig-ocean` được chuyển sang `/var/lib/zmrig`.
3. Unit cũ được dừng, tắt và xoá, để sau khi reboot máy không chạy hai miner.
4. `purge` xoá cả hai bộ tên, nên nâng cấp không để lại file mồ côi.

## Nhánh

```text
ALPHA  ──►  BETA  ──►  master
mới nhất    mặc định   lịch sử gốc
```

Mọi lệnh trong tài liệu này dùng `BETA`. Muốn thử `ALPHA` một lần:

```bash
MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install --wallet 4YourMoneroAddress
sudo ./oneclick.sh update    # về nhánh mặc định
```

`update` fetch nhánh đã cấu hình trước khi checkout, và dừng lại kèm tên nhánh
nếu nhánh đó không tồn tại. Trước đây chỗ này fail một cách im lặng.
