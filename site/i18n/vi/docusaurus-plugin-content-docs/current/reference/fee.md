---
title: Phí 1 %, nói hết
description: Phí developer tốn bao nhiêu, áp cho coin nào, in ở đâu, đổi thế nào, và lệnh chứng minh đó là khoản phí duy nhất.
image: https://nggkhaiz.github.io/ZMRIG/img/og-vi.png
---

# Phí 1 %, nói hết

`zmrig` đào **1 % thời gian đào Monero** cho developer. 99 % còn lại vào pool và
ví bạn cấu hình. Chính sách chỉ có vậy:

| | |
| --- | --- |
| Mức | 1 % thời gian đào Monero (`rx/0`), `--donate-level=0` đến 10 |
| Nhịp | 60 giây đào Monero cho ví developer sau mỗi 100 phút của bạn |
| Coin | chỉ Monero. Ví là địa chỉ Monero, nên thời gian ArQmA, Wownero, Graft, Safex, Yada hay Scala không tích phí |
| Đích | đúng pool bạn đang dùng, chỉ đổi ví trong lệnh login. Không pool thứ hai, không relay, không endpoint ẩn |
| Tắt | `--donate-level=0` hoặc `--no-donate` tắt hoàn toàn |

Phí không lấy từ share bạn đã giải: pool trả cho người login, nên cách duy nhất
để miner trả phí mà không chen vào đường truyền của bạn là login bằng ví kia một
lúc. Đồng hồ tính theo nợ, nên mất kết nối không làm mất phí và cũng không tính
hai lần:

- mỗi giây đào Monero cộng 10 ms nợ ở mức 1 % (100 ms ở mức 10 %),
- khi nợ đủ 60 giây, miner đóng kết nối hiện tại và login lại **cùng pool** bằng
  ví developer,
- để không thành vòng lặp reconnect, nhịp tối đa là một phiên phí mỗi ~100 phút
  ở mức mặc định; pool từ chối ví developer thì phí hoãn 2 phút, và sau ba lần
  từ chối thì hoãn 30 phút, thay vì cắt ngang việc đào của bạn.

## In ở đâu

Đây không phải thiết lập âm thầm. Tất cả những chỗ sau đều nói mức phí và địa chỉ:

```text
ZMRIG 6.33.0 - RandomX miner by @nggkhaiz
1% of Monero mining time goes to the developer (--donate-level=0 turns it off), GPL-3.0, https://github.com/NggKhaiz/ZMRIG
```

```bash
zmrig ... --check | grep donate
#   donate  1% of Monero (rx/0) mining time to 46SQLW7D…n6ysb5tJ, 60 s every 100 min (--donate-level=0 turns it off)
```

Lúc chạy, mỗi phiên một lần:

```text
developer fee: 60 s owed, reconnecting to pay it
developer fee: login ok, mining job 7f3a… for the developer wallet
developer fee: session paid, back to your wallet
```

Và API HTTP báo `"donate_level": 1` trong `/1/summary` và `/2/summary`, nên
dashboard không thể hiện 0 trong khi miner đang trả phí.

## Phí này không phải là gì

- **Không lấy từ share của bạn.** Không share nào bị gửi hai lần, không share nào
  bị đổi trọng số, pool không thấy share cho ví khác ngoài cửa sổ phí.
- **Không trả bằng coin khác.** Đào ArQmA vào địa chỉ Monero là đốt coin vào chỗ
  không ai tiêu được, nên thời gian đó không tích phí.
- **Không dùng pool cứng.** Phiên phí dùng đúng pool, port, TLS và proxy bạn đã
  cấu hình. Pool đó không nhận ví developer thì phí hoãn, việc đào của bạn
  không bị ảnh hưởng.

## Tự kiểm tra

```bash
./scripts/verify-fee.sh --binary zmrig/out/zmrig
```

Script đọc hằng số phí, xác nhận `--check` in ra mức phí và địa chỉ, xác nhận
`--donate-level=0` in `off`, và fail nếu binary có host donate hay ví thứ hai.
Mỗi bước in ra dòng nó đọc, nên "pass" không phải đầu ra duy nhất.

```bash
zmrig ... --check | grep donate             # mức phí và địa chỉ
zmrig ... --donate-level=0                  # không đào cho ai ngoài bạn
strings zmrig/out/zmrig | grep -c 46SQLW7D  # đúng một địa chỉ
```

## Engine C++ trong repo này

`src/` là cây XMRig gốc đã xoá mọi dòng donate, và vẫn không có phí
(`doc/ZERO_FEE.md`, `./scripts/verify-fee-free.sh`). Nó được giữ cho những thuật
toán engine Zig chưa nói, chọn bằng `--engine=xmrig`; engine mặc định `zmrig` là
engine trả phí. Muốn ủng hộ công việc thì ở lại engine mặc định là đủ.

## Vì sao 1 %

Đúng mức XMRig thu, cùng lý do: đủ nhỏ để không nhìn thấy trong bài tính lợi
nhuận (1 kH/s, 1 % của một tháng ít hơn tiền điện một ngày) và đủ lớn để nuôi
pool, website và các bài đo đã tạo ra những con số trên các trang này. Đó là
thời gian, không phải tiền: không hoá đơn, không tài khoản, không theo dõi.
