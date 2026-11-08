---
title: Chạy bằng Docker
description: Miner và pool trong cùng một image đã phát hành — ghcr.io/molik-labs/zmrig — cấu hình bằng đúng tên biến như trên thiết bị, kiểm tra ví ở mọi lần khởi động, và chỉ cập nhật khi thật sự có bản mới.
image: https://molik-labs.github.io/ZMRIG/img/og-vi.png
---

# Chạy bằng Docker

Một image duy nhất, do CI của chính kho này dựng từ cùng một commit với các bản
binary phát hành, đẩy lên registry của GitHub:

```console
$ docker run --rm -e WALLET=4YourAddress… -e POOL=gulf.moneroocean.stream:10001 \
    ghcr.io/molik-labs/zmrig
```

Không cần cài đặt, không cần compiler, không phụ thuộc gì. `docker inspect` trên
container đang chạy trả lời được nó được dựng từ commit nào.

| Tag | Nó là gì |
| --- | --- |
| `ghcr.io/molik-labs/zmrig:6.48.0` | một bản phát hành, và nó không bao giờ đổi |
| `ghcr.io/molik-labs/zmrig:latest` | bản phát hành mới nhất |
| `ghcr.io/molik-labs/zmrig:edge` | đầu nhánh `BETA` — để thử, không dành cho rig bạn cần |

## Kiểm tra ví trước mọi thứ

Một rig đào vào địa chỉ không thể trả tiền cho nó là sai lầm đắt nhất trong dự án
này, vì nó trông y hệt một rig đang chạy tốt. Image trả lời câu đó mà không cần
pool, không cần config, không cần boot:

```console
$ docker run --rm -e WALLET=4YourAddress… ghcr.io/molik-labs/zmrig check
valid   4YourAddress…
  check checksum verified (Keccak-256)
  kind  standard
  net   mainnet
```

Một ký tự sai bị từ chối, và nói rõ hỏng ở bước kiểm tra nào:

```console
$ docker run --rm -e WALLET=4YourAddress…f ghcr.io/molik-labs/zmrig check
invalid 4YourAddress…f
  checksum does not match: at least one character is wrong
```

Một ký tự sai bị từ chối, và phép kiểm tra đó chạy lại lúc khởi động, do chính
miner thực hiện, nên kết luận luôn có trong log của mọi container dù không ai hỏi.

## Cần đặt gì

Tên biến là đúng những tên `zmrig-os` ghi vào `/etc/zmrig/os.conf`, nên rig cài từ
image thiết bị và rig chạy từ image này được cấu hình bằng cùng một bộ từ.

| Biến | Mặc định | Nó làm gì |
| --- | --- | --- |
| `WALLET` | — | địa chỉ nhận tiền của rig. Bắt buộc |
| `POOL` | — | `host:port`, hoặc `tls://`, `ws://`, `wss://` |
| `WORKER` | `x` | tên worker. Nhiều rig cùng một ví gộp vào một số dư |
| `MODE` | `max` | `max` (hết tốc lực), `eco` (nhiều hash nhất trên mỗi watt), `safe` (thêm bộ điều nhiệt), `light` (256 MiB) |
| `ALGO` | `auto` | `rx/0`, `rx/wow`, … hoặc `auto`, để pool tự chuyển rig giữa các biến thể RandomX |
| `THREADS` | `auto` | tự tính theo cache, và bị chặn trên bởi hạn mức CPU (bên dưới) |
| `DONATE` | `3` | phí phát triển, tính theo phần trăm. `0` là tắt |
| `SAFE_TEMP` | `72` | trần nhiệt `MODE=safe` không bao giờ vượt, °C |
| `MSR` | `auto` | `on`, `off`, `auto`; `safe` không bao giờ ghi thanh ghi |
| `API_PORT` | `0` | API giám sát của miner; `0` là tắt |
| `API_HOST` | `0.0.0.0` | địa chỉ bind khi đã đặt `API_PORT` — bind loopback thì từ ngoài container không tới được |
| `API_TOKEN` | — | bắt buộc `Authorization: Bearer T` trên API đó |
| `EXTRA_ARGS` | — | thêm cờ cho miner, tách theo khoảng trắng, không bao giờ đi qua shell |

`docker run --rm -e WALLET=… -e POOL=… ghcr.io/molik-labs/zmrig args` in ra đúng
dòng lệnh nó sẽ chạy rồi thoát — câu trả lời cho "vì sao máy 8 lõi mà nó dùng có
4 luồng".

Bảng đầy đủ, kể cả hai biến chỉ tồn tại cho test, nằm ở
[doc/DOCKER.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/DOCKER.md).

## Hai chỗ tối ưu riêng của container

**Hạn mức CPU không phải mặt nạ affinity.** `docker run --cpus=2` giới hạn cả
nhóm, nhưng tiến trình vẫn thấy mọi CPU của host, nên miner tự tính theo số CPU
rồi đòi mỗi lõi một luồng — và sau đó phải chia nhau thời gian của hai lõi. Như
vậy chậm hơn hai luồng chạy hết tốc: khi hạn mức cạn, cả nhóm bị dừng, và một
luồng đang có trang dataset trong cache ngồi không hết phần còn lại của chu kỳ.
Image đọc hạn mức cgroup và, khi `THREADS=auto`, chặn số luồng theo đó:

