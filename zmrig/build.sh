#!/usr/bin/env bash
#
# build.sh - build the zmrig binary: the hash engine (C++ from this repo) plus
# the miner (Zig).
#
#   ./zmrig/build.sh                 # release build into zmrig/out/zmrig
#   ./zmrig/build.sh --jobs 8        # parallel C++ compile
#   ./zmrig/build.sh --no-zig        # only rebuild libxmorx.a
#   ./zmrig/build.sh --portable      # no -march=native (run on any x86-64)
#   ./zmrig/build.sh --arch=NAME     # gcc -march=NAME, e.g. x86-64-v2, znver3
#   ./zmrig/build.sh --static        # one file, no libc at all (musl, via zig)
#   ./zmrig/build.sh --output DIR    # write the binary/objects to DIR
#
# --static cross-compiles the whole engine with `zig cc` against musl and links
# it into a single file that runs on any Linux, including an Alpine live image
# that has no glibc and no shared libraries at all. Combine it with --arch to
# pick the instruction set the ISO build ships.
#
# Requirements: g++, ar, zig 0.13 (or set ZIG=/path/to/zig).
# The Zig part has no external dependencies - nothing is downloaded.
#
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
HERE="${ROOT}/zmrig"
OUT="${OUT_DIR:-${HERE}/out}"
OBJ="${OUT}/obj"
JOBS=$(nproc 2>/dev/null || echo 2)
BUILD_ZIG=1
MARCH="-march=native"
MCPU="native"
STATIC=0
ZIG="${ZIG:-zig}"   # replaced by scripts/find-zig.sh when left as the default

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)      JOBS="${2:?}"; shift ;;
        --jobs=*)    JOBS="${1#*=}" ;;
        --output)    OUT="${2:?}"; OBJ="${OUT}/obj"; shift ;;
        --output=*)  OUT="${1#*=}"; OBJ="${OUT}/obj" ;;
        --no-zig)    BUILD_ZIG=0 ;;
        --portable)  MARCH=""; MCPU="baseline" ;;
        --static)    STATIC=1 ;;
        --arch)      ARCH="${2:?}"; MARCH="-march=${ARCH}"; MCPU="${ARCH//-/_}"; shift ;;
        --arch=*)    ARCH="${1#*=}"; MARCH="-march=${ARCH}"; MCPU="${ARCH//-/_}" ;;
        -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

command -v g++ >/dev/null || { echo "g++ is required" >&2; exit 1; }

# Zig 0.13, from PATH, from ZIG=..., or from the `ziglang` pip wheel. Resolved
# here, before the static path asks for it. The search is version-aware on
# purpose: a newer Zig on PATH is not a usable Zig for this code, and silently
# using it produces a compile error that looks like a broken source tree.
if [ "$ZIG" = "zig" ]; then
    ZIG=$("${ROOT}/scripts/find-zig.sh") || {
        echo "zig 0.13 not found (set ZIG=/path/to/zig, or pip install ziglang==0.13.0)" >&2
        exit 1
    }
fi

# A static build has to come from one toolchain: gcc links glibc, and glibc
# cannot be dropped into a musl image. `zig c++` is clang plus a musl sysroot,
# which is the same compiler family upstream RandomX and XMRig are tested with.
CXX_BIN=(c++)
CC_BIN=(cc)
if [ "$STATIC" -eq 1 ]; then
    command -v "$ZIG" >/dev/null || [ -x "$ZIG" ] || { echo "zig is required for --static" >&2; exit 1; }
    CXX_BIN=("$ZIG" c++ -target x86_64-linux-musl)
    CC_BIN=("$ZIG" cc  -target x86_64-linux-musl)
fi

CXXFLAGS=(
    -std=c++11 -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -DXMRIG_VAES -fno-rtti -fexceptions -pthread
    -maes -Wall -Wno-strict-aliasing -Wno-class-memaccess
    -I"${ROOT}/src" -I"${ROOT}/src/3rdparty" -I"${ROOT}/src/crypto/randomx"
    -I"${HERE}/capi"
)
[ -n "$MARCH" ] && CXXFLAGS+=("$MARCH" -mtune=native -fno-plt)
# shellcheck disable=SC2206
[ -n "${EXTRA_FLAGS:-}" ] && { CXXFLAGS+=(${EXTRA_FLAGS}); }

