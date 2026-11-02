# Cài đặt

## Yêu cầu

- Linux x86-64 (Debian/Ubuntu, RHEL/Fedora, Arch đều được; script tự nhận distro).
- 2 GB RAM trống cho chế độ `fast` (dataset RandomX), hoặc dùng `--mode light` với ~300 MB.
- `systemd` nếu muốn cài như dịch vụ.
- Quyền root.

Script cần mạng để tải source (hoặc bạn clone sẵn repo). Không tải binary từ nơi khác: mọi thứ được biên dịch tại máy.

Không muốn nhớ cờ nào? [Wizard bốn bước](wizard.html) hỏi đúng ba thứ installer không tự quyết được — ví, pool, mạng — rồi in một lệnh.

## Cài một lệnh — chỉ cần địa chỉ ví

```bash
curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet YOUR_WALLET
```

Nếu đã có repo:

```bash
sudo ./oneclick.sh --wallet YOUR_WALLET
```

Không cần cờ nào khác. Mọi quyết định còn lại được đọc từ chính cái máy đang chạy:

| Quyết định | Cách script tự chọn |
| --- | --- |
| Engine | `zmrig` (0% phí), và nó tự thương lượng: pool đổi coin theo lợi nhuận (MoneroOcean…) nhận được login khai đủ họ RandomX nên vẫn chuyển rig sang coin đắt nhất được. `--algo` phi RandomX (cn/2…) hoặc `--engine=xmrig` mới dùng engine C++ (34 thuật toán). |
| Chế độ | `free` (hashrate tối đa) cho mọi máy, trừ laptop đang dùng pin → `watt` (tối đa H/W). |
| Số thread | Đo thật sau khi build: mỗi ứng viên chạy 8 s trên dataset thật, kết quả tốt nhất ghi vào `config.json`. |
| Huge pages | Tự đặt theo kích thước dataset; nếu kernel không cấp đủ thì lùi về THP và nói rõ. |
| Governor | `performance` cho `free`, giữ governor tiết kiệm điện cho `watt`. |

Muốn xem trước mà không thay đổi gì trên máy:

```bash
./oneclick.sh plan
```

Script làm theo thứ tự: cài phụ thuộc (build-essential, cmake, libuv, …) → build engine hash + miner → đo và chọn số thread → tune hệ thống (huge pages, THP, governor, MSR) → viết `/etc/zmrig/config.json` → tạo systemd unit `zmrig` → self-check → in hashrate.

Toàn bộ idempotent: chạy lại không tạo service trùng, không ghi đè config trừ khi có `--force`, bỏ qua bước build nếu binary mới hơn source.

## Hai chế độ: điện free và tiết kiệm điện

```bash
# điện free: quán coffee, trường, máy văn phòng — hashrate tối đa
sudo ./oneclick.sh install --wallet YOUR_WALLET --profile free

# mỗi watt đều tính tiền: laptop, VPS trả theo điện — tối đa H/W
sudo ./oneclick.sh install --wallet YOUR_WALLET --profile watt
```

`free` dùng hết logical CPU, `--mode fast`, huge pages, `--priority 5`.

`watt` bớt xuống một thread cho mỗi core vật lý (SMT chỉ thêm 5–15% hashrate nhưng
tốn thêm 30–40% điện), không ép CPU lên xung cao nhất, và **tự dừng khi laptop
chuyển sang pin**. Cả hai chế độ đều 0% phí và đều kiểm chứng được bằng
`sudo ./oneclick.sh verify`.

## Gỡ cài đặt

Hai mức, vì hai câu hỏi khác nhau:

```bash
sudo ./oneclick.sh uninstall          # dừng, xoá service và binary, giữ config
sudo ./oneclick.sh uninstall --force  # ... và xoá luôn config (có ví)

sudo ./oneclick.sh purge --dry-run    # liệt kê từng đường dẫn tool đã tạo, kèm dung lượng
sudo ./oneclick.sh purge              # xoá hết: config, state, build cache, log
```

`purge` in danh sách trước, bắt gõ đúng chữ `purge` mới xoá, trả `vm.nr_hugepages`
về 0, và không đụng vào file nào nó không tạo ra. `--yes` để chạy không cần hỏi
(dùng cho script), `--dry-run` để xem mà không xoá.

## Chọn branch

Ba branch, một chiều đi:

```
ALPHA  ──►  BETA  ──►  master
mới nhất    mặc định    nền upstream
```

| Branch | Dùng khi nào |
|---|---|
| **`BETA`** | mặc định — mọi lệnh trong trang này đều lấy từ đây, ổn định |
| `ALPHA` | muốn thử bản mới nhất, có thể lỗi |
| `master` | chỉ để tra history và cắt tag release |

Đổi branch bằng biến môi trường, không cần cài lại:

```bash
# thử bản ALPHA
MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install --wallet 4YourMoneroAddress...

# quay lại bản ổn định
sudo ./oneclick.sh update
```

`oneclick.sh update` tự fetch đúng branch rồi mới checkout; nếu branch không tồn tại nó **dừng và báo tên branch**, trước đây lỗi này bị nuốt và update im lặng không làm gì.

## Cờ thường dùng

