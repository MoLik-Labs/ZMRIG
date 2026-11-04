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

## Một lệnh, không hỏi gì

Wizard hỏi từng câu một, đúng cho người ngồi trước bàn phím. Còn khi ssh vào máy,
hoặc khi script provisioning dựng mười máy một lúc, thì cùng việc đó gói trong một
dòng:

```bash
zmrig-os quickstart --wallet 4... --pool gulf.moneroocean.stream:10001 --mode balanced
```

Nó kiểm ví và pool, ghi cấu hình, tinh chỉnh máy theo đúng thuật toán được đưa,
in Device ID rồi khởi động miner — và nói rõ miner có chạy thật hay không, đúng
phần mà script provisioning hay bỏ qua. `--coin` chọn thuật toán để tính dung
lượng bộ nhớ đặt trước, `--fleet` ghi danh rig với bot, `--no-start` dừng trước
khi đào.

Tham số sai bị từ chối trước khi ghi bất cứ thứ gì: pool thiếu cổng, chuỗi không
phải địa chỉ ví, chế độ không tồn tại.

## Giữ nhân hệ điều hành ra khỏi lõi đào

Một luồng đào bị scheduler đẩy sang CPU đang phục vụ ngắt của pool thì mất nhiều
hơn cái giá của một lần ngắt: scratchpad 2 MiB của nó nguội dần trong cache trong
khi lõi khác hâm nóng scratchpad của chính nó.

```bash
zmrig-os isolate 4     # bốn CPU logic dành cho đào
zmrig-os isolate       # xem đang giữ những CPU nào
zmrig-os isolate off   # trả lại
```

CPU được lấy theo từng cặp SMT nguyên vẹn, từ trên xuống, và không bao giờ lấy
cpu0 — đó là nơi ngắt và phần lớn luồng của nhân đổ về. Trên máy 4 lõi/8 luồng,
`isolate 3` cho bạn 2 CPU chứ không phải 3: CPU thứ ba là anh em sinh đôi của một
CPU ở lại với nhân, mà nửa lõi thì không phải là lõi đã tách. Lệnh in ra đúng tập
nó lấy được, không giả vờ lấy đúng như bạn xin.

Cả hai nửa đều được ghi, vì chỉ một nửa thì không mua được gì:

* tham số khởi động `isolcpus=`, `nohz_full=` và `rcu_nocbs=` — gộp vào GRUB
  environment block trên ổ đã cài và được mọi menu entry đã cài đọc
  (`${zmrig_extra}`), nên có hiệu lực từ lần boot sau; trên USB chỉ đọc thì in ra
  để bạn tự gõ;
* `--cpu-affinity` cho miner, và mặt nạ ngắt được dời sang các CPU còn lại mỗi
  lần supervisor khởi động.

`ISOLATE=4` trong `/etc/zmrig/os.conf`, hoặc `zmrig.os.isolate=4` trên dòng lệnh
nhân, để nó sống qua lần khởi động lại; `ISOLATE=0` trả máy lại cho `AFFINITY=auto`,
tức ghim miner vào toàn bộ lõi vật lý. Số luồng đi theo mặt nạ: rig `balanced` trên
máy mà miner chỉ được dùng ba lõi sẽ ghim ba luồng, không phải bảy.

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

### Nhân, ngắt và NUMA

`nproc` đếm cả hyperthread, mà RandomX không chạy trên hyperthread: hai luồng
trên một cặp sibling chia nhau đúng 512 KiB L2 của một nhân. Ảnh đọc topology của
kernel và chọn số luồng theo **nhân vật lý**, ghim miner vào đó bằng
`--cpu-affinity`, dồn ngắt và workqueue không ràng buộc về CPU 0 khi máy có từ 4
nhân trở lên, và tắt NUMA balancing ở các chế độ mà máy sinh ra để đào. Chế độ
light để kernel yên.

```
$ zmrig-os topology
cores      8 physical, 16 threads
mining on  0 1 2 3 4 5 6 7
affinity   0xff (--cpu-affinity)
threads    7 (THREADS=auto, mode balanced)
```

Trước đây `--mode balanced` trên máy đó xin 15 luồng — mỗi hyperthread một luồng —
vừa nóng vừa chậm hơn 8. `AFFINITY=off` trong `os.conf` (hoặc
`zmrig.os.affinity=off` trên command line) bỏ phần ghim nếu có lý do riêng.

### Máy nào chạy được

