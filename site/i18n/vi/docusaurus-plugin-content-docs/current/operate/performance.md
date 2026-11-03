---
title: Hiệu năng
description: Cái gì thật sự làm hashrate đổi trên CPU, cái gì không, và cách đo mà không tự lừa mình.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Hiệu năng

RandomX là proof-of-work phụ thuộc bộ nhớ: vòng hash đọc dataset theo thứ tự
ngẫu nhiên. Gần như mọi thứ quan trọng suy ra từ đúng một câu đó.

## Ba đòn bẩy thật sự

**Huge pages.** Mức lợi lớn nhất và rõ nhất. Trang 4 KiB làm mỗi vài lần truy cập
dataset lại thành một TLB miss. Có hai cách có trang 2 MiB và miner nói rõ nó
được cách nào: `huge pages … MB (explicit)` là pool đã đặt trước, còn
`huge pages: … MB via THP (…, measured by the kernel)` là transparent huge pages
đã gộp mapping — đọc từ `/proc/self/smaps_rollup`, không phải đoán. Cách thứ hai
là thứ một user thường nhận được trên kernel Ubuntu mặc định, và nó chiếm phần
lớn lợi ích: 786 H/s so với 615 H/s khi dùng trang 4 KiB trên máy test, trong khi
pool đặt trước cho 800–841.

```bash
echo 1168 | sudo tee /proc/sys/vm/nr_hugepages    # ~2.3 GiB trang 2 MiB, cho Monero
grep HugePages_ /proc/meminfo
```

Installer làm việc này và đặt `LimitMEMLOCK=infinity` trong unit. Con số này
không cố định: nó là cache cộng dataset của coin đang đào — 1168 trang cho
Monero, 96 trang cho Panthera/Scala (bảng bên dưới). `zmrig` tự tính mức đặt
theo từng thuật toán, và `zmrig-tune --algo=` ghi đúng con số đó, nên
`sudo zmrig-tune --algo panthera` chỉ đặt 192 MB chứ không phải 2.3 GB.

Kiểm tra miner có lấy được: log khởi động in số byte thật sự đến từ huge pages
tường minh (`huge pages 2336 MB (explicit)`), API trả
`"hugepages": [được cấp, cần]` — `[1168, 1168]` với `rx/0`, `[96, 96]` với
`panthera`.

:::warning Đo khi không có huge pages
Khi đã đặt 1234 trang, RAM thường chỉ còn khoảng 1.2 GB. Chạy `--no-huge-pages`
lúc đó sẽ bị OOM-kill (exit 137), vì dataset 2 GiB thứ hai không có chỗ. Đặt
`nr_hugepages` về 0 trước khi đo trường hợp đó, và nhớ đặt lại.
:::

**Chế độ fast hay light.** `fast` dựng một dataset dùng chung cho mọi thread.
`light` giữ cache và dựng lại từng dòng dataset cho mỗi hash: 82 H/s so với
849 H/s trên cùng máy, cùng phút, `rx/0` — chênh mười lần, không phải một lựa
chọn tiết kiệm điện. Một rig rơi về light mode không phải đang đào, nó đang chạy
không ở 10 %. Log khởi động nói nó chọn chế độ nào và vì sao, và `--check` in ra
quyết định đó trước khi bạn bắt đầu.

`--mode=auto` chọn chế độ nào là tuỳ **coin**, vì các coin không cùng kích thước.
Đây là số đo, không phải suy ra từ một hằng số:

| Thuật toán | Coin | Cache | Dataset | Tổng | Vừa VPS 1 GiB? |
| --- | --- | ---: | ---: | ---: | --- |
| `rx/0` | Monero | 256 MB | 2080 MB | 2336 MB | chỉ light |
| `rx/wow` | Wownero | 256 MB | 2080 MB | 2336 MB | chỉ light |
| `rx/arq` | ArQmA | 256 MB | 2080 MB | 2336 MB | chỉ light |
| `rx/graft` | Graft | 256 MB | 2080 MB | 2336 MB | chỉ light |
| `rx/sfx` | Safex Cash | 256 MB | 2080 MB | 2336 MB | chỉ light |
| `rx/yada` | YadaCoin | 256 MB | 2080 MB | 2336 MB | chỉ light |
| `panthera` | Scala (XLA) | 128 MB | 64 MB | **192 MB** | được |

