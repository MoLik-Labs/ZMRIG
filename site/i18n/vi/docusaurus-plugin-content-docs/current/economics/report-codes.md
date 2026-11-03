---
title: Mã báo cáo
description: Định dạng ZMRIG1. — máy đo những gì, cách tự giải mã, và vì sao trong đó không có ví hay token.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Mã báo cáo

Mã báo cáo là cách một máy tự mô tả mình mà không cần server: một dòng văn bản,
in được ra console, dán được vào chat, đọc được trong trình duyệt.

```bash
sudo ./oneclick.sh report --power 45
ZMRIG1.eyJ2IjoxLCJpZCI6InZwc…
```

```bash
# trong lúc đào: để file luôn mới
zmrig --report-file /var/lib/zmrig/report.txt --report-interval 60
sudo cat /var/lib/zmrig/report.txt
```

## Định dạng

`ZMRIG1.` theo sau là base64url của một object JSON gọn. Phiên bản 1 của định
dạng:

```json
{
  "v": 1,
  "id": "vps-sg-02",
  "ver": "6.32.1",
  "cpu": "AMD EPYC 7B13 64-Core Processor",
  "arch": "x86_64",
  "cores": 32,
  "thr": 2,
  "algo": "rx/0",
  "mode": "fast",
  "hs": [1461.2, 1470.5, 1466.1, 1478.9],
  "hp": [1168, 1168],
  "shares": [806, 0, 0],
  "hash": 881234012,
  "up": 86400,
  "pw": 22,
  "pwsrc": "rapl",
  "hw": 66.8,
  "tmax": 72,
  "tc": 68.5,
  "at": 7,
  "health": "ok",
  "pool": "gulf.moneroocean.stream:10001",
  "ts": 1793412000
}
```

| Trường | Ý nghĩa |
| --- | --- |
| `hs` | hashrate 10 s, 60 s, 15 phút, tốt nhất phiên (H/s) |
| `hp` | huge pages được cấp, cần |
| `shares` | nhận, từ chối, lỗi |
| `hash` | tổng hash đã tính |
| `up` | uptime tính bằng giây |
| `pw`, `pwsrc` | watt, và nguồn: `rapl`, `hwmon`, `user`, `none` |
| `hw` | hash trên watt, khi biết công suất, ngược lại `null` |
| `tmax` | mức `--max-temp`, hoặc `null` khi không bật chế độ an toàn |
| `tc` | nhiệt độ lần cuối bộ điều tiết phản ứng, hoặc `null` |
| `at` | số thread đang được phép chạy — thấp hơn `thr` khi đang bị hạ tải |
| `health` | miner tự đánh giá thu nhập: `ok`, `warming`, `degraded`, `stalled`, `rejected` |

`at` thấp hơn `thr` là trường duy nhất mà bảng điều khiển không thể suy ra từ
hashrate: một rig đang bị hạ tải và một rig khoẻ chạy nửa công suất trông giống
hệt nhau từ phía pool, và chỉ một trong hai đang có vòng bi sắp hỏng.

Không có gì khác trong đó. **Không địa chỉ ví, không mật khẩu pool, không IP công
khai, không hostname** ngoài tên worker do chính bạn đặt.

## Tự giải mã

```bash
cut -d. -f2 report.txt | tr '_-' '/+' | base64 -d | python3 -m json.tool
```

Hoặc trong console trình duyệt:

```js
JSON.parse(atob("eyJ2Ijox…".replace(/-/g, "+").replace(/_/g, "/")))
```

Bạn không nên phải tin một bộ giải mã trên website để đọc con số do máy mình tạo
ra. Máy tính trên trang này giải mã tại chỗ và không gửi gì đi, nhưng hai dòng
trên là toàn bộ mẹo.

## Chọn cửa sổ hashrate

`--report` đo 10 s warm-up cộng một cửa sổ `--report-time` giây (mặc định 15),
rồi báo hashrate **ổn định** chứ không phải trung bình từ lúc khởi động: trung
bình sẽ gồm cả thời gian dựng dataset và ra thấp hơn 20–25 %.

Trong máy tính bạn chọn cửa sổ:

| Cửa sổ | Dùng để |
| --- | --- |
| 10 s | trạng thái hiện tại của máy |
| 60 s | mặc định; làm phẳng các cú tụt ngắn |
| 15 phút | máy bị throttle hoặc chia sẻ với việc khác |
| tốt nhất phiên | máy làm được gì khi không chạy gì khác |

So sánh các máy ở cửa sổ khác nhau là cách nhanh nhất để đi tới kết luận sai về
một CPU.

## Cả một fleet

1. Cho mỗi máy một `--report-id` riêng.
2. Để miner tiếp tục ghi file báo cáo.
3. Thu các dòng lại và dán vào [máy tính](/docs/economics/profitability), mỗi
   dòng một mã — hoặc dán JSON thô nếu bạn giữ danh sách máy riêng.

Mã sống sót qua copy-paste: bảng chữ là base64url, nên không có xuống dòng, khoảng
trắng hay phải quote trong shell.
