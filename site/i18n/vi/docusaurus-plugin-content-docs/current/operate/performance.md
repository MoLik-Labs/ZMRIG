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

Bao nhiêu trang là câu hỏi về cái máy chứ không phải về Monero: phần đặt trước
không trả lại trong suốt thời gian rig chạy, nên `doctor` chỉ đề nghị một con số
khi vẫn còn 2 GiB cho nhân, page cache và shell. Trên máy 4 GB, nó nói máy không
dư trang nào thay vì in ra một lệnh để lại 1 GB cho mọi thứ khác.

Đặt pool gigantic **thay thế** phần đặt trước 2 MiB chứ không cộng thêm — ba
trang 1 GiB đã lấy 3 GB bộ nhớ vật lý liền mạch, và miner map pool nào đang có.
Log lúc boot và `zmrig-os tune` đều nói pool nào đang có hiệu lực.

Trên phần lớn máy ảo, pool không tạo được — ghi `nr_hugepages` dưới
`hugepages-1048576kB` báo thành công mà vẫn để 0 — và đó không phải lỗi: fallback
về trang 2 MiB là tự động, và phần lợi ích lớn (4 KiB lên 2 MiB) đã có sẵn — đo
trên máy kiểm thử ngày 2026-11-07, **đổi qua lại giữa hai cấu hình** để độ trôi
của chính cái máy không bị nhầm thành lợi ích: **897–900 H/s trên trang 4 KiB so
với 1090–1094 H/s khi đã đặt pool 2 MiB, +21,5 %**. Một cặp đo trước đó không đổi
qua lại đọc ra 678 so với 913 và sẽ tuyên bố +34,7 % — đó là thông lượng của máy
dao động 20 % giữa các giờ, không phải trang nhớ.

Phần thêm 1-3 % thì **chưa đo được trong môi trường đó**, vì ghi vào
`nr_hugepages` báo thành công mà pool vẫn 0. Preset MSR cũng vậy — chạy bằng root
thì kernel từ chối bằng `Input/output error`, đúng như một máy ảo không có MSR
passthrough, nên mức 5–15 % trên bare metal không được tuyên bố từ máy này.

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

## Đổi thuật toán tốn 16 giây, trừ khi dataset vẫn được giữ trong bộ nhớ

Một pool chở nhiều coin — MoneroOcean, và mọi rig `MODE=auto` trên pool đa thuật
toán — đưa rig qua lại giữa các nhánh RandomX mà không hỏi. Mỗi lần đổi trước đây
đều dựng lại dataset: 256 MB cache, rồi 2080 MB dựng theo cấu hình chương trình
của nhánh đó. Đo trên hai vCPU, `rx/0` nguội: **16 491 ms** không có hash nào, và
20 337 ms trong một ngày chậm hơn trước đó.

Dataset là một mapping chỉ đọc, nên không nhất thiết phải bỏ đi. Miner giờ giữ
dataset cũ trong bộ nhớ theo mặc định và nói rõ:

```console
info keeping the rx/0 dataset mapped (2336 MB) so a switch back costs nothing
info dataset ready in 374 ms
info switched to rx/0 without re-initialising: its dataset was still mapped
     (9 s old, built in 18259 ms, 1 initialisation(s) saved), hash engine ready immediately
```

Dòng log báo giá của chính dataset đó, không phải lần dựng gần nhất: trong vòng
đổi này lần dựng trước là của Panthera 348 ms, và in 348 ms cạnh một lần dựng
2 GiB là con số sai trong một cuốn log người ta tin.

Cùng máy, cùng pool, đi và về `rx/0 → panthera → rx/0`: 374 ms để sang dataset
Panthera 192 MB, **0 ms** để quay lại. Trong 135 s được 132 855 hash, so với
337 338 hash trong 125 s khi có cache và 99 973 khi không — dựng lại dataset không
phải trả một lần, mà là giá của mỗi lần đổi.

Không giữ thứ gì không vừa. Miner biết hạn mức bộ nhớ của container (cgroup chứ
không phải `free`), giữ tối đa hai dataset, và cần dataset đang chạy cộng 64 MB dư
vẫn còn vừa thì mới giữ thêm được — trên container 3 GiB, dataset Monero thứ hai
bị từ chối và log nói rõ, thay vì bị OOM killer giết giữa lúc đang tính share.

```bash
zmrig -o pool.example:3333 -u … --dataset-cache          # mặc định: vừa bao nhiêu giữ bấy nhiêu
zmrig … --dataset-cache=2048                             # giữ tối đa 2 GiB
zmrig … --no-dataset-cache                               # luôn dựng lại
DATASET_CACHE=off docker run …                           # như trên, trong container
```

Giữ cache chỉ đúng nếu hash vẫn đúng, nên nó đã được kiểm chứ không phải đoán:
ba share gửi sau một vòng đổi đầy đủ được đưa lại qua `--verify-share` với đúng
seed, blob và nonce của chúng và tính ra **giống hệt**. Bài test đó giờ là
`zmrig/tests/switch.sh` trong CI, ở cả trường hợp có cache và `--no-dataset-cache`,
vì lỗi nó bắt được là lỗi thật: cấu hình RandomX là toàn tiến trình, nên một
engine được giữ lại phải khẳng định lại cấu hình trước khi hash. Không phải sai
kích thước hay offset — mà là engine đang chạy theo chương trình của thuật toán
khác.

## Bao nhiêu phần trăm của giờ đồng hồ mới thật sự là đào