Sáu nhánh RandomX có dataset cùng kích thước vì chúng chỉ đổi cấu hình chương
trình, salt argon và số vòng lặp; Panthera là một cấu hình khác (`ArgonMemory`
128 MB, `DatasetBaseSize` 32 MB).

`zmrig --check` in con số cho đúng thuật toán bạn hỏi, và dataset được cấp theo
cấu hình đã biên dịch chứ không theo `RANDOMX_DATASET_MAX_SIZE` — hằng số đó là
2 GiB, và dùng nó cho một dataset 64 MB là cách một VPS 512 MB từ chối khởi động
trên coin mà nó đào được.

**Số thread.** Một thread mỗi core vật lý, hai mỗi core chỉ khi SMT giúp: trên
máy test, hai thread trên hai vCPU cho 808–817 H/s, một thread 408 H/s, và bốn
thread trên hai core 798–801 H/s — chia quá số core không được gì. SMT thường
thêm 5–15 % hashrate với 30–40 % điện hơn, nên profile `watt` bỏ nó.

## Hai thứ không có tác dụng

- **Chế độ scratchpad prefetch** (0/1/2/3): 1208–1302 kH/s trên `panthera` — trong
  nhiễu. Mặc định (1) được giữ nguyên.
- **Affinity** trên máy 2 vCPU: không khác gì. Nó có ý nghĩa trên máy nhiều core
  với L3 không đều, đó là một phép đo khác.

Bất cứ thứ gì được quảng cáo là tăng tốc lớn mà không phải huge pages, chế độ
dataset hay số thread thì nên được đo trước khi tin.

## Số đo

2 vCPU Xeon 2.60 GHz, 3.9 GiB RAM, 1234 × 2 MiB huge pages, thuật toán `rx/0`,
mỗi cấu hình một lần chạy.

| Cấu hình | Hashrate | Tỉ lệ |
| --- | ---: | ---: |
| mặc định: 2 thread, đặt trước 1168 trang, prefetch 1 | 800–841 H/s | 100 % |
| như trên, không đặt trang nào (THP gộp mapping) | 786 H/s | 95 % |
| như trên, không đặt trang và THP tắt (4 KiB) | 615–626 H/s | 76 % |
| `--mode light` | 82 H/s | 10 % |
| `-t 1` | 408 H/s | 50 % |
| `-t 4` trên hai core | 798–801 H/s | 98 % (nhiễu) |
| `--scratchpad-prefetch=0/2/3` | 1208–1302 kH/s trên `panthera` | nhiễu |
| `--no-affinity` | 814 H/s | 100 % (nhiễu) |

Đo lại cho 6.33.0 ngày 2026-11-01 (ba lần `--bench=3000`, THP, hai thread):
**889 / 956 / 886 H/s** — đúng cấu hình của dòng 786 H/s, chỉ khác ngày. Hãy dùng
tỷ lệ, đừng dùng số tuyệt đối.

Cùng binary, cùng host, ở một phiên ít tải hơn: **1008–1103 H/s**. Độ tản 20–25 %
đó là lý do con số tuyệt đối trong tài liệu gần như vô dụng, và tỉ lệ ở trên mới
là phần dùng được.

Engine C++ trên cùng host, để tham chiếu: **1075.7 H/s**. Khoảng cách tới engine
Zig còn nhỏ hơn khoảng cách giữa hai lần chạy.

## Tự đo

```bash
zmrig --bench=20000      # seed cố định, blob cố định, không tính thời gian dựng dataset
zmrig --report --power 45   # 10 s warm-up + 15 s đo, in một mã
sudo ./oneclick.sh bench    # dừng service trước, rồi đo
```

Quy tắc để phép đo có nghĩa:

1. **Dừng miner trước.** Miner đang chạy giữ huge pages; benchmark sẽ cấp phát
   trong bộ nhớ thường và báo thấp khoảng 20 %.
2. **Đo đúng máy bạn quan tâm.** Hashrate tuyệt đối là thuộc tính của host, không
   phải của binary.
3. **Mỗi cấu hình chạy hai lần.** Dưới 2 % là nhiễu.

Bảng đầy đủ, kèm ngày và các lưu ý, ở [Hiệu năng đo được](/docs/reference/benchmarks).
