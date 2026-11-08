---
title: Tham chiếu lệnh
description: Mọi cờ của zmrig, nhóm theo thứ nó tác động, kèm kiểm tra config, self-test và autotune.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Tham chiếu lệnh

`zmrig --help` in đúng danh sách này, nhóm giống hệt. Cờ có giá trị mặc định thì
hiện trong ngoặc vuông.

## Pool

```text
-o, --url=URL              tcp|tls|ws|wss, ví dụ wss://pool.example.com/monero
-u, --user=USER            địa chỉ ví hoặc login pool
-p, --pass=PASS            mật khẩu [x]
-a, --algo=ALGO            rx/0, rx/2, rx/wow, rx/arq, rx/graft, rx/sfx,
                           rx/yada, panthera — hoặc auto, khai báo cả họ RandomX
    --rig-id=ID            tên worker gửi lên pool
    --keepalive, --no-keepalive
    --transport=NAME       tcp | tls | ws | wss
    --cloudflare[=HOST]    wss://HOST:443/ sẵn cho mạng chỉ mở 443
    --ws-path=PATH         đường dẫn WebSocket
    --ws-origin=URL        header Origin lúc nâng cấp
    --tls                  TLS cho pool hiện tại
    --tls-ca=FILE          tin CA trong FILE
    --tls-insecure         nhận cho tương thích; việc xác thực vẫn bật
    --connect-to=H:P       dial địa chỉ khác, giữ SNI và Host
    --proxy=URL            http://user:pass@host:port hoặc socks5://host:port
    --retries=N            số lần thử mỗi pool [5]
    --retry-pause=N        giây giữa các lần thử [5]
    --ban-cooldown=N       giây bỏ qua một pool sau khi bị ban, bị từ chối ví
                           hoặc nhận thông báo pool đầy [900]
                           trường hợp từ chối ví bị kẹp tối thiểu 30 phút
    --check-wallet=ADDR    giải mã địa chỉ Monero - độ dài, bảng chữ base58,
                           byte mạng, checksum Keccak-256 - in ra loại địa chỉ,
                           mạng và các khóa, thoát 1 nếu pool mainnet không trả được
    --allow-bad-wallet     vẫn khởi động dù checksum sai. Với rx/0, checksum
                           sai là bị từ chối: máy sẽ đào mà không bao giờ được trả
    --idle-timeout=N       ngắt kết nối im lặng sau N giây [300, 0 = tắt]
    --keepalive-interval=N [60, 0 = tắt]
```

## Đào

```text
-t, --threads=N            số thread [cache L3 / 2 MiB]
    --mode=auto|fast|light
    --no-huge-pages
    --no-huge-pages-jit
    --no-jit
    --no-affinity
    --priority=N           1..5 (thang XMRig) hoặc giá trị nice thô, ví dụ -10
    --scratchpad-prefetch=N 0 nop, 1 prefetcht0 [mặc định], 2 prefetchnta, 3 load
    --no-optimized-init    bộ khởi tạo dataset di động
    --autotune[=SECONDS]   đo các phương án số thread, không cần pool
    --max-temp=C           giữ cảm biến CPU nóng nhất ở mức ≤ C độ
    --thermal-file=PATH    đọc nhiệt độ từ FILE thay vì sysfs
    --no-thermal           tắt bộ điều tiết
```

## Địa chỉ ví

`-u/--user` nhận địa chỉ mà pool sẽ trả. Với Monero, địa chỉ được giải mã trước
chia sẻ đầu tiên: 95 ký tự (106 nếu có payment id), base58, byte mạng, và
checksum Keccak-256 bốn byte. Sai **một** ký tự là kiểu hỏng mà phép đếm ký tự
không thấy — máy vẫn băm hoàn hảo và tiền trả về một địa chỉ không ai giữ khóa
spend — nên với `rx/0` đó là lý do từ chối khởi động:

```console
$ zmrig -o gulf.moneroocean.stream:10001 -u 4AdUndXH...684Rgf
error 4AdUndXH...684Rgf is not a valid Monero address: checksum does not match: at least one character is wrong
error this rig would mine and never be paid; check it with `zmrig --check-wallet 4AdUndXH...684Rgf`
error if that login is not a Monero address, pass --allow-bad-wallet
```

`--check-wallet ADDR` là đúng phép kiểm đó mà không cần pool, và `--check` in kết
luận cạnh phần còn lại của cấu hình:

```console
$ zmrig -o gulf.moneroocean.stream:10001 -u 4... --check
  wallet  standard mainnet checksum verified
```

Với mọi thuật toán khác, phép kiểm chỉ là cảnh báo: kho này chỉ nhận là biết định
dạng của Monero, và một login có dạng địa chỉ nhưng là địa chỉ của đồng CryptoNote
khác thì không được phép ngăn máy khởi động. `--allow-bad-wallet` biến lý do từ
chối trở lại thành cảnh báo như trước, cho trường hợp đó. Dòng tóm tắt nói rõ đang
ở trường hợp nào, để một lần chạy thử của rig Wownero không bị đọc thành "rig này
sẽ không khởi động":

```console
$ zmrig -o gulf.moneroocean.stream:10001 -u 4AdUndXH...684Rgf -a rx/wow --check
  wallet  INVALID: checksum does not match: at least one character is wrong
          not a Monero address: if this is another coin's address, mining is unaffected (--allow-bad-wallet silences the check)
```

## Log và vòng đời

```text
    --no-color
    --verbose
    --print-time=N         giây giữa các dòng hashrate [60, 0 = tắt]
    --log-file=FILE        ghi log ra đây nữa
    --background           fork xuống nền
-c, --config=FILE
    --check                kiểm tra cấu hình rồi thoát
    --self-test[=light]    kiểm tra engine hash
    --bench[=HASHES]       benchmark; dừng ở HASHES hoặc 180 s
    --report               đo trong --report-time rồi in mã ZMRIG1.
    --report-time=N        [15]
    --report-file=FILE     cập nhật FILE liên tục trong lúc đào
    --report-interval=N    [60]
    --report-id=NAME       tên máy trong báo cáo
    --power=W              công suất tại ổ cắm, đưa vào mã báo cáo
    --http-port=N          cổng API giám sát
    --http-host=ADDR       địa chỉ bind [127.0.0.1]
    --http-access-token=TOKEN
-h, --help
-V, --version
```

## Profile: `free` và `watt`

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile free  # hashrate tối đa
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile watt  # H/W tối đa
sudo ./oneclick.sh install --wallet 4YourMoneroAddress                 # = auto
```

`auto` đọc pin: laptop đang dùng pin thành `watt`, còn lại thành `free`. Miner
đọc lại profile lúc khởi động, nên rút sạc rồi restart service là đủ để đổi.

## Chế độ an toàn: đào mà không nướng máy

`--max-temp` là con số duy nhất của chế độ này. Nó bật một bộ điều tiết chạy mỗi
giây, đọc cảm biến CPU nóng nhất và trả lại thread khi máy nóng lên:

```bash
sudo zmrig -o gulf.moneroocean.stream:10001 -u 4YourMoneroAddress \
    --max-temp=72 --profile watt
```

| chuyện gì xảy ra | khi nào |
| --- | --- |
| không gì cả | dưới 72 °C |
| treo một thread | ở 72 °C, tối đa 30 giây một lần |
| treo thread ngay | ở 80 °C (đích + 8), tối đa 5 giây một lần |
| dừng đào | ở 87 °C (đích + 15) dù chỉ còn một thread |
| đào lại bằng một thread | khi cảm biến xuống dưới 65 °C |
| trả lại một thread | sau hai phút ở dưới 67 °C (đích − 5) |

Hai tốc độ khác nhau là cố ý. Ở mức đích, một cú nhảy nhiệt là bình thường — một
nhịp turbo, một đợt share — nên nó chờ. Ở mức trần cứng thì phần cứng đã tự bảo
vệ, nên nó phản ứng ngay. Chiều tăng thì cố ý chậm: nguội hai phút rồi nóng lại
trong mười giây là cách giết vòng bi quạt, và cũng làm hashrate trung bình tệ hơn
là giữ bớt một thread.

Không có gì bị dựng lại trong lúc này. Thread bị treo vẫn giữ VM và dataset nằm
nguyên trong RAM, nên một lần dừng chỉ mất đúng số share không tính được — kết nối
pool vẫn mở.

```text
thermal: holding 72 C max - k10temp/Tctl reads 61.5 C now; 8 thread(s), step down at 72 C, pause above 87 C
thermal: 73.4 C on k10temp/Tctl -> 7 of 8 threads (target 72 C; 1 step-down(s), 0 step-up(s) so far)
```

`zmrig --check` in ra bộ điều tiết có bật hay không và nó nhìn thấy gì — đó là
khác biệt giữa "nó đã hạ tải" và "nó không có cảm biến và không bao giờ hạ được":

```text
  thermal hold 72 C: k10temp/Tctl 61.5 C now, step down at 72 C, pause above 87 C (--no-thermal turns it off)
  thermal off (no --max-temp: nothing throttles, however hot the box gets)
