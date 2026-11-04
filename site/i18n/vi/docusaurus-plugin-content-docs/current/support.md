---
title: Hỗ trợ và donate
description: Nơi gửi Monero, cách kiểm tra địa chỉ trước khi gửi, một khoản donate không mua được gì, và những gì giúp dự án nhiều hơn.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Hỗ trợ và donate

Miner Zig đã lấy 3 % thời gian đào Monero làm phí
([chi tiết](/docs/reference/fee)); engine C++ thì không lấy gì. Trang này tồn
tại cho những người vẫn muốn gửi thêm. Không phần mềm nào đọc địa chỉ bên dưới.

## Địa chỉ

```text
46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ
```

<img src="/img/donate-monero.png" width="190" alt="Mã QR cho địa chỉ donate Monero 46SQLW7D…n6ysb5tJ" />

- **Chỉ Monero (XMR).** Thứ khác — BTC, ETH, USDT, token wrapped — là mất, và
  không ai lấy lại được.
- **Địa chỉ mainnet chuẩn**, 95 ký tự, network byte `18`. Không phải integrated
  address, không phải subaddress.
- **Cùng ví với phí pool.** `pool/src/operator.js` giải mã ra đúng địa chỉ này, và
  mọi instance pool công bố nó ở `/api/config` và trên trang trạng thái. Một ví,
  một dấu vết kiểm toán.

## Kiểm tra trước khi gửi

Đừng tin một chuỗi chỉ vì nó nằm trên GitHub. Địa chỉ bắt đầu bằng `46SQLW7D` và
kết thúc bằng `n6ysb5tJ`; địa chỉ Monero là base58 kèm checksum Keccak-256 4
byte, nên một lỗi gõ không thể sống sót qua bước giải mã.

```python
from Crypto.Hash import keccak              # pip install pycryptodome

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
ADDRESS = "46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"

def decode_block(text, size):
    value = 0
    for char in text:
        value = value * 58 + ALPHABET.index(char)
    return value.to_bytes(size, "big")

raw = b""
for offset in range(0, len(ADDRESS), 11):
    group = ADDRESS[offset:offset + 11]
    raw += decode_block(group, 8) if len(group) == 11 else decode_block(group, 5)

body, checksum = raw[:-4], raw[-4:]
digest = keccak.new(digest_bits=256, data=body).digest()[:4]
print(len(raw), body[0], "OK" if digest == checksum else "BAD")
# 69 18 OK
```

Checksum sai nghĩa là gõ nhầm, chép thiếu, hoặc đó chưa từng là địa chỉ Monero.

## Một khoản donate không mua gì

- **Không ảnh hưởng gì tới miner.** Không gì đọc trang này lúc build hay lúc
  chạy, và `sudo ./oneclick.sh verify` báo đúng mức phí binary đang lấy, công bố
  địa chỉ hay không.
- **Không có bản supporter.** Chỉ có một binary và nó đào hết tốc lực cho tất cả
  mọi người. Ai bán "bản nhanh hơn" thì không phải dự án này.
- **Không ưu tiên hỗ trợ, không vote roadmap, không huy hiệu.** Issue được trả lời
  theo thứ tự đến và theo mức dễ tái hiện.
- **Không có subscription.** Không có gì định kỳ để huỷ.

## Những gì giúp hơn một khoản chuyển tiền

1. **Đào về pool.** Phí 3 % là thứ nuôi công việc, và nó chỉ tồn tại khi có người
   đào.
2. **Gửi một phép đo.** `zmrig/tests/ab.sh` so hai cài đặt trên cùng một máy; một
   bảng trước/sau kết thúc tranh luận mà ý kiến không làm được.
3. **Báo lỗi** kèm lệnh, toàn bộ output và phần cứng. Light mode trên VPS 2 GiB và
   đọc MSR trên máy thật là hai chỗ một báo cáo đáng giá nhất.
4. **Gửi patch.** Kế toán share của pool, phần giao diện Zig và lỗi chính tả
   trong `doc/` đều được.

## Nếu bạn thấy một địa chỉ khác

Dự án này đã công bố đúng một địa chỉ, chuỗi ở trên. Địa chỉ trong fork, issue,
pull request, video, chat hay trang "mirror chính thức" không phải của chúng tôi.
Hãy so với `doc/DONATE.md` trong lịch sử repo (`git log -p doc/DONATE.md`), không
so với ảnh chụp màn hình.

## Riêng tư

Donate là công khai trên chuỗi Monero theo thiết kế. Không có gì khác được thu
thập: miner không gửi telemetry, trang không có analytics, và pool không giữ tài
khoản nào cho người donate. Muốn không bị liên kết, hãy gửi không kèm payment ID
và từ một địa chỉ bạn chưa dùng ở nơi khác.
