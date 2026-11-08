---
title: Cài trong một lệnh
description: Cài ZMRIG bằng một lệnh và một địa chỉ ví. Installer tự quyết định những gì, in ra những gì, và kiểm tra thế nào là xong.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Cài trong một lệnh

Chưa chắc đây là cách bạn muốn? [Dựng rig từ đầu](/docs/install/setup) so sánh
cách này với container và ảnh boot trong một bảng, kèm năm bước kiểm tra để biết
đã cài xong thật chưa.

```bash
curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress
```

Nếu repo đã clone sẵn:

```bash
sudo ./oneclick.sh --wallet 4YourMoneroAddress
```

Đó là toàn bộ phần cài. Nó cài phụ thuộc build, biên dịch engine hash và miner,
đo máy để chọn số thread, tinh chỉnh host, ghi `/etc/zmrig/config.json`, tạo
`zmrig.service`, chạy tự kiểm tra và in hashrate đo được. Chạy lại an toàn: không
nhân đôi service, không ghi đè config nếu thiếu `--force`, không build lại khi
binary mới hơn mã nguồn.

## Nó quyết định gì, và vì sao

| Quyết định | Cách installer chọn |
| --- | --- |
| Engine | `zmrig` (3 % thời gian Monero, `--donate-level=0` để bỏ). Nó khai báo cả họ RandomX, nên pool đổi thuật toán vẫn chuyển được rig sang coin đang trả tốt nhất. `--algo` ngoài RandomX, hoặc `--engine=xmrig`, sẽ chọn engine C++, engine này không lấy phí. |
| Profile | `free` (hashrate tối đa) ở mọi nơi, trừ laptop đang dùng pin → `watt` (hash trên mỗi watt tối đa). |
| Thread | Đo sau khi build: mỗi phương án chạy 8 s trên dataset thật, phương án thắng được ghi vào config. |
| Huge pages | Tính từ dataset. Nếu kernel cấp ít hơn, nó lùi về transparent huge pages và nói rõ. |
| Governor | `performance` cho `free`, giữ nguyên powersave cho `watt`. |

Xem đúng danh sách đó mà không đụng vào máy:

```bash
./oneclick.sh plan
```

```text
==> plan
    engine         zmrig  (RandomX family, 3% dev fee)
    pool           gulf.moneroocean.stream:10001
    algo           auto  (RandomX family: rx/0, rx/wow, rx/arq, …)
    profile        free  (auto: no battery, electricity is treated as free)
    mode           auto (fast when RAM allows)
    huge pages     none yet, the installer reserves what the dataset needs
    autotune       8 s per candidate, winner written to config.json
    service        zmrig.service (systemd)
```

## Kiểm tra đã chạy chưa

```bash
sudo ./oneclick.sh status      # service, hashrate 10s/60s/15m, share, huge pages
sudo ./oneclick.sh verify      # self-test + kiểm tra phí developer
sudo ./oneclick.sh logs 50     # 50 dòng log cuối
```

```text
==> verifying zmrig
    OK  PASS rx/0 reference vector
    OK  PASS pipelined hashing
    OK  PASS full-memory dataset matches the cache
    OK  fee audit: one wallet, Monero only, switchable off
    OK  verified
```

`status` chỉ báo số đo thật: miner vừa khởi động sẽ hiện `warming up` chứ không
đọc lại số của lần chạy trước, vì dataset cần 15–25 giây để dựng.

## Hai profile điện

```bash
# điện miễn phí: quán cà phê, trường học, máy cơ quan — hashrate tối đa
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile free

# mỗi watt đều tốn tiền: laptop, VPS trả theo đồng hồ — hash trên watt tối đa
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile watt
```

`free` dùng mọi CPU logic, `--mode fast`, huge pages và `--priority 5`. `watt`
giảm còn một thread mỗi core vật lý (SMT thêm 5–15 % hashrate nhưng tốn thêm
30–40 % điện), không ép CPU lên xung cao nhất, và tự dừng khi laptop chuyển sang
pin.

## Cập nhật, gỡ

```bash
sudo ./oneclick.sh update        # git pull, build lại, khởi động lại
sudo ./oneclick.sh uninstall     # dừng, xoá service và binary, giữ config
sudo ./oneclick.sh purge --dry-run
sudo ./oneclick.sh purge         # xoá mọi thứ công cụ đã tạo
```

`purge` in từng đường dẫn nó đã tạo kèm dung lượng, bắt gõ chữ `purge` để xác
nhận, đặt lại `vm.nr_hugepages` về 0, và không bao giờ đụng vào file nó không tạo.
`--dry-run` liệt kê mà không xoá.

## Khi có gì đó sai

- **Không có huge pages.** Trong container hoặc VPS OpenVZ kernel có thể từ chối;
  miner ghi phần thiếu vào log và chạy tiếp ở khoảng 78 % hashrate. Không có gì
  để sửa — hãy hỏi nhà cung cấp về trang 2 MiB.
- **Service khởi động lại liên tục.** Gần như luôn là config bị miner từ chối.
  Chạy `sudo journalctl -u zmrig -n 60` và đọc dòng đầu tiên sau khi binary khởi
  động; installer đã kiểm tra config trước khi ghi, nên thường là do ai đó sửa nó.
- **`the miner rejected the generated config`.** Ví có ký tự không thuộc base58.
  Chạy lại với địa chỉ sạch.

Các kiểu lỗi còn lại nằm ở [Lỗi thường gặp](/docs/operate/troubleshooting).