CFLAGS=(
    -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -pthread -maes -std=gnu99 -fno-strict-aliasing
    -I"${ROOT}/src" -I"${ROOT}/src/3rdparty" -I"${ROOT}/src/crypto/randomx"
)
# argon2 ships its own blake2.h; src/crypto/randomx would shadow it and the two
# structs have different layouts, so these files get their own include order.
ARGON_CFLAGS=(
    -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -pthread -maes -std=gnu99 -fno-strict-aliasing
    -I"${ROOT}/src/3rdparty/argon2/lib" -I"${ROOT}/src/3rdparty/argon2/include"
    -I"${ROOT}/src/3rdparty/argon2" -I"${ROOT}/src/3rdparty" -I"${ROOT}/src"
)
[ -n "$MARCH" ] && CFLAGS+=("$MARCH" -mtune=native -fno-plt)
[ -n "$MARCH" ] && ARGON_CFLAGS+=("$MARCH" -mtune=native -fno-plt)
# shellcheck disable=SC2206
[ -n "${EXTRA_FLAGS:-}" ] && { CFLAGS+=(${EXTRA_FLAGS}); ARGON_CFLAGS+=(${EXTRA_FLAGS}); }

if [ "$STATIC" -eq 1 ]; then
    CXXFLAGS+=(-static)
    CFLAGS+=(-static)
    ARGON_CFLAGS+=(-static)
fi

# Three translation units use AVX-512 intrinsics and are only ever called behind
# a runtime CPUID check, so their instruction set is not the build baseline: the
# flags below override whatever -march said. Clang 19 split 512-bit EVEX out of
# -mavx512f into a feature of its own, and a -march=x86-64-v2 baseline has that
# feature off, which turned every _mm512_* call in those files into "requires
# target feature 'evex512'" on a newer compiler than the one this was tested on.
# Ask for the feature by name when the compiler knows it; ignore it when it does
# not, because older clang enables 512-bit from -mavx512f alone.
AVX512_FLAGS=(-mavx512f -mavx512vl -mavx512dq -mavx512bw -mvaes)
# Probed by compiling a real file to a real object: zig's driver does not
# implement -fsyntax-only (it answers FileNotFound for every input), and it
# treats a trailing `-` as an output name, so both of the obvious one-liners
# report "unsupported" no matter what the compiler can do.
# The same argument applies to every other ISA-specific translation unit, and it
# is the reason a `--portable` build used to be fragile rather than merely slow:
# RandomX picks an implementation at runtime from CPUID, but the *object* still
# has to be compiled with the instructions it uses. With no -march, gcc compiles
# the AVX2 files with AVX2 off, which is not a warning to ignore - "-Wpsabi: AVX
# vector return without AVX enabled changes the ABI" means the calling
# convention of those functions is not the one the rest of the build assumes.
# Clang refuses the same code outright, so the flag has to be per file, not per
# build.
ISA_SSE41=(-msse4.1)
ISA_SSSE3=(-mssse3)
ISA_AVX2=(-mavx2)

probe_dir=$(mktemp -d 2>/dev/null || echo "${OBJ}/probe")
mkdir -p "$probe_dir"
printf 'int main(void){return 0;}\n' > "${probe_dir}/probe.cpp"
if "${CXX_BIN[@]}" -mevex512 -c "${probe_dir}/probe.cpp" -o "${probe_dir}/probe.o" >/dev/null 2>&1; then
    AVX512_FLAGS+=(-mevex512)
fi
rm -rf "$probe_dir"

# Objects are not interchangeable between flag sets. This signature used to be
# computed from the *environment* arrays, which were still empty at that point,
# so a --static or --arch build in the same output directory silently reused the
# native objects. Hash the real flags, and the mode, now that they exist.
FLAGS_SIG=$(printf '%s\n' "${CXXFLAGS[@]}" "${CFLAGS[@]}" "${ARGON_CFLAGS[@]}" \
            "${AVX512_FLAGS[@]}" "${ISA_SSE41[@]}" "${ISA_SSSE3[@]}" "${ISA_AVX2[@]}" \
            "static=${STATIC}" "arch=${MARCH}" \
            | sha256sum | cut -d' ' -f1)

