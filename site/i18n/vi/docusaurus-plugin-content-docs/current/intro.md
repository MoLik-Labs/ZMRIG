---
title: ZMRIG là gì
description: Miner RandomX không phí developer, installer cài đặt nó, proxy cho farm và pool tự dựng. Từng phần làm gì, tốn bao nhiêu, và mã nguồn đến từ đâu.
slug: /intro
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# ZMRIG là gì

ZMRIG là một bộ đào Monero hoàn chỉnh, không phải mớ script rời:

| Phần | Là gì | Tốn gì |
| --- | --- | --- |
| **Miner** | XMRig 6.26.0 đã xoá sạch mọi dòng mã donate, cộng thêm miner Zig hoàn chỉnh trên cùng engine RandomX | **1 %** thời gian Monero ở engine Zig, in ra và tắt được; engine C++ không có mã phí |
| **Installer** | `oneclick.sh`: một cờ, tinh chỉnh host, unit systemd, tự kiểm tra, gỡ cài đặt | miễn phí |
| **Proxy** | một kết nối pool cho cả farm: extranonce riêng từng rig, độ khó riêng, tunnel | miễn phí |
| **Pool** | pool Monero tự dựng: stratum qua TCP và WebSocket, PPLNS, mọi share đều được kiểm lại | 1 % mỗi block, không gì khác |

Miner chạy được với bất kỳ pool nào. 1 % ở pool trong repo này là thứ giữ dự án
sống; bản thân miner không lấy gì của bạn, và không có tài khoản, token hay
telemetry ở bất kỳ đâu trong đó.

## Ba quyết định định hình mọi thứ còn lại

**Phí phải chứng minh được, nên nó được kiểm tra.** `sudo ./oneclick.sh verify`
grep binary để tìm endpoint donate của bản gốc và các ví đã biết, rồi chạy
self-test hash — để "không tìm thấy gì" không thể có nghĩa là "nó đọc sai file".
Chi tiết ở [trang phí](/docs/reference/fee): mức phí, các dòng log và cách tắt.

**Không có cờ nào bắt buộc phải nhớ.** `--wallet` là đầu vào duy nhất. Installer
đọc CPU, RAM, hypervisor và pin, rồi chọn engine, số thread, chiến lược huge page
và governor, in lý do cho từng lựa chọn trước khi làm. `./oneclick.sh plan` cho
xem toàn bộ quyết định mà không thay đổi gì.

**Miner không kiếm được tiền thì phải nói ra.** Một rig bị pool từ chối mọi share
nhìn từ ngoài vẫn "khoẻ". `zmrig` tự đánh giá số liệu mỗi giây và thoát để
supervisor khởi động lại — mất hai mươi giây hashrate thay vì cả đêm bằng không.

## Cần gì

- Linux x86-64 (Debian/Ubuntu, RHEL/Fedora, Arch; script tự nhận distro). macOS
  và Windows build được engine C++, nhưng installer nhắm vào Linux.
- 2 GB RAM trống cho chế độ `fast`, hoặc `--mode light` với khoảng 300 MB.
- `systemd` nếu muốn chạy như service.
- root, cho huge pages, MSR và service.
- Mạng cho lần build đầu. Mọi thứ được biên dịch trên máy; không tải binary từ
  đâu về.

## Mã nguồn đến từ đâu

Không có gì ở đây viết từ số không, và những phần không tự viết được ghi công
trong file `NOTICE` của repo:

| Dự án | Đóng góp | Giấy phép |
| --- | --- | --- |
| [XMRig](https://github.com/xmrig/xmrig) | miner C++, engine RandomX, định dạng config, CLI | GPL-3.0 |
| [RandomX](https://github.com/tevador/RandomX) | thuật toán proof-of-work và JIT | BSD-3-Clause |
| [MoneroOcean](https://github.com/MoneroOcean/xmrig) | mô hình pool đổi thuật toán và nhánh `-mo` | GPL-3.0 |
| [Monero](https://github.com/monero-project/monero) | đồng coin, daemon và wallet RPC | BSD-3-Clause |
| libuv, hwloc, rapidjson, `{fmt}` | mạng, topology, config, định dạng | MIT / BSD / ICU |

Miner Zig, installer, proxy, pool và trang này là phần tự viết. Tất cả theo
GPL-3.0, Copyright (C) 2026 @nggkhaiz.

## Tiếp theo

- [Cài trong một lệnh](/docs/install/quickstart) — năm phút mà phần lớn người
  dùng cần.
- [Chọn engine](/docs/install/engines) — `zmrig` hay `xmrig`.
- [Pool và tiền](/docs/pools/choosing) — phí, mức trả tối thiểu, và cách không
  bị ban IP.
- [Máy tính lợi nhuận](/docs/economics/profitability) — dán mã các máy bạn in ra.