| Cờ | Ý nghĩa |
|---|---|
| `--wallet ADDR` | địa chỉ ví hoặc login pool |
| `--pool HOST:PORT` | endpoint pool, mặc định `gulf.moneroocean.stream:10001`. Tên ngắn cũng được: `moneroocean`, `supportxmr`, `c3pool`, `xmrpool`, `herominers`, `p2pool`, `p2pool-nano`. |
| `--failover DANH_SÁCH` | pool dự phòng, cách nhau bằng dấu phẩy; ghi vào `config.json`, chỉ dùng khi pool đầu không tới được hoặc từ chối IP này. Xem [Chọn pool](docs.html#chon-pool). |
| `--pass VALUE` | password pool (mặc định `x`) |
| `--rig-id NAME` | tên máy hiện trên dashboard pool và trong mã báo cáo |
| `--algo NAME` | ghim một thuật toán; `--algo=auto` khai cả họ RandomX để pool chuyển sang coin đắt nhất (mặc định: pool tự chọn) |
| `--engine xmrig\|zmrig` | engine C++ hay engine Zig |
| `--tls` | dùng TLS cho kết nối pool |
| `--cloudflare[=HOST[:PORT]]` | pool qua `wss://` trên 443, tự chuyển sang engine `zmrig` |
| `--transport tcp\|tls\|ws\|wss` | ghi đè scheme của pool |
| `--ws-path PATH` | path WebSocket (mặc định `/`) |
| `--ws-origin URL` | header `Origin` cho upgrade |
| `--proxy URL` | `http://user:pass@host:port` hoặc `socks5://host:port` |
| `--connect-to HOST:PORT` | nối tới địa chỉ khác nhưng giữ SNI/`Host` của pool |
| `--tls-ca FILE` | tin CA riêng / pin chứng chỉ relay |
| `--idle-timeout N` | ngắt kết nối nếu pool im lặng N giây (0 = tắt) |
| `--power W` | công suất thực của máy, ghi vào mã báo cáo |
| `--report-file PATH` | nơi zmrig ghi mã báo cáo (mặc định `/var/lib/zmrig/report.txt`) |
| `--no-report` | không ghi file báo cáo |
| `--http-port PORT` | cổng API giám sát (mặc định 18080) |
| `--http-token TOKEN` | yêu cầu `Authorization: Bearer TOKEN` |
| `--no-http` | tắt API giám sát |
| `--cpu-hint N` | `max-threads-hint` phần trăm (mặc định 100) |
| `--no-tune` | bỏ qua bước chỉnh hệ thống |
| `--no-service` | cài và cấu hình nhưng không tạo service |
| `--force` | ghi đè config đang có |
| `--yes` | không hỏi gì |

Ví dụ cho VPS chỉ mở 443:

```bash
sudo ./oneclick.sh install \
  --wallet YOUR_WALLET \
  --pool my-relay.example.com \
  --cloudflare=my-relay.example.com --ws-path /pool \
  --power 45 --rig-id vps-sg-02
```

## Lấy mã báo cáo

```bash
sudo ./oneclick.sh report --power 95
# tạm dừng service, đo 15 giây, in ZMRIG1.…, rồi bật lại
```

Lệnh này cần engine `zmrig`. Nếu service đang chạy, nó tự dừng trước khi đo — dataset 2 GiB không thể dựng
hai lần cùng lúc. Mã in ra dán thẳng vào bảng tính trên trang chủ.

## Kiểm tra sau khi cài

```bash
./oneclick.sh status     # service, hashrate 10s/60s/15m, số share, huge pages
./oneclick.sh logs 50    # 50 dòng log cuối
curl -s 127.0.0.1:18080/1/summary | head -c 400
```

`status` chỉ đọc số thật: nếu miner vừa khởi động, nó in `warming up` thay vì hashrate của lần chạy trước, vì dataset cần 15–25 giây để dựng xong.

Trạng thái dịch vụ:

```bash
systemctl status zmrig
journalctl -u zmrig -f
```

Unit dùng `Restart=always`, `RestartSec=5`, `Nice=-10`, `LimitMEMLOCK=infinity`, `PrivateTmp=true`. Config chỉ root đọc được (`/etc/zmrig/config.json`, mode 600) vì có thể chứa token API.

## Cập nhật và gỡ

```bash
sudo ./oneclick.sh update      # git pull + build lại + restart
sudo ./oneclick.sh uninstall   # dừng, xoá service và binary (giữ config nếu bạn chọn giữ)
```

## Build tay (không dùng installer)

```bash
# engine hash + miner Zig
ZIG=/path/to/zig ./zmrig/build.sh --jobs 2

# kiểm tra
./zmrig/out/zmrig --self-test
./zmrig/out/zmrig --version

# chạy thử 60 giây
./zmrig/out/zmrig -o pool.example.com:3333 -u YOUR_WALLET -p x -t 2
```

Cần Zig 0.13.0 (bản 0.14 đổi API std, chưa build được) và `g++`, `ar`. Build ~35 giây trên 2 vCPU.

Engine C++ vẫn build bằng CMake như repo gốc:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j2
```

Tiếp: [Cấu hình](#cau-hinh).