if [ -d "$OBJ" ] && [ "$(cat "$OBJ/.flags" 2>/dev/null)" != "$FLAGS_SIG" ]; then
    echo "==> compiler flags changed, rebuilding everything"
    rm -rf "$OBJ"
fi

mkdir -p "$OBJ"
printf '%s\n' "$FLAGS_SIG" > "$OBJ/.flags"

RX="${ROOT}/src/crypto/randomx"

# --- C++: RandomX core, the XMRig allocator it depends on, RxAlgo, the shim ---
CXX_SOURCES=(
    "${RX}/aes_hash.cpp"
    "${RX}/aes_hash_vaes512.cpp"
    "${RX}/allocator.cpp"
    "${RX}/blake2_generator.cpp"
    "${RX}/bytecode_machine.cpp"
    "${RX}/dataset.cpp"
    "${RX}/instructions_portable.cpp"
    "${RX}/randomx.cpp"
    "${RX}/soft_aes.cpp"
    "${RX}/superscalar.cpp"
    "${RX}/virtual_machine.cpp"
    "${RX}/virtual_memory.cpp"
    "${RX}/vm_compiled.cpp"
    "${RX}/vm_compiled_light.cpp"
    "${RX}/vm_interpreted.cpp"
    "${RX}/vm_interpreted_light.cpp"
    "${RX}/jit_compiler_x86.cpp"
    "${ROOT}/src/crypto/common/VirtualMemory.cpp"
    "${ROOT}/src/crypto/common/VirtualMemory_unix.cpp"
    "${ROOT}/src/crypto/common/HugePagesInfo.cpp"
    "${ROOT}/src/crypto/common/MemoryPool.cpp"
    "${ROOT}/src/crypto/common/LinuxMemory.cpp"
    "${ROOT}/src/crypto/common/Assembly.cpp"
    "${ROOT}/src/crypto/rx/RxAlgo.cpp"
    "${ROOT}/src/crypto/rx/RxFix_linux.cpp"
    "${ROOT}/src/backend/cpu/Cpu.cpp"
    "${ROOT}/src/backend/cpu/CpuThread.cpp"
    "${ROOT}/src/backend/cpu/CpuThreads.cpp"
    "${ROOT}/src/backend/cpu/platform/BasicCpuInfo.cpp"
    "${ROOT}/src/base/crypto/Algorithm.cpp"
    "${ROOT}/src/base/tools/Chrono.cpp"
    "${ROOT}/src/base/tools/String.cpp"
    "${ROOT}/src/base/io/json/Json.cpp"
    "${ROOT}/src/3rdparty/fmt/format.cc"
    "${HERE}/capi/xmo_randomx.cpp"
    "${HERE}/capi/xmo_msr.cpp"
    "${HERE}/capi/shim.cpp"
)

# --- C: blake2, argon2 (cache initialisation), panthera helpers ---
C_SOURCES=(
    "${RX}/blake2/blake2b.c"
    "${RX}/blake2/blake2b_sse41.c"
    "${RX}/blake2/avx2/blake2b_avx2.c"
    "${RX}/reciprocal.c"
    "${RX}/panthera/sha256.c"
    "${RX}/panthera/KangarooTwelve.c"
    "${RX}/panthera/KeccakP-1600-reference.c"
    "${RX}/panthera/KeccakSpongeWidth1600.c"
    "${RX}/panthera/yespower-opt.c"
)

ARGON_SOURCES=(
    "${ROOT}/src/3rdparty/argon2/lib/argon2.c"
    "${ROOT}/src/3rdparty/argon2/lib/core.c"
    "${ROOT}/src/3rdparty/argon2/lib/blake2/blake2.c"
    "${ROOT}/src/3rdparty/argon2/lib/encoding.c"
    "${ROOT}/src/3rdparty/argon2/lib/genkat.c"
    "${ROOT}/src/3rdparty/argon2/lib/impl-select.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-arch.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-avx2.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-avx512f.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-sse2.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-ssse3.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-xop.c"
)

ASM_SOURCES=(
    "${RX}/jit_compiler_x86_static.S"
)

