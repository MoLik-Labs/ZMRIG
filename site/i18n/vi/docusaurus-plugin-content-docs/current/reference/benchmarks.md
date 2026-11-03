---
title: Benchmark và tinh chỉnh
description: Cách đo, số đo trên VM 2 vCPU, những cài đặt thật sự làm hashrate đổi, và quy trình mười phút để tinh chỉnh một máy.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Benchmark và tinh chỉnh

## Cách đo

```bash
# một lần chạy đầy đủ: 20 000 hash, có cả thời gian dựng dataset
./zmrig/out/zmrig --bench=20000

# đo nhanh sau khi đổi cấu hình
./zmrig/out/zmrig --bench=15000

# số liệu cho dashboard (10 s warm-up + 15 s đo)
./zmrig/out/zmrig --report --power 45
```

`--bench` dùng seed cố định `00112233…`, blob 76 byte và target thấp nhất, nên mọi
lần chạy hash cùng một dữ liệu và kết quả so sánh được. Thời gian dựng dataset
(15–25 s) nằm ngoài cửa sổ đo.

Quy tắc để con số có nghĩa:

- **Dừng miner trước khi bench.** Miner đang chạy giữ huge pages; bench sẽ dựng
  dataset trong bộ nhớ thường và báo thấp hơn thực tế. `oneclick.sh bench` tự
  dừng và khởi động lại service để tránh chuyện này.
- **Đo trên chính máy đó.** Hashrate tuyệt đối phụ thuộc host; đừng so với bảng
  dưới.
- **Mỗi cấu hình chạy hai lần.** Dưới 2 % là nhiễu.

## Một VM 2 vCPU (Xeon 2.6 GHz, 1234 huge page 2 MiB)

| Cấu hình | Hashrate | So với mặc định | Nhận xét |
| --- | ---: | ---: | --- |
| Mặc định: 2 thread, đặt trước 1168 trang, prefetch 1 | 800–841 H/s | 100 % | điểm chuẩn, năm lần chạy |
| Không đặt trang nào, THP bật (Ubuntu mặc định) | 786 H/s | 95 % | thứ một user thường nhận được |
| Không đặt trang nào, THP tắt | 615–626 H/s | 76 % | trường hợp duy nhất đáng bỏ công chạy root |
| `--mode light` | 82 H/s | 10 % | chỉ khi thiếu RAM |
| `-t 1` | 408 H/s | 50 % | scale tuyến tính |
| `-t 4` trên hai core | 798–801 H/s | 98 % | chia quá số core không được gì |
| `--scratchpad-prefetch=0/2/3` | 1208–1302 kH/s (`panthera`) | — | trong nhiễu |
| `--no-affinity` | 814 H/s | 100 % | 2 vCPU, không khác biệt |

Cùng máy, cùng binary, ở một phiên ít tải hơn: **1008–1103 H/s**. Độ tản đó là
lý do mọi so sánh phải là tương đối.

Engine C++ trên cùng máy, cùng phiên: **1075.7 H/s** — khoảng cách tới engine Zig
nằm trong biên độ giữa các lần chạy, không phải một tuyên bố về hiệu năng.

## Ba cài đặt thật sự quan trọng

### 1. Huge pages

Hiệu ứng lớn nhất và rõ ràng nhất. RandomX đọc dataset 2 GiB theo kiểu ngẫu
nhiên, và trang 4 KiB nghĩa là TLB miss liên tục.

```bash
# đặt trước 1168 trang 2 MiB (≈2.3 GiB) — cỡ của rx/0, không phải của mọi coin
echo 1168 | sudo tee /proc/sys/vm/nr_hugepages
grep HugePages_ /proc/meminfo
```

Installer làm việc này và ghi vào unit systemd (`LimitMEMLOCK=infinity`). Kiểm
tra miner có lấy được: log khởi động in `huge pages … MB (explicit)`, API trả
`"hugepages": [được cấp, cần]` — `[1168, 1168]` với `rx/0`, `[96, 96]` với
`panthera`. Số trang đi theo coin: `panthera` cần 96 trang (192 MB) chứ không
phải 1168; `sudo zmrig-tune --algo panthera` ghi đúng con số đó, và `zmrig` tự
tính mức đặt của mình theo cùng cách.

### Ba trạng thái cỡ trang, đã đo

`--no-huge-pages` không phải cùng một phép thử với "chưa bao giờ đặt trang".
Miner này đặt `MADV_HUGEPAGE` cho mọi mapping nó tạo, nên trên kernel có
`transparent_hugepage=madvise` (mặc định của Ubuntu) một lần chạy không có quyền
root vẫn nhận trang 2 MiB, chỉ là không lấy từ pool. Ba trạng thái, `rx/0`, mỗi
cấu hình hai lần, cùng phiên:

| Số trang | Nguồn cấp | Hashrate |
| --- | --- | ---: |
| đặt trước 1168 | `MAP_HUGETLB` | 814.5 / 832.2 H/s |
| không đặt trang nào | THP gộp 99 % mapping | 785.9 / 786.1 H/s |
| không đặt trang nào, THP tắt | 4 KiB | 614.8 / 626.3 H/s |

