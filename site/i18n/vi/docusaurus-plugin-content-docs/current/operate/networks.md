---
title: Mạng chỉ mở 443
description: Relay Cloudflare, proxy SOCKS5 và HTTP, --connect-to và ghim CA, cho VPS và mạng công ty chặn mọi thứ trừ HTTPS.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Mạng chỉ mở 443

Một VPS "kén chọn" thường rơi vào một trong bốn tình huống:

1. Chỉ mở 443/tcp ra ngoài; 3333, 10001, 5555 đều bị chặn.
2. Bắt buộc TLS, stratum dạng thường bị drop, hoặc DPI cắt gói lạ.
3. Mọi thứ phải đi qua proxy của tổ chức.
4. Chỉ một số dải địa chỉ là tới được (anycast của CDN, relay nội bộ).

Engine Zig xử lý cả bốn. Engine C++ không có client WebSocket nên không xử lý
được (1) và phần lớn (2) — installer đổi engine thay vì ghi ra một config không
thể kết nối.

## Một cờ cho trường hợp phổ biến

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress \
  --pool my-relay.example.com \
  --cloudflare=my-relay.example.com --ws-path /pool
```

`--cloudflare` nghĩa là: `wss://<host>:443<path>`, bật TLS, engine `zmrig`. Ép
`--engine xmrig` cùng lúc sẽ bị từ chối, không phải bị bỏ qua lặng lẽ.

Làm tay thì tương đương:

```bash
zmrig -o wss://my-relay.example.com:443/pool -u 4YourMoneroAddress -p x
```

## Có cần relay không?

Nếu pool có endpoint WebSocket trên 443 thì không. Nếu không, phải có thứ gì đó
bắc cầu WebSocket sang stratum thô. Hai lựa chọn chạy được:

| Relay | Hợp khi | Chi phí |
| --- | --- | --- |
| `pool/worker/` trong repo này | pool nói TCP thường và bạn muốn một endpoint `wss://` | gói Workers free đủ cho một farm |
| Worker của bạn | bạn muốn đọc từng dòng mã | gói Workers free |

Worker trong `pool/worker/` là một ống byte: nó mở socket TCP tới pool và chuyển
frame hai chiều. Nó không thấy ví của bạn, và pool thấy địa chỉ của Worker chứ
không phải VPS của bạn. Nó có thấy luồng stratum, nên nếu điều đó khiến bạn bận
tâm thì tự dựng là lựa chọn đúng.

```bash
# 1. cd pool/worker && sửa wrangler.toml, rồi: npx wrangler deploy
# 2. trỏ miner vào đó
sudo ./oneclick.sh install --wallet 4YourMoneroAddress \
  --pool your-worker.workers.dev --cloudflare \
  --ws-path /relay/YOUR_TOKEN --yes
```

## Proxy

```bash
# SOCKS5, không auth
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress --proxy socks5://127.0.0.1:1080

# HTTP CONNECT có thông tin đăng nhập
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress \
  --proxy http://user:pass@proxy.corp.example:3128
```

Engine Zig phân giải tên pool qua proxy (DNS từ xa), nên resolver nội bộ bị đầu
độc không thành vấn đề.

## Khi vấn đề là DNS, không phải firewall

Quad9 trả NXDOMAIN cho `gulf.moneroocean.stream`; resolver lọc mã độc của
Cloudflare làm điều tương tự với `pool.supportxmr.com`. Trong log miner, một tên
bị chặn trông y hệt một cổng bị chặn.

```bash
# giữ hostname cho SNI và Host, dial địa chỉ đã biết là tốt
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress \
  --connect-to 203.0.113.10:3333

# hoặc ghim CA của relay do bạn dựng
zmrig -o wss://relay.example.com/pool -u 4YourMoneroAddress \
  --tls-ca /etc/zmrig/tls-ca.pem
```

Installer chép CA bạn đưa vào `/etc/zmrig/tls-ca.pem`: unit chạy với
`PrivateTmp=true`, nên file trong `/tmp` có thể biến mất sau khi restart.

## Những gì miner sẽ không làm

- Thử lại ví sai mỗi năm giây. Ví bị từ chối được nhận diện, pool đó bị để yên
  30 phút, và log nói rõ cần sửa gì.
- Kết nối lại ngay sau `your IP is banned`. Mười lăm phút mỗi pool
  (`--ban-cooldown`), rồi sang pool kế tiếp trong danh sách dự phòng.
- Gửi tiếp sau khi ba share bị gọi là invalid — nghỉ mười phút thay vì ăn ban cả
  tiếng như `xmrpool.eu` áp.
- Để hai mươi rig reboot cùng lúc kết nối lại trong cùng một mili giây. Mỗi lần
  thử lệch ±20 %.

Đây là những hành vi phân biệt một buổi tối xui với một lần bị chặn vĩnh viễn.
Chọn pool kỹ hơn ở [Pool](/docs/pools/choosing).