Dòng speed trả lời "nhanh đến đâu", không bao giờ trả lời "bao nhiêu phần thời
gian", và với tiền thì đó là hai con số khác nhau. Một rig hash 1 000 H/s trong
60 % số giây của một ngày thì kiếm được 60 % so với chính nó chạy đủ 100 % — mà
log thì trông hoàn hảo suốt cả ngày.

Miner lấy mẫu mỗi giây một lần (thread monitor vốn đã đọc bộ đếm hash), và nói ra
khi tiến trình dừng:

```console
$ zmrig -o pool.example:3333 -u …
info hashing 29 s of 44 s (65.9 %): 16 s building a dataset
```

Bốn loại, và chỉ một loại là lỗi:

| Loại | Nghĩa | Tốn gì |
| --- | --- | --- |
| hashing | bộ đếm có nhích trong giây đó | không gì cả |
| building a dataset | `randomx_init_dataset` đang chạy | 14–20 s với Monero, 0.3 s với Panthera |
| throttled | governor nhiệt đã cho một thread nghỉ (`--max-temp`) | một quyết định, không phải lỗi |
| no job | không hash và không có gì giải thích | tất cả thời gian nó phủ |

Nếu phút vừa rồi phần lớn là loại thứ tư thì có cảnh báo, thay vì một con số phần
trăm không ai đọc:

```console
warn hashing 41 % of the last minute: 22 s with no job (the pool is gone, or a reconnect is in flight)
```

### Phí phát triển, đo được

Cùng dụng cụ đó được chĩa vào đúng điều mà tài liệu về phí vẫn khẳng định mà chưa
từng đo: việc giao ví rồi lấy lại không tốn gì của người dùng. Một lần chạy 18
phút với `--donate-level=10` (để một phiên mở sau 10 phút thay vì 33 phút), trọn
một phiên, cùng máy 2 vCPU:

| | |
| --- | --- |
| đồng hồ | 1 099 s |
| đang hash | 1 084 s (**98.6 %**) |
| không hash | 16 s, lần dựng dataset lúc khởi động |
| share | 984 772 hash, 17 được nhận, 0 bị từ chối |
| phiên phí | nợ 60 s → 59 s đào cho ví nhà phát triển → quay lại, mất **0 s** |

Hai lần nối lại mà nó cần (một vào phiên phí, một về ví người dùng) không tốn gì
đo được, cùng lý do một pool rớt không tốn gì: worker vẫn hash job đang có cho tới
khi có job mới.

### Đo cả hai chiều

Một dụng cụ chỉ biết im lặng thì không đáng tin, nên nó được kiểm với hai pool
"xấu tính" trên cùng máy 2 vCPU:

| Pool | Hành vi | Kết quả |
| --- | --- | --- |
| cắt socket mỗi 5 s | 6–7 lần nối lại trong 45 s | mất **0 s**: worker vẫn hash job cuối trong lúc thread chính nối lại |
| nhận kết nối rồi không trả lời | không có job nào | `hashing 0 s of 24 s`, và dòng kết thúc nói rõ lý do |

Dòng đầu là thiết kế (pool chớp một cái không được làm mất một phút đào), và
trước đây nó chưa từng được đo. `zmrig/tests/duty.sh` khẳng định cả hai dòng ở
mỗi lần push.

Cùng phép đo đó trả lời câu "engine Zig có chậm hơn khi qua pool so với
`--bench` không": chạy xen kẽ trên máy rảnh cho **934–970 H/s** với `--bench` và
**928–961 H/s** qua pool — chênh lệch nằm trong độ tản giữa các lần chạy của máy
này (cùng binary cho 1 008–1 103 H/s vào một ngày yên tĩnh). Không có overhead
nào để đuổi theo ở đây.

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

## Bộ nhớ theo thời gian

Rò rỉ vài megabyte mỗi phút là một rig chết ba ngày sau khi cài, và log không nói
gì. Tám phút trên máy kiểm thử ở 1,2 kH/s, qua hai lần đổi seed và một lần đổi
thuật toán: RSS đi từ 2 408 lên 2 429 MB theo từng bước **và đi cả hai chiều**
(dataset được chạm lại), còn `VmData` và `VmPeak` thì không nhúc nhích — đó mới là
phép thử thật cho allocator. 1 422 share được nhận, 0 bị từ chối. Tám phút không
phải một tuần, nhưng nó loại bỏ được kiểu lỗi quan trọng: một cấp phát cho mỗi
share hoặc mỗi job mà không bao giờ trả lại.

## Hạn mức CPU không phải mặt nạ affinity

`docker run --cpus=2`, `systemd CPUQuota=200%` và `limits.cpu` của Kubernetes là
cùng một cơ chế: hạn mức CFS trên cả nhóm. Tiến trình vẫn thấy mọi CPU, nên số
luồng tính theo số CPU sẽ đòi quá mức — và khi hạn mức cạn, kernel dừng cả nhóm,
nên một luồng đang có scratchpad trong L3 ngồi chờ hết chu kỳ thay vì làm xong
phần chia của nó.

Miner đọc hạn mức (`cpu.max` ở cgroup v2, `cpu.cfs_quota_us` ở v1) và dùng nó làm
trần cho số luồng mặc định:

```console
$ zmrig --check
cpu quota: 1 cpu(s) available of 2 visible, using 1 thread(s)
profile free: 1 thread(s) of 2 logical cpu (2 physical cores)
```

`-t` do người dùng đặt thì không bao giờ bị hạ, và `--autotune` chỉ tìm trong phạm
vi hạn mức thay vì đo một con số bị throttle rồi coi đó là tốt nhất của máy. Image
container áp dụng đúng trần đó, nên `docker run … args` in ra số luồng miner thật
sự dùng.

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
