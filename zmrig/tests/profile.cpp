/*
 * profile.cpp - where the time in one RandomX hash actually goes.
 *
 * The miner is a Zig program around a C++ hash engine, and the question "what
 * should be made faster" has one honest answer only if it is measured: this
 * prints the cycles spent in each phase of a hash, through the same C API the
 * mining loop calls.
 *
 * It is built against an engine compiled with -DXMO_PROFILE (see profile.sh),
 * which is the only build where the counters exist. In a release build the
 * instrumentation is preprocessor-removed, so shipping this file costs the
 * miner nothing.
 *
 * Two modes, because the miner uses the second:
 *   one-shot  - randomx_calculate_hash: fill, 8 programs, final AES pass.
 *   pipelined - hash_first/hash_next: the final AES pass of one hash and the
 *               fill of the next are the same loop over the scratchpad.
 *
 * Everything here is single-threaded on purpose: with two workers the counters
 * would sum both, and the shares would be meaningless.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <sys/mman.h>
#include <x86intrin.h>

#include "xmo_randomx.h"

extern "C" {
/* Present only in a -DXMO_PROFILE build; weak so this file also links against
 * a plain release engine, where it prints the rate and no phases. */
extern unsigned long long xmo_prof_tsc[8] __attribute__((weak));
extern unsigned long long xmo_prof_hashes __attribute__((weak));
}

static double now_s() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int run(int rounds, bool pipelined, int algo) {
    char err[256] = {0};
    /* 1 = huge pages, 2 = huge pages for the JIT, 4 = full dataset, 8 = JIT.
     * These are the flags the miner sets by default. */
    xmo_engine *engine = xmo_engine_new(algo, 1 | 2 | 4 | 8, err, sizeof(err));
    if (!engine) { printf("engine: %s\n", err); return 1; }

    uint8_t seed[32];
    for (int i = 0; i < 32; i++) seed[i] = (uint8_t)i;

    if (xmo_engine_seed(engine, seed, sizeof(seed), 2, err, sizeof(err)) != 0) {
        printf("seed: %s\n", err);
        xmo_engine_free(engine);

        return 1;
    }

    /* 1 = huge pages, 2 = JIT - the flags the worker threads use. */
    xmo_vm *vm = xmo_vm_new(engine, 3, 0, err, sizeof(err));
    if (!vm) { printf("vm: %s\n", err); xmo_engine_free(engine); return 1; }

    uint8_t blob[76], out[32];
    memset(blob, 0xab, sizeof(blob));
    alignas(64) uint64_t temp[8];

    xmo_hash(vm, blob, sizeof(blob), out);   /* warm the JIT before counting */

    if (xmo_prof_tsc) memset(xmo_prof_tsc, 0, sizeof(unsigned long long) * 8);
    if (&xmo_prof_hashes) xmo_prof_hashes = 0;

    const double t0 = now_s();

    if (pipelined) {
        xmo_hash_first(vm, blob, sizeof(blob), temp);
        for (int i = 0; i < rounds; i++) {
            memcpy(blob, &i, sizeof(i));
            xmo_hash_next(vm, temp, blob, sizeof(blob), out);
        }
    } else {
        for (int i = 0; i < rounds; i++) {
            memcpy(blob, &i, sizeof(i));
            xmo_hash(vm, blob, sizeof(blob), out);
        }
    }

    const double dt = now_s() - t0;

    printf("%s: %d hashes in %.3f s = %.1f H/s (one thread)\n",
           pipelined ? "pipelined (what the miner runs)" : "one-shot", rounds, dt, rounds / dt);

    if (xmo_prof_tsc) {
        const double n = (double)xmo_prof_hashes;
        double total = 0;
        for (int i = 0; i < 5; i++) total += (double)xmo_prof_tsc[i];

        const char *names[5] = {
            "blake2b(blob)",
            "scratchpad fill / rounding",
            "8 VM programs (dataset reads)",
            "blake2b(register file) x7",
            "final AES pass (2 MiB)",
        };

        printf("  cycles per hash: %.0f\n", total / n);
        for (int i = 0; i < 5; i++) {
            printf("    %-30s %10.0f  %5.1f %%\n", names[i],
                   (double)xmo_prof_tsc[i] / n, 100.0 * (double)xmo_prof_tsc[i] / total);
        }
    }

    xmo_vm_free(vm);
    xmo_engine_free(engine);

    return 0;
}

/* The other half of the answer: what one random read from a 2 GiB buffer costs
 * on this machine. A hash makes 16384 of them - ProgramCount (8) x
 * ProgramIterations (2048) - each 64 bytes, each dependent on the one before,
 * so this number sets the ceiling. On bare metal it is 70-90 ns; a VM with an
 * oversubscribed host is several times that, and no amount of source
 * optimisation changes it. */
static int latency(size_t mib) {
    const size_t bytes = mib << 20;
    const size_t lines = bytes / 64;

    void *mem = mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
    if (mem == MAP_FAILED) { printf("latency: mmap of %zu MiB failed\n", mib); return 1; }
    madvise(mem, bytes, MADV_HUGEPAGE);

    uint64_t *base = (uint64_t *)mem;
    size_t *perm = (size_t *)malloc(lines * sizeof(size_t));
    if (!perm) { munmap(mem, bytes); return 1; }

    for (size_t i = 0; i < lines; i++) perm[i] = i;
    unsigned seed = 12345;
    for (size_t i = lines - 1; i > 0; i--) {
        seed = seed * 1103515245u + 12345u;
        const size_t j = (size_t)(seed >> 8) % (i + 1);
        const size_t t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }

    /* One cycle through every line: each load depends on the previous one, which
     * is the shape of the RandomX address chain. */
    for (size_t i = 0; i < lines; i++)
        base[perm[i] * 8] = (uint64_t)&base[perm[(i + 1) % lines] * 8];

    uint64_t node = (uint64_t)&base[perm[0] * 8];
    const double t0 = now_s();
    for (size_t i = 0; i < lines; i++) node = *(volatile uint64_t *)node;
    const double dt = now_s() - t0;

    const double per_read = dt / (double)lines;
    printf("memory: %zu MiB, %zu dependent random reads\n", mib, lines);
    printf("  %.1f ns per read  (a hash makes 16384 of them)\n", per_read * 1e9);
    printf("  ceiling for one thread if nothing overlaps: %.0f H/s\n", 1.0 / (16384.0 * per_read));

    free(perm);
    munmap(mem, bytes);

    return 0;
}

int main(int argc, char **argv) {
    const int rounds = argc > 1 ? atoi(argv[1]) : 200;
    const int algo = argc > 2 ? atoi(argv[2]) : XMO_RX_0;

    if (run(rounds, false, algo) != 0) return 1;
    putchar('\n');

    if (run(rounds, true, algo) != 0) return 1;
    putchar('\n');

    /* After the engine has been freed: the probe wants 2 GiB of its own. */
    return latency(2048);
}