```console
$ docker run --rm --cpus=2 -e WALLET=… -e POOL=… ghcr.io/molik-labs/zmrig args
zmrig: the container is limited to 2 CPUs (16 visible): 2 mining threads
/usr/local/bin/zmrig -o pool.example:3333 -u 4… -p x -t 2 --profile free …
```

`--cpuset-cpus` thì không cần gì trong số này: kernel giấu các CPU còn lại và
miner tự tính đúng.

**Phí nằm ngay trên dòng lệnh.** `--donate-level 3` luôn được truyền tường minh,
nên con số một rig phải trả hiện ra trong `args` thay vì nằm trong mặc định của
binary. Ba phần trăm là mặc định; `DONATE=0` là tắt, và bản dựng tự hỏng test nếu
mã và tài liệu nói khác nhau.

**Huge page chỉ cần một lệnh ở host, không cần cờ nào cho container.** Pool thuộc
về kernel (`sysctl -w vm.nr_hugepages=1168`, hoặc `zmrig-os hugepages` trên máy
cài image), và container không có quyền đặc biệt vẫn map được: mapping
`MAP_HUGETLB` ẩn danh không cần capability nào — đã đo, 2336 MB trên 2336 MB lấy
từ pool với `CapEff: 0` và không mount `/dev/hugepages`. `docker run … args` in ra
cả hai trường hợp, kèm con số 18 % mà một pool rỗng làm mất.

**`--memory` là giới hạn thật và nó quyết định chế độ.** `rx/0` map 2336 MB; dưới
hạn mức nhỏ hơn, miner chỉ giữ cache 256 MB và dựng lại dataset cho từng hash,
chậm khoảng 10 lần. Nó nói rõ lúc khởi động và trong `--check`, và dòng `memory`
in ra thứ nó *sẽ* map chứ không phải thứ nó muốn map. Cho container 3 GiB, hoặc
chọn `MODE=light` một cách có ý thức.

## Thứ container không làm được

Ghi MSR cần `/dev/cpu/*/msr` và quyền root, cảm biến nhiệt không nằm trong
namespace. Image nói rõ điều đó thay vì hỏng lặng lẽ:

* **Ghi MSR** (`MSR=on`) cần `--device /dev/cpu/0/msr --cap-add SYS_RAWIO
  --user 0`, mỗi CPU một `--device`: container chạy root chọc vào thanh ghi CPU,
  đáng 5-15 % trên máy thật và không đáng gì trong VM. `MSR=auto` để chính miner
  tự dò, và nó sẽ nói không.
* **`MODE=safe`** đọc cảm biến của host — đó là điều bạn muốn, và cũng là lý do bộ
  điều nhiệt nên nằm ở host khi host chạy nhiều hơn một container.
* **CPU governor và affinity của interrupt** là chuyện của cả host:
  `scripts/tune-linux.sh` trên host là nửa còn lại của `--profile free`.

## Cập nhật

Image được thay, không bao giờ được vá tại chỗ:

```console
$ ./zmrig-docker-update --check     # 0 đang mới, 3 có bản mới, 2 không biết
$ ./zmrig-docker-update --apply     # pull, rồi dựng lại — chỉ khi thật sự có bản mới
```

`--check` chạy bộ kiểm tra nằm trong image đã có trên đĩa: nó hỏi registry công
khai qua HTTPS ẩn danh và so nhãn bản phát hành với version đã nướng vào container
đang chạy. Không cần Docker socket trong container, không cần `node` trên host.
`--apply` pull trước rồi mới dựng lại, vì một lần pull hỏng phải để nguyên miner
đang chạy.

Cả hai nửa, file compose và một timer systemd chạy hằng ngày nằm trong
`deploy/docker/`. Timer coi "đã cài được bản mới" (3) là thành công và "không tới
được registry" (2) là thông báo — miner không được khởi động lại chỉ vì GitHub
mất mạng vài phút, và một unit báo đỏ mỗi lần như thế là một unit bị mask.

Ghim phiên bản là lựa chọn còn lại, và là lựa chọn tốt:
`ghcr.io/molik-labs/zmrig:6.48.0` không bao giờ đổi, nên `compose pull` hằng đêm
không làm gì cho tới khi bạn sửa file.

## Pool, từ chính image đó

```console
$ docker run -d --name pool -p 3333:3333 -p 8080:8080 \
    -e DAEMON=http://your-node:18081 \
    -e OPERATOR_ADDRESS=4YourAddress… \
    -v pool-data:/app/pool/data \
    ghcr.io/molik-labs/zmrig pool
```

Rig và pool nó đào vào vì thế không bao giờ được dựng từ hai commit khác nhau.
Cấu hình của pool nằm ở [chạy một pool](/docs/fleet/pool).
