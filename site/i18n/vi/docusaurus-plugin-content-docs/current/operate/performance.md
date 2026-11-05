---
title: Hiệu năng
description: Cái gì thật sự làm hashrate đổi trên CPU, cái gì không, và cách đo mà không tự lừa mình.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Hiệu năng

RandomX là proof-of-work phụ thuộc bộ nhớ: vòng hash đọc dataset theo thứ tự
ngẫu nhiên. Gần như mọi thứ quan trọng suy ra từ đúng một câu đó.

## Bốn đòn bẩy thật sự

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
tường minh (`huge pages 2336 MB (explicit, 2 MiB pages)`), API trả
`"hugepages": [được cấp, cần]` — `[1168, 1168]` với `rx/0`, `[96, 96]` với
`panthera`.

**Có pool 1 GiB thì nó được dùng trước.** Dataset 2080 MB là 1 040 mục TLB ở
2 MiB và hai mục ở 1 GiB, nên bộ cấp phát hỏi trang gigantic trước, rồi tới pool
2 MiB, rồi tới bộ nhớ thường kèm gợi ý THP — và log nói cái nào đã trả lời
(`explicit, 1 GiB pages` so với `explicit, 2 MiB pages`). Đây không thể là thiết
lập lúc chạy: pool là bộ nhớ vật lý liền mạch và phải được lấy sớm lúc boot, nên
nó là tham số kernel.

```bash
sudo zmrig-os hugepages            # đang đặt bao nhiêu, lần chạy này cần bao nhiêu
sudo zmrig-os hugepages 1g 3       # dataset Monero là 3 trang; áp dụng lần boot sau
sudo zmrig-os hugepages off        # thôi đặt trước
```

Đặt pool gigantic **thay thế** phần đặt trước 2 MiB chứ không cộng thêm — ba
trang 1 GiB đã lấy 3 GB bộ nhớ vật lý liền mạch, và miner map pool nào đang có.
Log lúc boot và `zmrig-os tune` đều nói pool nào đang có hiệu lực.

Trên phần lớn máy ảo, pool không tạo được — ghi `nr_hugepages` dưới
`hugepages-1048576kB` báo thành công mà vẫn để 0 — và đó không phải lỗi: fallback
về trang 2 MiB là tự động, và phần lợi ích lớn (4 KiB lên 2 MiB) đã có sẵn — đo
trên máy kiểm thử ngày 2026-11-05, `--bench=2000`: **678,1 H/s trên trang 4 KiB so
với 913,2 H/s khi đã đặt pool 2 MiB (+34,7 %)**. Phần thêm 1-3 % thì **chưa đo được
trong môi trường đó**, vì ghi vào `nr_hugepages` báo thành công mà pool vẫn 0.

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

**Preset MSR.** Tắt bộ dò trước phần cứng của CPU chỉ tốn một lần ghi thanh ghi,
và đây là đòn bẩy duy nhất không miễn phí: cần root và module `msr`. RandomX đi
trong dataset một cách ngẫu nhiên, nên bộ dò đoán sai và đốt băng thông bộ nhớ cho
những dòng không ai cần. Mức tăng được công bố là **5–15 %** trên Zen và ít hơn
trên Intel; nó **chưa được đo trên máy này**, và con VM 4 lõi dùng để viết tài
liệu này không có MSR passthrough.

Từ 6.48 nó **bật mặc định** (`auto`): miner tự dò, áp preset khi máy chịu được, và
in đúng một dòng — trong log và trong `--check`. `--no-msr` là cách giữ
`/dev/cpu/*` không bị đụng tới, chế độ `safe` luôn làm vậy, còn máy đã cài ZMRIG OS
thì đã có root sẵn, nên preset đơn giản là được áp. Giá trị gốc được lưu và trả
lại khi thoát.

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
