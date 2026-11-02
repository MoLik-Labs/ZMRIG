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
  memory  rx/0 maps 2336 MB, 1168 pages of 2 MiB: no pages reserved; transparent huge pages collapse the mapping instead
  thp     madvise (default): the hint this miner sets is honoured, so no root step is needed
  msr     intel preset; reading /dev/cpu/0/msr needs root (off: --msr is worth 5-15% on Zen 3/4 …)
```

Dòng `memory` là cỡ của chính coin đó — `panthera maps 192 MB, 96 pages` — và
dòng `thp` trả lời câu hỏi mà nó đặt ra: `madvise` và `always` nghĩa là kernel
cấp trang 2 MiB cho mapping mà không cần bước nào bằng root, `never` nghĩa là
không, và miner sẽ chậm khoảng 28 % cho tới khi bạn đặt trang.

`--check` đọc file và in ra; nó không mở socket và không cấp phát dataset. Nếu
file chỉ root đọc được thì chạy bằng `sudo`, không thì bạn nhận
`cannot read …: check the path or run as root`.
