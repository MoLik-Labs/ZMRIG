---
title: Proxy cho farm
description: Một kết nối pool cho nhiều rig. Extranonce riêng từng rig, độ khó riêng, một login cho cả farm, và tunnel cho rig ở toà nhà khác.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Proxy cho farm

Mười rig ở hai toà nhà, một ví, một kết nối tới pool. `proxy/` làm được điều đó:
Node 18+, không dependency, không cần biên dịch.

```bash
sudo ./proxy/install.sh --user=4YourMoneroAddress --pool=gulf.moneroocean.stream:10001
```

Hoặc không cài gì cả:

```bash
node proxy/src/main.js start --user=4YourMoneroAddress --pool=gulf.moneroocean.stream:10001
```

`install.sh --dry-run` in unit systemd trước khi ghi, và banner in đúng dòng lệnh
từng rig phải gõ.

## Vì sao có proxy thì kiếm nhiều hơn

Ba kiểu mất tiền, cùng một gốc:

1. **Trùng việc.** Nonce Monero chỉ 32 bit. Hai rig tìm cùng dải thì share tìm
   được cũng chỉ trả một lần. Proxy chia byte nonce trên cho từng rig và giữ 24
   bit dưới cho rig — giống `xmrig-proxy`. Cái bẫy: **prefix 0 không phải là
   prefix.** Blob có nonce 0 là tín hiệu tắt chế độ extranonce của miner, nên đưa
   0 cho rig là nó quay lại dùng chung dải, im lặng, và kiếm ít hơn.
2. **Một độ khó không vừa mọi rig.** Máy 500 H/s và máy 20 kH/s trên cùng target
   cho ra một share mỗi giờ và một share mỗi phút. Rig nhỏ chết đói share trong
   khi vẫn ăn đủ điện. Proxy cấp độ khó riêng cho từng rig, mục tiêu khoảng 15
   giây một share.
3. **Bão login.** Pool thấy mỗi rig một login, và pool sau Cloudflare — hoặc sau
   bất kỳ dịch vụ free tier — giới hạn login rồi ban IP. Một kết nối từ proxy
   thay cho cả farm, mà mỗi rig vẫn hiện trên pool như một worker riêng
   (`--user=wallet.rig3`).

Proxy **không** băm. Nó kiểm tra target của từng share (so sánh BigInt, vài
micro-giây) rồi chuyển tiếp; pool mới là nơi băm lại. Proxy không thể làm giả
công việc, và bản này không thử.

## Kiểm tra trước khi trỏ rig

```bash
node proxy/src/main.js doctor --user=4YourMoneroAddress --pool=gulf.moneroocean.stream:10001
```

```text
ok   pool gulf.moneroocean.stream:10001 answered -- 168 ms
ok   job difficulty -- 60011.2
ok   a 5 kH/s rig would find -- 0.30 shares/hour at this difficulty
```

Dòng cuối là phép tính hay bị bỏ qua: share/giờ = `hashrate × 3600 /
difficulty`. 0.30 nghĩa là ba tiếng mới có một share — ổn với PPLNS cửa sổ dài,
chết với pool có ngưỡng trả cao.

## Tới rig ở toà nhà khác

| Cờ | Đường truyền | Địa chỉ cố định | Bên thứ ba | Kết luận |
| --- | --- | --- | --- | --- |
| `--tunnel=wireguard` | WireGuard qua UDP, trong kernel | `10.66.66.1` | không | **nên dùng** |
| `--tunnel=tailscale` | WireGuard qua coordination server | `*.ts.net` | Tailscale | tốt khi không mở được port |
| `--tunnel=cf` | Cloudflare tunnel có tên, WebSocket | hostname của bạn | Cloudflare | chạy được, thêm một chặng edge |
| `--tunnel=cf-quick` | `*.trycloudflare.com`, WebSocket | ngẫu nhiên, đổi mỗi lần chạy | Cloudflare | **chỉ để demo** |

```bash
# một lần, trên máy chạy proxy
node proxy/src/main.js tunnel wireguard --rigs=10 --dir=wg
sudo cp wg/ocean-proxy.conf /etc/wireguard/ocean-proxy.conf
sudo systemctl enable --now wg-quick@ocean-proxy

node proxy/src/main.js start --user=4YourMoneroAddress \
  --pool=gulf.moneroocean.stream:10001 --tunnel=wireguard
```

Nó ghi config server cùng một file cho mỗi rig (`wg/rig-1.conf` …), mỗi file một
key và một địa chỉ từ `10.66.66.2` trở lên, kèm `INSTALL.txt` chứa lệnh chép.
**Một file cho một máy** — dùng chung file là phiên bản WireGuard của lỗi trùng
nonce.

Vì sao nên chọn: địa chỉ cố định (đổi IP nhà mạng không phải sửa gì trên rig),
UDP trong kernel nên không thêm độ trễ, không phụ thuộc bên thứ ba, và chỉ cần mở
**một cổng UDP 51820** trên router — cổng stratum vẫn nằm ở localhost.

## Tailscale, khi không mở được cổng nào

```bash
node proxy/src/main.js start --user=4YourMoneroAddress \
  --pool=gulf.moneroocean.stream:10001 \
  --tunnel=tailscale --tunnel-token=tskey-auth-…
```

Ba điều cần biết trước khi chọn: Funnel chỉ phục vụ **443/8443/10000**, chỉ TLS,
và băng thông không đủ để poll dashboard mỗi giây (đủ cho stratum, vài kB/s). Gói
free Personal là **phi thương mại**. Nếu rig nằm trong cùng tailnet thì bỏ Funnel,
trỏ thẳng `<host>.<tailnet>.ts.net:3333`; không lộ gì ra internet.

## Cloudflare tunnel, nói thẳng

**Quick tunnel không phải đường chạy thật.** Nó tốt cho đúng một việc: chứng minh
trong hai phút rằng đường mạng thông.

| Đặc điểm | Hệ quả khi đào |
| --- | --- |
| Hostname ngẫu nhiên mỗi lần chạy | mọi rig phải sửa sau mỗi lần restart |
| Không cam kết uptime | tunnel rớt là cả farm dừng cùng lúc |
| Không kiểm soát truy cập | ai biết tên cũng đào về ví bạn được |
| Thêm một chặng | thêm độ trễ cho mỗi thông báo job |

Tunnel có tên kèm token sửa được hostname và kiểm soát truy cập, và đó là lựa
chọn đúng khi chỉ mở 443. Kể cả vậy, proxy vẫn là thứ duy nhất lộ ra, và rig
không bao giờ thấy internet.

## Trạng thái và thu nhập từng rig

```bash
curl -s http://127.0.0.1:3334/status | python3 -m json.tool
```

`/status` báo, cho từng rig, hashrate suy ra từ share được nhận và độ khó cục bộ
nó được cấp, cộng XMR/ngày khi biết độ khó mạng:

```bash
node proxy/src/main.js start --user=4YourMoneroAddress \
  --pool=gulf.moneroocean.stream:10001 \
  --network-difficulty=350000000000 --block-reward=0.6
```

Con số đó là đo, không suy từ tên CPU, và nó là `null` thay vì một con số đoán
khi chưa biết độ khó mạng.