obj_path() {
    # Flatten the path so two files with the same basename cannot collide.
    local src="$1"
    local rel="${src#${ROOT}/}"
    printf '%s/%s.o' "$OBJ" "${rel//\//_}"
}

echo "==> compiling hash engine ($(( ${#CXX_SOURCES[@]} + ${#C_SOURCES[@]} + ${#ARGON_SOURCES[@]} + ${#ASM_SOURCES[@]} )) files, -j${JOBS})"

objects=()
LAST_CMD=()

compile_one() {
    local src="$1" obj="$2"
    local ext="${src##*.}"
    LAST_CMD=()
    case "$ext" in
        c)
            # Every ISA-specific unit carries its own flags: see ISA_* above.
            case "$src" in
                */argon2-avx512f.c)
                    LAST_CMD=("${CC_BIN[@]}" "${ARGON_CFLAGS[@]}" "${AVX512_FLAGS[@]}" -x c -c "$src" -o "$obj") ;;
                */argon2-avx2.c)
                    LAST_CMD=("${CC_BIN[@]}" "${ARGON_CFLAGS[@]}" "${ISA_AVX2[@]}" -x c -c "$src" -o "$obj") ;;
                */argon2-ssse3.c)
                    LAST_CMD=("${CC_BIN[@]}" "${ARGON_CFLAGS[@]}" "${ISA_SSSE3[@]}" -x c -c "$src" -o "$obj") ;;
                */3rdparty/argon2/*)
                    LAST_CMD=("${CC_BIN[@]}" "${ARGON_CFLAGS[@]}" -x c -c "$src" -o "$obj") ;;
                */blake2/avx2/blake2b_avx2.c)
                    LAST_CMD=("${CC_BIN[@]}" "${CFLAGS[@]}" "${ISA_AVX2[@]}" -x c -c "$src" -o "$obj") ;;
                */blake2b_sse41.c)
                    LAST_CMD=("${CC_BIN[@]}" "${CFLAGS[@]}" "${ISA_SSE41[@]}" -x c -c "$src" -o "$obj") ;;
                *)
                    LAST_CMD=("${CC_BIN[@]}" "${CFLAGS[@]}" -x c -c "$src" -o "$obj") ;;
            esac ;;
        S)
            LAST_CMD=("${CC_BIN[@]}" "${CFLAGS[@]}" -x assembler-with-cpp -c "$src" -o "$obj") ;;
        *)
            # AVX-512 translation units carry their own flags: see AVX512_FLAGS.
            case "$src" in
                */aes_hash_vaes512.cpp)
                    LAST_CMD=("${CXX_BIN[@]}" "${CXXFLAGS[@]}" "${AVX512_FLAGS[@]}" -c "$src" -o "$obj") ;;
                *)
                    LAST_CMD=("${CXX_BIN[@]}" "${CXXFLAGS[@]}" -c "$src" -o "$obj") ;;
            esac ;;
    esac
    "${LAST_CMD[@]}"
}

# A background compile must not be able to fail silently: the archive would
# then be built from stale objects. Each object keeps its own stderr, so a
# failure can name the file that failed, the command that ran, and why - four
# compilers writing to one terminal interleave their output, and a runner that
# kills a compiler for memory prints nothing at all.
compile_bg() {
    local src="$1" obj="$2"
    local err
    err="${OBJ}/$(basename -- "${obj%.o}").err"
    if ! compile_one "$src" "$obj" 2>"$err"; then
        # Every failure is recorded, not just the last one to finish: when the
        # toolchain itself is missing something (a header, a crt object) every
        # file fails at once and reporting one of them sends the reader to a
        # perfectly good source file.
        printf '%s\n' "$src" >> "${OBJ}/.failed"
        {
            printf 'error: compiling %s failed\n' "${src#"${ROOT}/"}"
            printf '  command:'
            printf ' %q' "${LAST_CMD[@]}"
            printf '\n'
            # The first lines, not the last: the tail of a failed compile is the
            # note under the error ("note: see declaration of ..."), and the line
            # that matters is at the top.
            head -n 12 "$err" 2>/dev/null | sed 's/^/  | /' || true
        } >&2
    else
        rm -f "$err"
    fi
}

