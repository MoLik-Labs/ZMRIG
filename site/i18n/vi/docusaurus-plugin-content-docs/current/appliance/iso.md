---
title: Ảnh khởi động (ISO)
description: Ảnh ZMRIG OS live — ghi ra USB, trả lời một câu, máy đào ngay. Không cài gì, không ghi gì lên ổ, mọi thứ đều chỉnh được.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Ảnh khởi động

`zmrig-os` là một hệ điều hành đào coin hoàn chỉnh: nhân Linux, một initramfs
nhỏ, và root filesystem Alpine chỉ đọc bên trong có `zmrig` và gần như không có
gì khác. Ghi ra USB, khởi động dàn máy, gõ ví — thế là đào. Không phải cài gì,
không sửa gì trên máy.

Nếu không muốn phụ thuộc vào cây USB thì cùng ảnh đó cài được thẳng lên ổ của
máy bằng một lệnh, sau đó nó tự lo phần còn lại:

```bash
zmrig-os install --disk /dev/nvme0n1   # chia ổ, copy, khởi động từ ổ
```

[Cài lên ổ](#cài-lên-ổ) và [Cập nhật](#cập-nhật-tự-động) bên dưới là toàn bộ câu
chuyện; phần còn lại của trang là ảnh làm gì và đổi bằng cách nào.

```bash
# tải ảnh đúng loại CPU ở trang releases, rồi
sudo dd if=zmrig-os-<version>-x86-64-v3.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Có hai bản. `x86-64-v3` cần AVX2 (mọi CPU x86 từ khoảng 2015) và là bản mặc
định; `x86-64-v2` chạy trên mọi thứ từ Nehalem. Ảnh được biên dịch cho đúng một
mức lệnh, và trình cập nhật không bao giờ đưa nhầm bản kia.

## Lần khởi động đầu

1. GRUB hiện ra; mục mặc định là *max hashrate*.
2. Console hiện banner ZMRIG và hỏi địa chỉ Monero.
3. Dán ví, Enter, và dòng hashrate bắt đầu sau vài giây.

Địa chỉ được kiểm trước khi dùng: 95 hoặc 106 ký tự, bảng chữ base58, bắt đầu
bằng `4` hoặc `8`. Ví gõ nhầm chữ `0` hay `l` — đúng hai ký tự mà base58 loại bỏ
vì dễ đọc sai — sẽ bị từ chối thay vì đào vào hư không.

## Không bàn phím, và cả fleet

Dàn máy không có bàn phím thì cấu hình bằng dòng lệnh nhân. Nhấn `e` ở mục GRUB,
hoặc sửa `grub.cfg` trên ảnh của fleet:

```
zmrig.os.wallet=4...
zmrig.os.pool=gulf.moneroocean.stream:10001
zmrig.os.worker=rig-07
zmrig.os.mode=max
zmrig.os.maxtemp=70
```

`zmrig.os.maxtemp` là giới hạn nhiệt độ cho chế độ `safe` và cho bất kỳ chế độ nào
bật bộ điều tiết.

Khi đã có ví thì wizard không hiện nữa. `zmrig.os.nostart=1` khởi động máy mà
không đào — đúng thứ một USB cứu hộ cần.

## Các chế độ

Mức "hung hăng" của miner là một từ, đổi được khi đang chạy:

```bash
zmrig-os mode eco       # khởi động lại với nửa số core và profile watt
zmrig-os mode safe 70   # ... và không để CPU vượt 70 C
zmrig-os status         # đang đào gì, tốc độ bao nhiêu, nóng bao nhiêu độ
```

| Chế độ | Thread | Ưu tiên | Profile | Huge pages | Dùng khi |
| --- | --- | --- | --- | --- | --- |
| `max` | theo cache, tất cả core | 5 | free | đặt trước lúc boot | mặc định |
| `balanced` | core − 1 nếu từ 4 core | 3 | free | đặt trước lúc boot | máy bạn còn ssh vào |
| `eco` | nửa số core | 1 | watt | THP `madvise` | êm và mát |
| `safe` | core − 1 nếu từ 4 core | 19 (nice) | watt | đặt trước lúc boot | máy không được phép hỏng |
| `light` | tất cả core, cache 256 MiB | 2 | free | không | máy dưới 2,5 GiB RAM |

Mỗi chế độ có một mục GRUB riêng, nên máy không mạng và không bàn phím vẫn đổi
được: chế độ đi theo dòng lệnh nhân và được áp ngay lúc boot.

### Chế độ an toàn

`safe` là chế độ duy nhất coi nhiệt độ của máy là **giới hạn**, không phải hệ quả.
Nó để một core cho hệ điều hành và bộ điều khiển quạt, hạ xuống mức ưu tiên thấp
nhất có thể, không bao giờ ghi vào thanh ghi MSR, và bật bộ điều tiết nhiệt của
miner ở 72 °C (đổi bằng `zmrig-os mode safe 68`):

```text
zmrig-os status
  mode           safe (max 72 C)
  thermal        64 C
```

Bộ điều tiết chạy mỗi giây trên thread monitor của miner. Ở 72 °C nó treo một
thread (tối đa 30 giây một lần), ở 80 °C treo ngay (tối đa 5 giây một lần), ở
87 °C thì dừng đào hẳn, và khi máy nguội thì leo lại từng thread một, mỗi bước
cần hai phút mát. Không có gì bị dựng lại: thread bị treo giữ nguyên VM, dataset
nằm trong RAM và kết nối pool vẫn mở — một buổi chiều nóng chỉ mất đúng số share
không tính được, không mất gì khác.

Nó chỉ đọc cảm biến của CPU (`coretemp`, `k10temp`, `zenpower`, `cpu_thermal`,
`acpitz`, chip Super I/O), nên NVMe ấm không làm mất thread nào. Máy không có
cảm biến thì nói một lần rồi giữ nguyên số thread được giao.

Với laptop, máy dùng chung ở cơ quan, hay bất kỳ rig nào mà chủ máy sẽ nhận ra
khi nó hỏng, đây là chế độ nên chạy. Nó mất vài phần trăm hashrate đỉnh lúc 20 °C
và đổi lại là không phải sống những giờ nóng trong trạng thái bị phần cứng tự hạ
xung mà mình không kiểm soát được.

## Cài lên ổ

Cây USB là thứ cố ý dùng một lần: `/etc/zmrig` nằm trong RAM và reboot là quên.
Máy đã cài là nửa còn lại của sự đánh đổi đó.

```bash
zmrig-os install --disk /dev/nvme0n1 --dry-run   # xem trước sẽ làm gì
zmrig-os install --disk /dev/nvme0n1             # làm thật
```

Ổ bị chia lại, không chia sẻ:

| Phân vùng | Kích thước | Nội dung |
| --- | --- | --- |
| BIOS boot | 1 MiB | `core.img`, cho máy boot kiểu BIOS |
| EFI | 100 MiB | `BOOTX64.EFI`, cho UEFI |
| root | phần còn lại | nhân, initramfs, `rootfs-a.squashfs`, cấu hình |

Sau đó nó copy, đọc lại đúng thứ vừa ghi (mount lại phân vùng mới và băm
squashfs) rồi in *rút USB ra và khởi động từ ổ*. Trên máy không có gói
bootloader nào: hai ảnh GRUB được build lúc build ISO và đi kèm trong ISO, nên
việc cài không cần mạng và không cần `grub-install`.

Mọi thứ sau đó là tự động: miner tự chạy, cấu hình được giữ, số thread được đo
ngay trên máy sẽ đào, và job cập nhật hằng ngày đã bật sẵn.

### Không cần bàn phím: Ventoy và fleet

Thêm một tham số vào mục boot rồi đi làm việc khác:

```
zmrig.os.install=/dev/nvme0n1
```

Máy tự cài, reboot vào ổ của nó và bắt đầu đào. Với Ventoy: chọn ISO, bấm `e`,
thêm tham số. Với fleet: cùng tham số đó trên mọi máy, chỉ đổi tên ổ theo model.

## Cập nhật tự động

Máy đã cài kiểm tra mỗi ngày một lần, bằng busybox `crond`
(`/etc/periodic/daily`), nên không có systemd timer và không có gói nào phải
giữ cho sống.

```bash
zmrig-os auto --check    # có bản mới hơn không?
zmrig-os auto --apply    # làm ngay thay vì đợi 03:00
```

- **Miner** được ghi cạnh hệ thống đang chạy, không ghi vào `/usr/local/bin` —
  thư mục đó là RAM, cập nhật vào đó chỉ sống tới lần reboot sau. Bản cũ được
  giữ lại, và miner được restart sang bản mới.
- **Ảnh hệ điều hành** (`AUTO_IMAGE=1`, mặc định tắt) được ghi vào slot *kia*,
  kiểm tra rồi mới thành mặc định cho lần boot sau.
- **Bản cập nhật không boot được thì tự lùi.** Initramfs đếm số lần boot mà máy
  không trở thành một rig đang đào; ba lần thì nó chuyển sang slot kia và reboot.
  `zmrig-os slot` xem cả hai, `zmrig-os slot b` chọn một.
- `AUTO_UPDATE=0` tắt toàn bộ. Không với tới được manifest nghĩa là "đang offline",
  không phải lỗi: rig vẫn đào và job thoát 0.

## Ảnh làm những gì mà distro thường không làm

Phần khó nhất của RandomX là bộ nhớ, và hệ điều hành quyết gần như toàn bộ. Trên
một bản cài đặt đa dụng, mỗi mục dưới đây là một cuộc chiến với gói cập nhật
hoặc một unit systemd. Ở đây chúng là mặc định:

- **Trang 2 MiB được đặt trước bởi initramfs**, trước khi bất kỳ chương trình
  nào làm phân mảnh bộ nhớ. Đó là +4–6 % cộng thêm trên transparent huge pages,
  và là bước gần như không thể làm lại vào cuối ngày.
- **Transparent huge pages vẫn bật** (`always` ở các mục max). Tắt nó mất khoảng
  28 % — đã đo, xem [Hiệu năng](/docs/operate/performance).
- **CPU governor là `performance`**, do đúng bước đặt trước bộ nhớ thiết lập,
  trước khi miner chạy.
- **`swappiness=1`** để dataset 2,3 GiB không bao giờ bị đẩy ra swap; **giới hạn
  write-back** để một lần xoay log không chặn thread đào; **giữ 64 MiB trống**
  để cấp phát đột ngột không kích hoạt reclaim giữa lúc hash;
  **`zone_reclaim_mode=0`** để máy nhiều socket không khựng ở một node;
  **tắt NMI watchdog**, vì chưa ai từng phát hiện được gì nhờ nó trên dàn đào.
- **Không chạy gì khác.** Không desktop, không daemon cập nhật, không telemetry.
  OpenRC, sshd, chrony và miner.
- **Binary tĩnh** (musl, một file 19 MB không phụ thuộc libc), nên cập nhật ảnh
  không làm hỏng nó, và chép sang distro nào cũng chạy.

## Ổn định

Chạy lâu không phải một tính năng mà là một chuỗi:

- miner tự thoát khi bị treo hoặc khi share bị từ chối liên tiếp
  (`--health-restart`, 900 giây), và ghi lý do vào log;
- `zmrig-os run` khởi động lại sau 10 giây, mãi mãi;
- năm lần thất bại liên tiếp thì máy reboot, vì lúc đó thứ hỏng là hệ điều hành;
- log xoay ở 8 MB, nên máy đào một năm vẫn khởi động được;
- chrony giữ đồng hồ đúng, vì đăng nhập pool qua TLS sẽ hỏng nếu lệch giờ.

`zmrig-os doctor` in ra mọi kiểm tra mà lúc boot đã làm, kèm giá trị đọc được:

```
  PASS  binary                 zmrig 6.36.0 - ZMRIG by @nggkhaiz
  PASS  wallet                 46SQLW7D...ysb5tJ
  PASS  memory                 32044 MB total, need 2400 MB
  PASS  hugepages              1168 x 2 MB reserved
  PASS  thp                    always
  PASS  governor               performance
  WARN  msr                    not applied (VM, or no msr module)
  PASS  swap                   off
  PASS  dns                    gulf.moneroocean.stream resolves
  PASS  config                 miner --check passed
```

## Đo đúng máy này

Số thread là con số duy nhất khác nhau theo từng máy, và heuristic theo cache giả
định 2 MiB L3 cho mỗi thread. Hãy để máy tự trả lời:

```bash
zmrig-os autotune 8     # 8 giây mỗi ứng viên, số thread thắng được ghi vào config
```

Kết quả được ghi vào `os.conf`; `THREADS="auto"` quay lại heuristic.

## Giữ lại cấu hình

Trên máy đã cài thì không cần bước này: cấu hình nằm trên ổ và tự quay lại. Trên
cây USB live, root filesystem chỉ đọc nên cấu hình nằm trong RAM và mất khi
reboot; một phân vùng nhỏ giải quyết việc đó:

```bash
zmrig-os persist /dev/sdb1      # format, gắn nhãn ZMRIGDATA, chép cấu hình
```

Initramfs tìm nó theo nhãn ở mỗi lần boot và chép `os.conf` cùng
`/root/.ssh/authorized_keys` vào.

## Giám sát mà không cần dashboard

Ảnh không có web UI, và đó là chủ ý — một web app là thêm một thứ phải vá. Thứ nó
có là JSON API của chính miner, mặc định tắt:

```
API_PORT="18080"
API_HOST="0.0.0.0"
API_TOKEN="một chuỗi ngẫu nhiên dài"
```

Với ba dòng đó, `http://rig:18080/2/summary` trả lời cho ai có token — đúng thứ
một dashboard fleet, Home Assistant hay một lệnh `curl` trong cron cần. Để
`API_HOST` là `127.0.0.1` thì API chỉ nằm trong máy.

## Cập nhật, làm tay

Job tự động ở trên dùng đúng những lệnh này; đây là bản làm tay:

```bash
zmrig-os update --check                  # bản nào đang phát hành cho kênh này
zmrig-os update --apply                  # binary 19 MB, kiểm sha256, thay tại chỗ
zmrig-os update --iso --write /dev/sdb1  # ghi ảnh mới ra USB khác
```

Trên **cây USB live**, `--apply` vá vào ảnh đang chạy và mất khi reboot — reboot
là quay lại đúng bản đã ghi trong ảnh; toàn bộ quy trình rollback là vậy, không
cần menu. Trên **máy đã cài** nó nằm trên ổ và sống qua reboot. `--iso` từ chối
ghi vào thiết bị mà máy đang boot từ đó.

Kênh: `stable` theo bản phát hành từ master, `beta` theo bản pre-release luân
phiên. Cả hai phát hành manifest riêng cho từng mức lệnh CPU, và đó là thứ trình
cập nhật đọc.

## Bảo mật

- Console là shell root tự đăng nhập — wizard cần thế, và chạm được vào dàn máy
  thì đã là root rồi. Mọi điểm dưới đây tồn tại vì điều đó đúng.
- SSH **chỉ dùng khoá**: `PermitRootLogin prohibit-password`, không mật khẩu,
  không keyboard-interactive. `zmrig-os ssh-key add` rồi `rc-service sshd start`.
- Không có trình quản lý gói nào chạy lúc vận hành: ảnh là thứ đã được build.
- Cập nhật được kiểm sha256 trước khi thay binary; sai thì báo lỗi và để nguyên
  file cũ.
- Không gọi về đâu cả. Lưu lượng ra chỉ là pool của bạn, NTP, và nếu bạn yêu cầu
  thì một lần kiểm tra cập nhật.

## Tự build

```bash
sudo ./os/deps.sh                 # xorriso, mtools, grub, squashfs-tools, qemu
sudo ./os/build-iso.sh            # → os/out/zmrig-os-<version>-x86-64-v3.iso
sudo ./os/build-iso.sh --smoke    # build rồi boot thử trong QEMU, đọc log
```

CI build lại ảnh mỗi khi `os/`, `zmrig/` hoặc `scripts/tune-linux.sh` đổi, và
mỗi bản phát hành giữ lại ISO của mình. Workflow cũng chạy trên pull request đụng
`os/`, nên ảnh hỏng sẽ fail trước khi merge. Bước build cũng phát hành manifest mà
`zmrig-os update` đọc, nên ảnh ngoài thực địa tiến lên được mà không phải ghi
lại USB.

## Không phải là gì

Không phải miner GPU. Không phải công cụ ép xung — timing bộ nhớ và điện áp là
việc của firmware. Không làm cho MSR ghi được trong máy ảo: hypervisor từ chối
và miner ở lại đường portable, điều mà `zmrig-os doctor` nói thẳng chứ không
giấu.
