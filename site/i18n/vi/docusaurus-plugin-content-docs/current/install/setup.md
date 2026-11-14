---
title: Dựng rig từ đầu
description: Ba cách để một cái máy bắt đầu đào — một lệnh, một container, hoặc ảnh boot — kèm năm bước kiểm tra, cách cập nhật, cách audit phí 3 %, và cách đặt tên khi có nhiều rig.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Dựng rig từ đầu

Trang này để chọn đường, không phải để tra cứu. Nó chỉ giả định hai thứ: bạn có
một địa chỉ Monero và một cái máy có CPU. Chọn một cách, chạy một lệnh, rồi làm
năm bước kiểm tra ở [Chạy được chưa](#chạy-được-chưa). Phần còn lại là những gì
bạn sẽ cần vào ngày thứ hai.

| Cách | Hợp với | Đụng vào đâu | Thời gian |
| --- | --- | --- | --- |
| [A. Một lệnh](#a-một-lệnh) | máy của bạn, dùng lâu dài | cài service, ghi `/etc/zmrig/config.json` | 5–10 phút, phần lớn là biên dịch |
| [B. Container](#b-container) | server, NAS, Kubernetes, máy đã có sẵn docker | không gì ngoài container | 1 phút |
| [C. Ảnh boot](#c-ảnh-boot) | rig chuyên dụng, hoặc máy không muốn cài gì | một USB, hoặc chính ổ đĩa của rig | 5 phút |

Cả ba chạy cùng một miner và cùng một engine hash. Khác nhau ở chỗ chúng để lại
gì trên máy.

## Trước tiên, ví

Sai ví là mất tiền, mà địa chỉ Monero dài 95 ký tự và có checksum — gõ sai một
ký tự thì không có gì báo cho đến khi pool từ chối. Kiểm tra trước khi đưa nó vào
config:

```bash
zmrig --check-wallet 4YourMoneroAddress
```

Nó in ra loại địa chỉ, network, và hai khoá spend/view; nếu không dùng được thì
in đúng lý do. Chưa build miner thì để container làm hộ:

```bash
docker run --rm -e WALLET=4YourMoneroAddress ghcr.io/molik-labs/zmrig check
```

Installer và image chạy đúng phép kiểm tra này trước khi ghi bất cứ thứ gì, nên
ví sai sẽ hỏng ở bước setup chứ không phải ở lần trả tiền đầu tiên.

## A. Một lệnh

```bash
curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress
```

Nếu đã clone repo thì `sudo ./oneclick.sh --wallet 4YourMoneroAddress` là như
nhau. Installer cài phụ thuộc build, đo máy để chọn số thread, tinh chỉnh host,
ghi config, tạo `zmrig.service` và in hashrate nó vừa đo.

Trước khi nó đụng vào máy, hỏi nó định làm gì:

```bash
./oneclick.sh plan
```

Mấy cờ cần biết ngay từ đầu:

| Cờ | Vì sao |
| --- | --- |
| `--pool HOST:PORT` | pool; tên ngắn như `supportxmr` cũng được |
| `--rig-id NAME` | tên máy này trên dashboard của pool |
| `--profile free\|watt` | hashrate tối đa, hoặc hashrate trên watt tối đa |
| `--max-temp 70` | ghi đè mặc định an toàn 80 °C; bớt thread khi CPU nóng lên |
| `--donate-level 3` | phí developer, `0`..`10`; `0` là tắt |

Còn lại ở [toàn bộ tuỳ chọn của installer](/docs/install/installer).

## B. Container

Một lệnh, không build, không service trên host:

```bash
docker run -d --name zmrig --restart unless-stopped \
  -e WALLET=4YourMoneroAddress \
  -e POOL=gulf.moneroocean.stream:10001 \
  -e WORKER=rig-01 \
  ghcr.io/molik-labs/zmrig
```

Container đọc đúng những tên mà image ghi vào `/etc/zmrig/os.conf`, nên `MODE`,
`THREADS`, `DONATE`, `SAFE_TEMP`, `MSR`, `API_PORT` và `EXTRA_ARGS` đều dùng
được. Trên một server dùng chung, hai biến sau là quan trọng:

* `--cpus=2` là hạn mức (quota), không phải số core. Container đọc chính hạn mức
  cgroup của nó và chặn số thread theo đó, vì một quota bị chia cho quá nhiều
  thread sẽ chậm hơn ít thread chạy hết tốc lực.
* `API_PORT=18080` bật API giám sát, và nó chỉ nghe ở loopback bên trong
  container — muốn mở ra thì mở có chủ ý: `-p 127.0.0.1:18080:18080`.

Khi log báo số thread ít hơn số core của máy, hỏi container xem nó đã nói gì với
miner:

```bash
docker run --rm -e WALLET=4YourMoneroAddress ghcr.io/molik-labs/zmrig args
```

Lệnh đó cũng nói ra hai lý do phía container khiến rig đào chậm hơn cái máy bên
cạnh: host chưa giữ huge page (khoảng 18 % hashrate, đã đo — `sysctl -w
vm.nr_hugepages=1168` trên host là xong, container không cần cờ nào), và thiếu
`/dev/cpu/*/msr` cho preset prefetcher.

Mọi biến môi trường ở [tài liệu container](/docs/install/docker).

## C. Ảnh boot

Một cái rig chỉ để đào thì không cần một distribution đa dụng. Ảnh này là một
kernel, một root Alpine chỉ đọc có `zmrig` và công cụ điều khiển, không có gì
khác chạy:

```bash
# manifest cho mức CPU của máy, rồi tới ISO mà nó chỉ ra
curl -fsSLO https://github.com/MoLik-Labs/ZMRIG/releases/download/os-beta/zmrig-os-beta-x86-64-v3.json

# ghi ra USB — file ISO lấy từ trang releases
sudo dd if=zmrig-os-<version>-x86-64-v3.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot rig, trả lời câu hỏi về ví, thế là nó đào. Không ghi gì lên máy, nên một
cái USB dựng được cả trăm máy.

Rig có ổ đĩa riêng thì nên cài hẳn, và cùng ảnh đó làm được:

```bash
zmrig-os install --disk /dev/nvme0n1   # chia phân vùng, copy, boot từ ổ đĩa
```

Cả hai dạng đều cấu hình được bằng một lệnh khi không có bàn phím:

```bash
zmrig-os setup --wallet 4YourMoneroAddress --pool gulf.moneroocean.stream:10001 --mode max
```

Ảnh, các mode và luật lưu trạng thái ở [hướng dẫn appliance](/docs/appliance/iso).

## Chạy được chưa

Năm bước, theo đúng thứ tự này. Mỗi bước trả lời một câu khác nhau, và ba bước
đầu chỉ mất mười giây.

| Kiểm tra | Lệnh | Kết quả tốt trông thế nào |
| --- | --- | --- |
| Có đang chạy không? | `sudo ./oneclick.sh status` | service ở trạng thái `active`, hashrate vượt qua `warming up` |
| Engine hash có khớp vector chuẩn không? | `sudo ./oneclick.sh verify` | các dòng `PASS`, rồi `verified` |
| Phí có đúng như tài liệu nói? | `sudo ./oneclick.sh verify` | `fee audit: one wallet, Monero only, switchable off` |
| Máy này đã được bố trí đúng chưa? | `zmrig-os doctor` | mọi dòng `ok`; dòng khác thì nó chỉ ra máy, không chỉ ra triệu chứng |
| Nhanh đến đâu, đo thật? | `zmrig --bench=20000` hoặc `zmrig-os bench` | một con số H/s, đo tại chỗ, so được với [bảng benchmark](/docs/reference/benchmarks) |

`status` chỉ báo số đã đo: miner vừa khởi động sẽ hiện `warming up` chứ không đọc
lại hashrate của lần chạy trước, vì dataset cần 15–25 giây để dựng.

Bước nào hỏng thì tra ở [khi có gì đó sai](#khi-có-gì-đó-sai).

## Cập nhật

| Cách | Lệnh | Cái gì còn lại sau khi cập nhật |
| --- | --- | --- |
| A. Một lệnh | `sudo ./oneclick.sh update` | config, service, tinh chỉnh; binary được build lại |
| B. Container | `docker run --rm ghcr.io/molik-labs/zmrig update --check` rồi pull và tạo lại container | không gì bên trong container — đó chính là ý đồ |
| C. Ảnh, USB live | `zmrig-os update --apply` | đến lúc reboot; USB live là chỉ đọc theo thiết kế |
| C. Ảnh, đã cài lên đĩa | `zmrig-os update --apply` | ghi xuống đĩa và ở lại |

`update --check` trả `0` khi đang là bản mới nhất, `3` khi có bản mới hơn và `2`
khi không xác định được — bộ hẹn giờ cập nhật đọc đúng mã này.

## Phí 3 %, và cách audit

Engine Zig dành 3 % thời gian đào Monero cho ví của developer. Engine C++ không
lấy gì. Con số đó được ghi thẳng vào config chứ không phải ngầm hiểu, và có ba
cách độc lập để kiểm tra — không cách nào cần tin trang này:

```bash
zmrig --check | grep donate        # rig này thật sự sẽ làm gì
sudo ./oneclick.sh verify          # audit của chính installer
./scripts/verify-fee.sh --source-only   # đọc hằng số từ mã nguồn
```

Lệnh cuối đọc `fee.default_percent` trong `zmrig/src/fee.zig` và fail nếu có bất
kỳ trang nào trong repo này nói khác, kể cả trang bạn đang đọc.

Muốn đổi thì nói ngay ở chỗ ghi config:

```bash
sudo ./oneclick.sh config --donate-level 0     # rig này, không phí
docker run -e DONATE=0 ...                     # container
zmrig-os setup --donate 0                      # appliance
```

`11` bị từ chối, và một chữ cũng vậy: miner chỉ nhận `0`..`10`, nên một giá trị
nó sẽ từ chối phải lộ ra ở bước setup chứ không phải lúc boot.
[Trang về phí](/docs/reference/fee) có bảng theo từng mức và đoạn code thực thi.

## Nhiều hơn một rig

Mỗi rig cần một cái tên riêng, nếu không dashboard của pool sẽ hiện một máy với
số liệu cộng lại không khớp:

```bash
sudo ./oneclick.sh install --wallet 4... --rig-id rig-02   # cách A
docker run -e WORKER=rig-02 ...                            # cách B
zmrig-os setup --wallet 4... --worker rig-02               # cách C
```

Sau đó, muốn gom về một chỗ: `zmrig-os id` in Device ID để đăng ký, và
`zmrig-os fleet --url https://your-fleet` trỏ rig vào bot Telegram. Cả hệ thống
điều khiển ở [cả một fleet](/docs/fleet/telegram); installer có sẵn vòng lặp cho
mười máy trong [cài không cần người](/docs/install/installer).

## Khi có gì đó sai

| Hiện tượng | Nguyên nhân thường gặp | Làm gì |
| --- | --- | --- |
| `the miner rejected the generated config` | ví có ký tự không thuộc base58 | `zmrig --check-wallet 4...`, rồi cài lại với địa chỉ sạch |
| pool ban IP này | ví sai, hoặc reconnect quá nhiều | chờ hết cooldown; ví sai bị chặn tối thiểu 30 phút |
| hashrate chỉ bằng một phần tư bảng benchmark | không có huge pages (container hoặc VPS OpenVZ) | `zmrig --check` báo số trang; hỏi nhà cung cấp về trang 2 MiB |
| máy ồn và nóng | mục tiêu đang cao so với tản nhiệt | `--max-temp 70`, hoặc `zmrig-os setup --max-temp 70` |
| container dùng ít thread hơn số core | có hạn mức `--cpus` | `docker run ... args` rồi đọc `-t` nó đã chọn |
| service khởi động lại liên tục | có người sửa config | `sudo journalctl -n 60 -u zmrig`, đọc dòng đầu sau khi binary khởi động |

Bảng đầy đủ, kèm dòng log để nhận ra từng trường hợp, ở
[lỗi thường gặp](/docs/operate/troubleshooting).

## Những con số này từ đâu

Không có gì trên trang này chép từ trí nhớ. Các lệnh được đối chiếu với chính
script thực thi chúng, và con số phí đối chiếu với hằng số trong mã nguồn, bởi
`tests/docs/setup-page.sh`, nên một subcommand bị đổi tên sẽ làm fail test chứ
không làm fail terminal của bạn. Chỗ nào trong môi trường này không đo được thì
trang không in con số đó — xem [cách repo này được kiểm thử](/docs/development/testing).