Vậy bước quan trọng là 4 KiB → 2 MiB (≈ +28 %), còn pool đặt trước thêm 4–6 %
nữa. Đó là lý do miner chỉ đòi quyền root khi THP tắt, và tại sao log khởi động
in chính con số kernel đếm được (`huge pages: 2332 MB via THP (99 % of the
2336 MB mapping, measured by the kernel)`) thay vì tuyên bố rằng gợi ý đã có
tác dụng.

Cảnh báo thực tế: khi đã đặt 1168 trang, RAM thường còn khoảng 1.2 GB. Chạy
`--no-huge-pages` lúc đó sẽ bị OOM-kill (exit 137), vì dataset 2 GiB không còn
chỗ. Hạ `nr_hugepages` về 0 trước.

### Dựng dataset

Dataset 2 GiB là bài toán băng thông bộ nhớ, và là chỗ chờ lâu nhất của một rig.
Đo trên máy này, seed `00112233…`:

| Số thread khởi tạo | `dataset ready in` |
| --- | ---: |
| 1 | 42.9 s |
| 2 | 21.1 s |

Nên `--randomx-init=1` là cách làm một lần đổi seed mất gấp đôi thời gian, không
phải cách để chừa một core cho việc khác — mọi core đằng nào cũng đang chờ
dataset. Mặc định là dùng mọi thread phần cứng, kể cả khi đào được lệnh dùng ít
thread hơn (`-t 1` vẫn dựng bằng tất cả).

### 2. Chế độ fast hay light

`fast` dựng một dataset 2 GiB dùng chung cho mọi thread → 849 H/s trên máy 2 vCPU
này. `light` chỉ giữ cache 256 MiB và tính lại dataset cho mỗi hash → 82 H/s.

Gần 10 lần. `light` hợp lý khi VPS không đủ RAM, hoặc để thử nhanh một cấu hình
(khởi động 0.6 s thay vì 20 s).

### 3. Số thread

Tuyến tính trên máy này: 2 thread = 808–817 H/s, 1 thread = 408 H/s, 4 thread
trên hai core = 798–801 H/s. Không có điểm ngọt bí ẩn và không có gì trên số core
thật. Trên vCPU chia sẻ bị throttle, thêm thread có thể làm hashrate mỗi
thread giảm mà tổng vẫn tăng; đo là cách duy nhất để biết.

## Những cài đặt không tạo ra khác biệt đo được

- `--scratchpad-prefetch` 0/1/2/3: dưới 1.5 %, tức là nhiễu. Để mặc định.
- `--no-affinity` trên 2 vCPU: không gì cả.
- `--no-optimized-init`: ảnh hưởng thời gian dựng dataset, không ảnh hưởng
  hashrate.

Bỏ qua lời khuyên tăng `priority` để có hashrate cao hơn: priority đổi cách hệ
điều hành chia CPU, nó không làm phép tính nhanh hơn. Nó hữu ích khi máy còn làm
việc khác.

## Quy trình tinh chỉnh mười phút

```bash
# 1. trạng thái nền
sudo ./oneclick.sh stop
grep -E "HugePages_Total|HugePages_Free" /proc/meminfo

# 2. đo mặc định
./zmrig/out/zmrig --bench=15000

# 3. các biến thể, mỗi cái hai lần
./zmrig/out/zmrig --bench=15000 -t 1
./zmrig/out/zmrig --bench=15000 --no-huge-pages   # chỉ sau khi hạ nr_hugepages
./zmrig/out/zmrig --bench=15000 --mode light

# 4. giữ phương án thắng trong config, rồi khởi động
sudo ./oneclick.sh start
```

Ghi số đo kèm ngày và tên host. Sáu tháng sau bạn sẽ cần chúng.

## Nhiệt và điện

Hashrate không phải tất cả. Máy chạy 814 H/s ở 95 W tốt hơn máy 900 H/s ở 130 W.
Đo ở ổ cắm, hoặc đọc công suất package qua RAPL:

```bash
cat /sys/class/powercap/intel-rapl:0/energy_uj   # hai lần, cách nhau một giây
```

`zmrig --report` đọc giúp và ghi nguồn vào mã báo cáo (`pwsrc`: `rapl`, `hwmon`,
`user` hoặc `none`), kèm `hw` — số hash trên mỗi watt (hashrate cột 60 s chia cho
công suất). Đó chính là con số mà `--profile watt` tối ưu, nên nó có trong mã
thay vì để mỗi người tự chia.

| | hashrate | điện | H/W |
| --- | --- | --- | --- |
| `--profile free` | cao nhất máy làm được | cao nhất | thấp hơn |
| `--profile watt` | thấp hơn vài % (bỏ thread SMT) | thấp hơn 30–40 % ở phần SMT | cao hơn |

Hai dòng đó nói về hướng, không phải về máy của bạn: **không đo được công suất
bên trong container của repo này** (RAPL bị chặn), nên phần watt được suy ra từ
P ∝ V²·f và số liệu SMT đã công bố. Phần hashrate là đo thật. Trên máy có RAPL,
chạy `zmrig --report` với cả hai profile rồi so `hw` — lúc đó kết luận là của
bạn, với giá điện của bạn.

[Máy tính lợi nhuận](/docs/economics/profitability) đổi số watt đó ra tiền.