rm -f "${OBJ}/.failed"

for src in "${CXX_SOURCES[@]}" "${C_SOURCES[@]}" "${ARGON_SOURCES[@]}" "${ASM_SOURCES[@]}"; do
    obj=$(obj_path "$src")
    objects+=("$obj")
    if [ -f "$obj" ] && [ "$obj" -nt "$src" ]; then
        continue
    fi
    compile_bg "$src" "$obj" &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
done
wait || true

if [ -f "${OBJ}/.failed" ]; then
    failed_n=$(wc -l < "${OBJ}/.failed" | tr -d ' ')
    failed_src=$(head -1 "${OBJ}/.failed")
    rm -f "${OBJ}/.failed"
    if [ "$failed_n" -gt 1 ]; then
        echo "error: ${failed_n} files failed to compile; the first was ${failed_src}" >&2
        echo "       (that many at once usually means the toolchain is incomplete, not the code)" >&2
    else
        echo "error: compilation failed: ${failed_src}" >&2
    fi
    exit 1
fi

echo "==> archiving libxmorx.a"
rm -f "${OUT}/libxmorx.a"
ar rcs "${OUT}/libxmorx.a" "${objects[@]}"

if [ "${OUT_DIR:-}" != "" ] && [ "$BUILD_ZIG" -eq 1 ]; then BUILD_ZIG=0; fi

if [ "$BUILD_ZIG" -eq 0 ]; then
    echo "built ${OUT}/libxmorx.a"
    exit 0
fi


echo "==> building zmrig ($($ZIG version))"
# `zig` is a multiplexer, not a compiler: --version is not a command it has. The
# version of the compiler inside it is what actually decides whether this file
# set compiles, so ask the C++ driver and say so.
if [ "$STATIC" -eq 1 ]; then
    echo "==> compiler: ${CXX_BIN[*]} -> $("${CXX_BIN[@]}" -dM -E -x c++ /dev/null 2>/dev/null | awk '/__clang_major__/ {print "clang " $3}' | head -1)"
else
    echo "==> compiler: $("${CXX_BIN[0]}" --version 2>/dev/null | head -1)"
fi
echo "==> avx-512 flags for the three files that use them: ${AVX512_FLAGS[*]}"

CPU_FLAG=()
[ -n "$MARCH" ] && CPU_FLAG=("-mcpu=${MCPU}")

# The hash engine is C++, so the binary needs the C++ runtime and the unwinder.
# Zig does not resolve plain "-lstdc++", so pass the real files.
LINK_RT=()
if [ "$STATIC" -eq 1 ]; then
    # musl has no separate pthread or librt. The engine is C++, so the C++
    # runtime still has to be named - Zig ships libc++ and libc++abi as static
    # archives, which is the same runtime `zig c++` compiled the objects
    # against. Linking libstdc++ here instead leaves __gxx_personality_v0
    # undefined, because those archives were never built with gcc.
    TARGET=(-target x86_64-linux-musl)
    LINK_RT=(-lc++ -lunwind)
else
    LIBSTDCXX=$(c++ -print-file-name=libstdc++.so 2>/dev/null)
    LIBGCC_S=$(c++ -print-file-name=libgcc_s.so.1 2>/dev/null)
    [ -f "${LIBSTDCXX:-/nonexistent}" ] || LIBSTDCXX=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
    [ -f "${LIBGCC_S:-/nonexistent}" ] || LIBGCC_S=/usr/lib/x86_64-linux-gnu/libgcc_s.so.1
    TARGET=()
    LINK_RT=("$LIBSTDCXX" "$LIBGCC_S")
fi

"$ZIG" build-exe "${HERE}/src/main.zig" "${TARGET[@]}" \
    -O ReleaseFast "${CPU_FLAG[@]}" \
    --name zmrig \
    -femit-bin="${OUT}/zmrig" \
    --cache-dir "${OUT}/zig-cache" \
    --global-cache-dir "${OUT}/zig-global" \
    -lc -lpthread -lm \
    -L"${OUT}" -lxmorx "${LINK_RT[@]}"

echo
echo "built ${OUT}/zmrig"
"${OUT}/zmrig" --version 2>/dev/null || true
