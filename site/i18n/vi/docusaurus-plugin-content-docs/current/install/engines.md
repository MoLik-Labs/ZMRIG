---
title: Chọn engine
description: zmrig (Zig) và xmrig (C++) dùng chung engine RandomX. Khác biệt nằm ở transport, thuật toán, và những gì mỗi bên tự nói được về mình.
image: https://nggkhaiz.github.io/ZMRIG/img/og-vi.png
---

# Chọn engine

Cả hai engine biên dịch ra cùng một vòng hash: `zmrig/capi` gắn phần RandomX C++
vào binary Zig, nên con số giống nhau trong biên độ nhiễu. Khác biệt nằm ở mọi
thứ xung quanh vòng hash.

| | `xmrig` (C++) | `zmrig` (Zig) |
| --- | --- | --- |
| Thuật toán | tất cả (34+) | họ RandomX: `rx/0`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada`, `panthera` (`rx/2` phân tích được nhưng không coin nào dùng và không có trong test) |
| Transport | TCP, TLS | TCP, TLS, `ws`, `wss` |
| Proxy | SOCKS5 một phần | HTTP CONNECT và SOCKS5, có auth và DNS từ xa |
| API giám sát | có, đầy đủ | có, chỉ đọc, cùng hình dạng với XMRig |
| Mã báo cáo cho máy tính | không | có (`--report`) |
| Watchdog sức khoẻ | không | có, tự khởi động lại khi hết thu nhập |
| `rx/0` đo được | 832 H/s | 800–841 H/s, cùng máy, cùng config |

Cả hai đo trên cùng một máy 2 vCPU, `--bench`, trang 2 MiB; độ tản là do host,
không do engine. [Hiệu năng](/docs/reference/benchmarks) có cách đo. Mỗi thuật
toán ở trên đều có vector kiểm tra trong `zmrig --self-test`, nên độ phủ của
engine Zig là đã kiểm chứng chứ không phải lời quảng cáo.

## Chọn bên nào

- **RandomX trên VPS bình thường:** bên nào cũng được. `zmrig` nhỏ hơn, có các
  lựa chọn transport và in được mã báo cáo, nên installer chọn nó.
- **Pool đổi thuật toán (MoneroOcean và bản sao):** `zmrig` vẫn chạy — nó khai
  báo cả họ RandomX và pool chuyển rig giữa các coin. Nó không đào được những
  thuật toán ngoài RandomX mà các pool đó cũng trả tiền, nên pool coi trọng độ
  rộng hơn độ sâu thì `xmrig` hợp hơn. Chế độ `auto` của installer chọn `xmrig`
  cho pool đổi thuật toán vì lý do này; `zmrig` vẫn là mặc định trong mọi
  trường hợp (1 % thời gian Monero, tắt được).
- **Thuật toán khác (cn/heavy, ghostrider, KawPow):** `xmrig`. `zmrig` từ chối
  ngay lúc phân tích tham số, thay vì khởi động rồi không kết nối được.
- **Mạng chỉ mở 443, hoặc đi qua proxy:** `zmrig`. Xem
  [Mạng chỉ mở 443](/docs/operate/networks).

## Đổi engine

Engine được ghi vào `/etc/zmrig/engine`, nên các lệnh con sau (`status`, `logs`,
`bench`, …) dùng đúng binary đó mà không cần lặp lại `--engine`.

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --engine zmrig --force
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --engine xmrig --force
```

Hai binary có thể nằm cạnh nhau; service chạy bản mà file marker chỉ định.