```

Chỉ cảm biến của CPU được dùng — `coretemp`, `k10temp`, `zenpower`, `cpu_thermal`,
`acpitz` và các chip Super I/O — nên NVMe hay GPU ấm không làm mất một thread
nào. Máy không có cảm biến thì nói một lần rồi vẫn đào với số thread được giao:
một nhiệt kế hỏng không phải lý do để ngừng kiếm tiền. `--thermal-file=PATH`
trỏ bộ điều tiết sang một file khác, cho board mà cảm biến nằm sau BMC.

## Số thread: đo, không đoán

Mặc định là `cache L3 / 2 MiB`, chặn trên bằng số CPU logic. Trên VPS 2 vCPU với
54 MB L3 thì đó là hai thread, cũng là giá trị đo tốt nhất: 814 H/s với hai,
408 H/s với một.

```bash
zmrig --autotune=8        # không cần pool, 8 s mỗi phương án
```

```text
   threads     hashrate  verdict
         1   499.625 H/s  best so far
         2   999.750 H/s  best so far
best: 2 thread(s) at 999.750 H/s
autotune-best-threads=2
```

Chênh dưới 2 % tính là nhiễu, nên một lần chạy may mắn không làm đổi số thread.

## Kiểm tra trước khi chạy

```bash
sudo zmrig -c /etc/zmrig/config.json --check
```

```text
config ok
  pool    wss://my-relay.example.com:443/pool user=4Ad algo=auto (all RandomX variants)
  route   connect 10.0.0.7:443, Host: my-relay.example.com
  proxy   socks5 127.0.0.1:1080
  threads 2 (default would be 2)
  cpus    [0,1] on 2 cpu(s), 2 physical core(s)
  mode    auto, huge pages on, jit on
  memory  rx/0 maps 2336 MB, 1168 pages of 2 MiB (or 3 of 1 GiB): no pages reserved; transparent huge pages collapse the mapping instead
  1g      no pool: this mode would need 3 page(s) of 1 GiB, and the mapping uses 2 MiB pages instead (doc/PERFORMANCE.md has the one-line reservation)
  thp     madvise (default): the hint this miner sets is honoured, so no root step is needed
  msr     intel preset; reading /dev/cpu/0/msr needs root (auto: the preset is skipped here; --msr tries anyway)
```

Dòng `msr` là câu trả lời, không phải lời nhắc: preset tắt prefetcher đáng
**5–15 %** trên máy thật, và từ 6.48 nó được áp **tự động** khi máy chịu được
(`auto`). Phần trong ngoặc cho biết lần chạy này đang ở trạng thái nào —
`auto: …` (do bước dò quyết định), `on: --msr` (bạn yêu cầu), `off: --no-msr`
(bị từ chối, và config có `"msr": false` cũng vậy).

Dòng `1g` là pool không thể tạo lúc chạy: nó cho biết các trang 1 GiB mà bộ cấp
phát muốn dùng có tồn tại không, và `zmrig-os hugepages 1g 3` sẽ đặt chúng ở lần
boot sau. Không có là câu trả lời bình thường trên máy ảo và không mất gì — gần
như toàn bộ lợi ích nằm ở trang 2 MiB.

Dòng `memory` là cỡ của chính coin đó — `panthera maps 192 MB, 96 pages` — và
dòng `thp` trả lời câu hỏi mà nó đặt ra: `madvise` và `always` nghĩa là kernel
cấp trang 2 MiB cho mapping mà không cần bước nào bằng root, `never` nghĩa là
không, và miner sẽ chậm khoảng 18 % cho tới khi bạn đặt trang.

`--check` đọc file và in ra; nó không mở socket và không cấp phát dataset. Nếu
file chỉ root đọc được thì chạy bằng `sudo`, không thì bạn nhận
`cannot read …: check the path or run as root`.