Fast mode của RandomX cần AVX2, AES-NI và 2 GB bộ nhớ cho dataset. Máy thiếu một
trong ba vẫn đào — chậm hơn nhiều lần — và điều đó nên được nói ra thay vì để
người dùng tự suy từ một con số hashrate không khớp với README.

```
$ zmrig-os hardware
cpu        Intel(R) Xeon(R) Processor @ 2.60GHz (1 cores, 2 threads)
flags      avx2 aes sha_ni
memory     3939 MB total
pages      2 MB (no 1 GB pages)
verdict    full: fast mode: AVX2 and AES, and room for the 2 GB dataset
```

| kết luận | nghĩa | nên làm gì |
| --- | --- | --- |
| `full` | có AVX2, AES, đủ chỗ cho dataset | không cần gì: `max` là miner chạy hết tốc của máy |
| `light` | có AVX2 và AES, dưới 2,4 GB | `--mode light`: vẫn đào, dataset không nằm gọn trong một mảng |
| `slow` | thiếu AVX2 hoặc thiếu AES | vẫn chạy và chậm hơn nhiều; CPU trước 2015 thì boot ảnh **x86-64-v2** |
| `small` | dưới 1,2 GB | không đào RandomX được — riêng scratchpad đã 256 MB mỗi thread |

Lệnh thoát khác 0 với `slow` và `small`, nên script cài cho cả trăm máy sẽ dừng
đúng cái máy không bao giờ nhanh thay vì thêm nó vào danh sách. `doctor` in cùng
kết luận đó thành một dòng mỗi lần boot.

### Cái USB, và cách để nó sống lâu

Một cây USB đào 24/7 suốt một năm là 8.760 giờ nằm trong một thiết bị vốn được
làm ra để chở một file văn bản qua phòng. Câu trả lời là: cây USB **không làm
việc** trong lúc rig đào.

**Sau khi boot xong, không có gì được ghi lên nó.** Root filesystem là squashfs
mount read-only, lớp ghi được xếp chồng lên trên là tmpfs trong RAM — log, file
ví, bản miner vừa cập nhật đều nằm ở đó. Đó cũng là lý do một lần reboot quên
cấu hình chưa persist, và lý do log có phình cũng không đầy được cây USB. NAND
mòn vì ghi; lúc chạy bình thường không có lần ghi nào.

Thứ thật sự chạm vào USB, và ghi bao nhiêu:

| | ghi gì | khi nào |
| --- | --- | --- |
| `zmrig-os install --disk` | toàn bộ ảnh, một lần | ngày bạn cài |
| cập nhật miner | ~19 MB vào phân vùng dữ liệu | `AUTO_UPDATE=1` (mặc định) và có bản mới |
| cập nhật ảnh | một slot, ~158 MB | `AUTO_IMAGE=1` (mặc định tắt) |
| `zmrig-os persist` | cấu hình, vài kB | khi bạn chạy nó |

Còn lại đều là đọc. Nên khối lượng thật của cây USB là vài lần đọc mỗi ngày,
không phải một năm ghi. Vậy câu
hỏi chuyển từ "độ bền" sang nhiệt, nguồn và controller rẻ tiền:

| Giữ cho | Vì sao |
| --- | --- |
| USB **mát** | nhiệt cao kéo dài làm mất khả năng lưu dữ liệu của NAND hơn hẳn việc đọc. Vỏ kim loại và một cổng tránh khí nóng của PSU là phần lớn của việc này |
| USB **nhỏ** | ảnh chỉ 158 MB, nên 8 GB là dư. Loại dung lượng lớn giá rẻ có controller tệ nhất |
| **nguồn** sạch | cửa sổ hỏng dữ liệu duy nhất là lúc cài hoặc lúc cập nhật ảnh. Một UPS, hoặc đơn giản là không rút dây giữa lúc cập nhật, đóng cửa sổ đó lại |
| **reboot** ít | mỗi lần boot đọc ~158 MB. Máy reboot ba lần một ngày làm cây USB vất vả hơn máy đào cả tháng — và hệ điều hành chỉ tự reboot sau năm lần miner khởi động hỏng liên tiếp |

**Ventoy** boot ảnh này đúng như một cây USB đã ghi: ISO là read-only và không có
gì bên trong bị sửa. Mọi điều trên giữ nguyên, thêm hai thói quen:

* **đừng bật persistence của Ventoy cho ảnh này.** Cấu hình thuộc về kernel
  command line (`zmrig.os.wallet=…`, `zmrig.os.pool=…`) hoặc file `os.conf` cạnh
  ảnh, còn fleet lấy phần còn lại từ roster. Persistence biến log thành những lần
  ghi lên USB — đúng thứ thiết kế này tránh.
* đặt `VTOY_DEFAULT_IMAGE` (kèm `VTOY_DEFAULT_IMAGE_FORCE=1`) để máy không bàn
  phím boot thẳng vào ảnh, và ít cập nhật bản thân Ventoy — đó là thứ còn lại duy
  nhất ghi lên USB.

**Cấu hình bền nhất không phải là USB.** Nếu máy có ổ SATA hoặc NVMe, chạy
`zmrig-os install --disk /dev/…` một lần: hệ điều hành chuyển sang ổ, cây USB
thành bộ cài cất trong ngăn kéo, và `zmrig-os update` có chỗ ghi hợp lý. Với một
fleet đang chạy, một cây USB dự phòng đã clone — ảnh cộng một file `os.conf` — là
toàn bộ phương án dự phòng.

Không tuyên bố ở đây: tuổi thọ tính bằng giờ. Nó phụ thuộc controller và nhiệt độ
phòng, và chưa được đo trong môi trường này.

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
  `zmrig-os slot` xem cả hai, `zmrig-os slot b` chọn một. Lần lùi đó *gộp* GRUB
  environment block chứ không ghi đè, nên các tham số nhân của máy —
  `isolcpus=`, `nohz_full=`, mức nhiệt trần — sống qua lần lùi. Rig quay về slot
  kia vẫn về đúng cấu hình của nó.
- **Bản cập nhật không có checksum thì bị từ chối.** Manifest ghi sha256 cho
  binary và cho ảnh; không có thì không cách nào phân biệt một file tải dở hay
  một trang captive portal với file thật, và cài đúng thứ đó làm miner thì tệ hơn
  là chậm một phiên bản. `zmrig-os auto` nói đúng một dòng rồi thoát 0, nên job
  hằng ngày vẫn im lặng.
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
- `zmrig-os run` khởi động lại sau 10 giây, rồi 20, 40, 80, 160, và từ lần thứ
  năm trở đi là năm phút: crash loop thường là do pool hoặc mạng, và kết nối lại
  mười giây một lần biến một lần mất mạng ngắn thành bão socket;
- một lần chạy sống được mười phút thì xoá bộ đếm đó, nên "năm lần liên tiếp"
  đúng nghĩa liên tiếp chứ không phải từ tháng trước;
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

Kết quả được ghi vào `os.conf`; `THREADS="auto"` quay lại heuristic. Lệnh này
tinh chỉnh máy trước — huge pages, THP, governor — vì đo trên một máy chưa tinh
chỉnh là trả lời sai câu hỏi.

**Và nó tự chạy.** Trên một rig chưa từng được đo, miner khởi động ngay và chín
mươi giây sau supervisor đo máy trong lúc máy vẫn đang đào. Kết quả được ghi vào
config và miner nạp lại đúng một lần. Không có lần boot nào ngồi chờ, không reboot,
và lần nạp lại đó không bị tính là một lần crash. `AUTO_AUTOTUNE=0` tắt nó đi, và
số thread bạn tự đặt sẽ không bao giờ bị ghi đè:

```
threads        auto (đang đo máy)
threads        8
```

### Khi rig không còn giữ nổi con số của chính nó

Một lần đo là một lời hứa về tương lai, và cái máy chỉ đôi khi giữ được lời hứa
đó: tản nhiệt đầy bụi, một thanh RAM bắt đầu lỗi, một tiến trình nền ai đó để
chạy. Không cái nào tự lên tiếng, và cả ba đều hiện ra giống nhau — hashrate thấp
hơn mức chính máy này đã đo.

Vì vậy ảnh lưu kết quả đo ngay cạnh số thread (`MEASURED_HS`, `MEASURED_THREADS`,
`TUNED_AT`) và so hai số đó mỗi mười lăm phút:

```
measured      1234 H/s at 4 thread(s), 6 h ago
```

Quy tắc cố tình dè dặt, vì một lần đo lại không cần thiết tốn hơn phần hashrate
mà nó đi tìm:

| Điều kiện | Vì sao |
| --- | --- |
| lấy hashrate 15 phút, không lấy 10 giây | dựng dataset hay nối lại pool làm cửa sổ ngắn nhảy loạn |
| thấp hơn 75 % mức đã đo | rig ở 90 % là rig đang có một ngày bình thường |
| mức đo được ít nhất 250 H/s | máy nhỏ thì hai lần chạy lệch nhau hàng chục phần trăm |
| cách lần đo trước ít nhất 6 giờ | lúc đo lại, rig chạy sai số thread khoảng 90 giây |
| vẫn đúng số thread mà lần đo đã chọn | con số do người đặt thì không bao giờ bị xét lại |

Khi cả năm điều kiện đúng, rig ghi lại nó thấy gì và đo lại. `zmrig-os doctor`
in đúng phép so sánh đó khi bạn muốn xem.

## Ảnh được build từ gì

| | |
| --- | --- |
| nền | Alpine Linux `latest-stable` — hiện là `3.22.x` — musl, OpenRC |
| kernel | `linux-lts` (`linux-virt` cho VM) |
| root filesystem | squashfs, zstd mức 19, block 1 MiB, chỉ đọc |
| initramfs | busybox + khoảng 30 module, zstd khi config của kernel nói nó giải nén được, ngược lại gzip |
| boot | GRUB, BIOS và UEFI, cả hai đều được build cùng ảnh |

Ảnh ghi bảng đó vào `/etc/zmrig/base`, và `zmrig-os version` in ra, nên một báo lỗi
tự mang theo nền của nó. `./os/upstream.sh` in đúng bảng đó từ mã nguồn, còn
`--check` trả lời câu hỏi build lại có thay đổi gì không — mirror Alpine phục vụ
`latest-stable`, nên lần build thứ Hai so nó với trường `alpine` trong manifest đã
phát hành thay vì cứ build lại cho chắc.

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

Bề mặt thứ hai, dành cho máy đọc, là bước kiểm sức khoẻ của chính ảnh:

```bash
zmrig-os doctor --json
```

Một object, mỗi kiểm tra một mục, và mã thoát khác 0 khi có mục hỏng:

```json
{"fail":1,"warn":3,"checks":[{"status":"ok","check":"wallet","detail":"46SQLW7D...ysb5tJ"}, ...]}
```

Đó là dòng để đưa vào cron hay một agent giám sát, vì nó không cần bóc tách văn
xuôi và không cần `grep` để biết quạt đã dừng hay ví vẫn còn trống.

## Một bot cho cả giá máy

Một cái USB boot cả trăm rig thì không nên cần bàn phím cho từng máy.
`zmrig-os fleet --url https://your-fleet` (hoặc `zmrig.os.fleet=` trên dòng lệnh
nhân) trỏ rig vào bot Telegram và Discord, và `zmrig-os id` in ra Device ID để
bạn nhập vào bot. Ví, pool, coin, chế độ và cập nhật sau đó đặt từ chat, và rig
im lặng sẽ tự báo.

[Điều khiển bằng Telegram và Discord](/docs/fleet/telegram) là hướng dẫn.

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
phiên dưới tag `os-beta`. Cả hai phát hành manifest riêng cho từng mức lệnh CPU,
và đó là thứ trình cập nhật đọc — nhưng hai kênh nằm ở hai chỗ khác nhau, vì
`releases/latest` không bao giờ trỏ vào một pre-release:

```
stable  https://github.com/MoLik-Labs/ZMRIG/releases/latest/download/zmrig-os-stable-x86-64-v3.json
beta    https://github.com/MoLik-Labs/ZMRIG/releases/download/os-beta/zmrig-os-beta-x86-64-v3.json
```

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

Năm bước, và bước nào cũng là một bước build chứ không phải một người phải nhớ:
một push build và boot cả hai kiến trúc trong QEMU; `master` phát hành
`v<version>` còn `BETA` phát hành bản cuốn chiếu `os-beta`, thay asset tại chỗ nên
link của một phiên bản không bao giờ chết; lần chạy thứ Hai hỏi
`os/upstream.sh --check` xem Alpine có đổi không và bỏ qua build nếu không; sau đó
job tải lại từng asset qua HTTPS và viết lại ghi chú kèm link; và job hằng ngày
trên từng rig cài miner, hoặc cả ảnh vào slot A/B còn trống với `AUTO_IMAGE=1`.

## Không phải là gì

Không phải miner GPU. Không phải công cụ ép xung — timing bộ nhớ và điện áp là
việc của firmware. Không làm cho MSR ghi được trong máy ảo: hypervisor từ chối
và miner ở lại đường portable, điều mà `zmrig-os doctor` nói thẳng chứ không
giấu.
