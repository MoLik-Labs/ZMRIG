---
title: Bộ tool, từng file
description: Sửa file nào cho installer, tuner, appliance hay container — và bài test giữ cho mỗi file đó đúng.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Bộ tool, từng file

Miner là `zmrig/`. Phần còn lại mà chủ rig *chạy* — cài, tune, giám sát, cập
nhật, container — là bộ tool, và nó có một trang mục lục:
[`tool/README.md`](https://github.com/Molik-Labs/ZMRIG/blob/BETA/tool/README.md).
Trang này là bản đồ tương tự cho docs, kèm lý do vì sao mỗi file nằm ở chỗ nó nằm.

| Bạn chạy | Nó là | Sửa khi nào | Test bởi |
| --- | --- | --- | --- |
| `oneclick.sh` | build, tune, cài, giám sát, cập nhật, purge | installer làm sai trên máy sạch | `tests/oneclick/` |
| `zmrig-os` | CLI của appliance: `setup`, `plan`, `doctor`, `hugepages`, `update`, `rollback`, `run` | một quyết định lúc boot là sai | `os/tests/` |
| `os/plan.sh` | phần tính toán: thread, page, ngân sách bộ nhớ, độ trễ restart | một con số phải tính khác đi | `os/tests/plan.sh` |
| `zmrig-tune` | huge pages, THP, governor, IRQ, MSR | host chưa được chuẩn bị cho RandomX | `tests/oneclick/tune-targets.sh` |
| `deploy/docker/entry.js` | biến môi trường → cờ miner, và các lệnh `args`/`plan`/`check`/`pool` | container trả lời khác host | `deploy/docker/tests/` |
| `deploy/docker/Dockerfile` | image hai tầng của `ghcr.io/molik-labs/zmrig` | image to hơn hoặc chậm hơn mức cần | `deploy/docker/tests/dockerfile.test.js` |
| `os/build-iso.sh` | appliance khởi động được | ISO cần khác bản cài | `tests/oneclick/plan.sh` |

## Vì sao không gom hết vào một thư mục

Không được. `zmrig-os` phải nằm ở `/usr/local/bin/zmrig-os` *bên trong image*,
`oneclick.sh` phải ở gốc repo để lệnh cài một dòng `curl … | sudo bash` chạy
đúng, và file của container phải ở chỗ `docker build` copy ra. Gom hết vào một
thư mục sẽ cần wrapper, và wrapper làm thay đổi file mà `curl | bash` thực sự
đọc — đúng thứ mà một lệnh cài một dòng không được phép mập mờ.

Nên cách xếp là theo người dùng, và mục lục chính là thứ biến nó thành một chỗ:

| Cây | Dành cho | Đừng nhầm với |
| --- | --- | --- |
| `oneclick.sh`, `scripts/`, `os/`, `deploy/` | chạy rig | miner |
| `zmrig/`, `src/` | engine hash và front end của nó | thứ người dùng cấu hình |
| `pool/`, `proxy/`, `serve/`, `fleet/` | dịch vụ bạn tự host | bộ tool của rig |
| `doc/`, `site/`, `web/` | tài liệu hai ngôn ngữ | `docs/` và `vi/`, bản build mà Pages phục vụ |

## Hai quy tắc

`tests/lint/tool-layout.sh` chạy trong CI mỗi lần push, và nó giữ cho danh sách
này có giá trị:

1. **Mọi đường dẫn trong mục lục đều tồn tại**, và mọi script ở gốc repo đều có
   mặt trong đó. Một entry point mới không được phép xuất hiện mà không ai biết.
2. **Mọi entry point được nêu đều có thư mục test tồn tại.** Tool không có test
   sẽ hỏng trên máy người khác, im lặng, lúc 3 giờ sáng.

## Nhánh

`ALPHA` → `BETA` → `master`, ba nhánh có ý nghĩa:

| Nhánh | Nó mang gì | Cài từ đó thế nào |
| --- | --- | --- |
| `ALPHA` | bản kế tiếp; có thể hỏng giữa các commit | `MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install` |
| `BETA` | thứ đang được cài hôm nay; mọi thay đổi đã merge đều vào đây trước | mặc định |
| `master` | bản phát hành gần nhất | `MINER_BRANCH=master …` |

Bộ tool là cùng một mã trên cả ba: một bản phát hành là một commit đã sống sót
qua `BETA`, không phải bản sao thứ hai của bộ tool.
