/* Validates the hash engine C API against the vectors this repository already
 * trusts (see tests/hash/main.cpp). Build with zmrig/tests/run.sh. */
#include "../capi/xmo_randomx.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static int failures = 0;

static void check(const char *name, const uint8_t *got, const uint8_t *want)
{
    if (std::memcmp(got, want, 32) == 0) {
        std::printf("PASS %s\n", name);
        return;
    }

    std::printf("FAIL %s\n  got  ", name);
    for (int i = 0; i < 32; ++i) std::printf("%02x", got[i]);
    std::printf("\n  want ");
    for (int i = 0; i < 32; ++i) std::printf("%02x", want[i]);
    std::printf("\n");
    ++failures;
}

struct AlgoVector {
    int         algo;
    const char *name;
    const char *hex;
};

/* One known answer per RandomX configuration, copied from tests/hash/main.cpp.
 * rx/2 is missing on purpose: no coin uses it, and upstream v6.26 disagrees with
 * itself about it - the interpreter ignores its AES tweak while the JIT applies
 * it, and tests/hash/main.cpp skips the same comparison for the same reason. */
static const AlgoVector algoVectors[] = {
    { XMO_RX_0,     "rx/0",     "1833ff322e60dad7d6885bcd5e0844ec8e4808a47d8d354806668f0c241a6af5" },
    { XMO_RX_WOW,   "rx/wow",   "45896210539d9ba37377b9c186b7343304cd6bf797c75f3d1087ee63f22a73e4" },
    { XMO_RX_ARQ,   "rx/arq",   "ca2b7afe5c50ab45296c5457337ff7cf27624139f05ec5d44c1e4ae8bfe95bb6" },
    { XMO_RX_GRAFT, "rx/graft", "c4a9cfd2f0a9359c78f089902b44b42623fbf18a1a01786879bfed3f0be255f7" },
    { XMO_RX_SFX,   "rx/sfx",   "3b88936e289ff3240dc074b289fe6464194bdfe31a80c9dc10c9c1eaa1975513" },
    { XMO_RX_YADA,  "rx/yada",  "04d68fb9c445f4437dfce6ebb8028367b060140066ebaa416a4cd2ca63cdb723" },
    { XMO_RX_XLA,   "panthera", "1805aa4fd26f5686dada26d9e16ccb290811b2a79404fdd1064f1ca092902212" },
};

/* What a full-memory run of `algo` can actually map: MemAvailable plus the huge
 * pages that are reserved but not handed out. The kernel does not count those as
 * available for ordinary allocations, and the dataset can be allocated from
 * exactly those pages, so both have to be in the sum. */
static double usableMb()
{
    double kb = 0;
    double free_pages = 0;
    double page_kb = 2048;

    if (FILE *f = std::fopen("/proc/meminfo", "r")) {
        char line[256];

        while (std::fgets(line, sizeof(line), f)) {
            if (std::strncmp(line, "MemAvailable:", 13) == 0) std::sscanf(line + 13, "%lf", &kb);
            else if (std::strncmp(line, "HugePages_Free:", 15) == 0) std::sscanf(line + 15, "%lf", &free_pages);
            else if (std::strncmp(line, "Hugepagesize:", 13) == 0) std::sscanf(line + 13, "%lf", &page_kb);
        }

        std::fclose(f);
    }

    return kb / 1024.0 + free_pages * page_kb / 1024.0;
}

static void unhex(const char *hex, uint8_t *out)
{
    for (int i = 0; i < 32; ++i) {
        unsigned v = 0;
        std::sscanf(hex + i * 2, "%2x", &v);
        out[i] = static_cast<uint8_t>(v);
    }
}

int main()
{
    char err[256] = {};

    const std::string seed  = "xmrig-mo-check-hashes seed";
    const std::string inA   = "xmrig-mo-check-hashes input A";
    const std::string inB   = "xmrig-mo-check-hashes input B";
    const std::string inC   = "xmrig-mo-check-hashes input C";

    uint8_t wantA[32];
    unhex("1833ff322e60dad7d6885bcd5e0844ec8e4808a47d8d354806668f0c241a6af5", wantA);

    std::printf("engine: %s\n", xmo_engine_name());

    /* --- the engine sizes itself per algorithm ----------------------------
     * Every RandomX fork in this repository has its own configuration, and the
     * sizes are not interchangeable: Monero needs 2336 MiB of cache+dataset,
     * Panthera/Scala 192. A miner that assumes Monero's number sends a 1 GiB
     * VPS to light mode on a coin it could mine in fast mode with huge pages.
     *
     * These are pure queries — no engine is created, nothing is allocated. */
    {
        const size_t monero_cache = xmo_algo_cache_memory(XMO_RX_0);
        const size_t monero_data  = xmo_algo_dataset_memory(XMO_RX_0);
        const size_t scala_cache  = xmo_algo_cache_memory(XMO_RX_XLA);
        const size_t scala_data   = xmo_algo_dataset_memory(XMO_RX_XLA);

        std::printf("rx/0: cache %zu MB, dataset %zu MB; panthera: cache %zu MB, dataset %zu MB\n",
                    monero_cache >> 20, monero_data >> 20, scala_cache >> 20, scala_data >> 20);

        struct Expect { const char *name; bool ok; };
        const Expect checks[] = {
            { "Monero cache is 256 MiB",              monero_cache == 268435456 },
            { "Monero dataset is 2 GiB + the extra items", monero_data == 2147483648UL + 33554368UL },
            { "Panthera cache is 128 MiB",            scala_cache == 134217728 },
            { "Panthera dataset is 32 MiB base + extras", scala_data == 33554432UL + 33554368UL },
            { "Panthera is smaller than Monero",      scala_cache + scala_data < monero_cache + monero_data },
            { "light mode maps the cache only",       xmo_algo_memory(XMO_RX_0, 0) == monero_cache },
            { "full mode maps cache and dataset",     xmo_algo_memory(XMO_RX_0, 1) == monero_cache + monero_data },
            /* The other five forks share Monero's dataset size, which is why a
             * reservation made for rx/0 covers them after a pool switch. */
            { "rx/wow has Monero's dataset size",     xmo_algo_dataset_memory(XMO_RX_WOW) == monero_data },
            { "rx/arq has Monero's dataset size",     xmo_algo_dataset_memory(XMO_RX_ARQ) == monero_data },
            { "rx/graft has Monero's dataset size",   xmo_algo_dataset_memory(XMO_RX_GRAFT) == monero_data },
            { "rx/sfx has Monero's dataset size",     xmo_algo_dataset_memory(XMO_RX_SFX) == monero_data },
            { "rx/yada has Monero's dataset size",    xmo_algo_dataset_memory(XMO_RX_YADA) == monero_data },
        };

        for (const auto &c : checks) {
            std::printf(c.ok ? "PASS %s\n" : "FAIL %s\n", c.name);
            if (!c.ok) ++failures;
        }
    }

    /* --- light mode (cache only), the fastest way to validate the API --- */
    xmo_engine *light = xmo_engine_new(XMO_RX_0, /*jit*/ 8, err, sizeof(err));
    if (!light) {
        std::printf("FAIL engine_new: %s\n", err);
        return 1;
    }

    if (xmo_engine_seed(light, reinterpret_cast<const uint8_t *>(seed.data()), seed.size(), 1, err, sizeof(err)) != 0) {
        std::printf("FAIL seed: %s\n", err);
        return 1;
    }

    xmo_vm *vm = xmo_vm_new(light, 0, 0, err, sizeof(err));
    if (!vm) {
        std::printf("FAIL vm_new: %s\n", err);
        return 1;
    }

    uint8_t outA[32] = {}, outB[32] = {};
    xmo_hash(vm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), outA);
    check("rx/0 light hash A", outA, wantA);

    /* Same hash into a deliberately misaligned destination. */
    {
        uint8_t raw[33] = {};
        xmo_hash(vm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), raw + 1);
        check("rx/0 light hash A (unaligned out)", raw + 1, wantA);
    }

    xmo_hash(vm, reinterpret_cast<const uint8_t *>(inB.data()), inB.size(), outB);

    /* RandomX pipelining: first() prepares blob A, and each next() returns the
     * hash of the previous blob (same contract as tests/hash/main.cpp). */
    uint64_t temp[8] = {};
    uint8_t nextA[32] = {}, nextB[32] = {};
    xmo_hash_first(vm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), temp);
    xmo_hash_next(vm, temp, reinterpret_cast<const uint8_t *>(inB.data()), inB.size(), nextA);
    xmo_hash_next(vm, temp, reinterpret_cast<const uint8_t *>(inC.data()), inC.size(), nextB);
    check("rx/0 light first/next A", nextA, outA);
    check("rx/0 light first/next B", nextB, outB);

    /* Regression: the pipelined state has to survive an *unaligned* staging
     * buffer. The wrapper has a slow path for that, and it used to forget to
     * copy the new state back, which silently corrupted every hash after the
     * first one. Chain four hashes through both paths. */
    {
        const std::string inputs[5] = { inA, inB, inC, inA, inB };
        uint8_t oneshot[5][32] = {};
        for (int i = 0; i < 5; ++i) {
            xmo_hash(vm, reinterpret_cast<const uint8_t *>(inputs[i].data()), inputs[i].size(), oneshot[i]);
        }

        uint8_t raw[8 * sizeof(uint64_t) + 1] = {};           /* deliberately misaligned +1 */
        uint64_t *misaligned = reinterpret_cast<uint64_t *>(raw + 1);

        xmo_hash_first(vm, reinterpret_cast<const uint8_t *>(inputs[0].data()), inputs[0].size(), misaligned);
        for (int i = 1; i < 5; ++i) {
            uint8_t got[32] = {};
            xmo_hash_next(vm, misaligned, reinterpret_cast<const uint8_t *>(inputs[i].data()), inputs[i].size(), got);
            char name[64];
            std::snprintf(name, sizeof(name), "pipelined unaligned #%d", i);
            check(name, got, oneshot[i - 1]);
        }
    }

    xmo_vm_free(vm);
    xmo_engine_free(light);

    /* --- every supported coin hashes its own reference vector ---------------
     * One vector per configuration, copied from tests/hash/main.cpp. Before
     * this, the suite only hashed rx/0 in light mode, which is how Panthera's
     * light-mode JIT read 2 GiB into a 128 MiB cache and segfaulted for months
     * without anybody noticing.
     *
     * rx/2 is missing on purpose: no coin uses it, and upstream v6.26 disagrees
     * with itself about it - the interpreter ignores its AES tweak while the JIT
     * applies it (tests/hash/main.cpp skips the JIT comparison for the same
     * reason). There is nothing to compare against, so we do not pretend. */
    {
        for (const auto &variant : algoVectors) {
            char name[64];

            xmo_engine *e = xmo_engine_new(variant.algo, /*jit*/ 8, err, sizeof(err));
            if (!e) {
                std::printf("FAIL %s engine: %s\n", variant.name, err);
                ++failures;

                continue;
            }

            if (xmo_engine_seed(e, reinterpret_cast<const uint8_t *>(seed.data()), seed.size(), 1, err, sizeof(err)) != 0) {
                std::printf("FAIL %s seed: %s\n", variant.name, err);
                ++failures;
                xmo_engine_free(e);

                continue;
            }

            xmo_vm *v = xmo_vm_new(e, 0, 0, err, sizeof(err));
            if (!v) {
                std::printf("FAIL %s vm: %s\n", variant.name, err);
                ++failures;
                xmo_engine_free(e);

                continue;
            }

            uint8_t want[32];
            uint8_t got[32] = {};
            unhex(variant.hex, want);
            xmo_hash(v, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), got);

            std::snprintf(name, sizeof(name), "%s light hash", variant.name);
            check(name, got, want);

            xmo_vm_free(v);
            xmo_engine_free(e);
        }
    }

    /*
     * The 512-bit scratchpad pass. The engine selects it on Zen 5 only, so on
     * any other CPU the honest report is "not run" - but where the instructions
     * exist it has to hash the same bytes as the ordinary path, and it has to do
     * it with a `fill_state` that is not 64-byte aligned (a stack `uint64_t[8]`
     * is not, and a vmovdqa64 against one is a crash, not a wrong answer).
     */
    {
        char report[256] = {};
        const int verdict = xmo_wide_scratchpad_agrees(report, sizeof(report));

        if (verdict == 0) {
            std::printf("SKIP wide scratchpad pass: this CPU has no AVX-512 + VAES (the engine only uses it on Zen 5)\n");
        }
        else if (verdict > 0) {
            std::printf("PASS wide scratchpad pass: %s\n", report);
        }
        else {
            std::printf("FAIL wide scratchpad pass: %s\n", report);
            ++failures;
        }
    }

    /* --- full memory mode equals light mode, and the dataset is 2 GiB ---
     * Needs 2.25 GiB, so it only runs when the machine has reserved huge pages
     * (or plenty of RAM); otherwise we would OOM the box, not test the code. */
    /* Monero's cache plus dataset is 2336 MiB; 2500 leaves room for the
     * scratchpads, the binary and the page cache. */
    const double usable_mb = usableMb();

    if (std::getenv("ZMRIG_TEST_QUICK")) {
        std::printf("SKIP full-memory test (ZMRIG_TEST_QUICK)\n");
        std::printf(failures == 0 ? "\nall API checks passed\n" : "\n%d FAILURES\n", failures);

        return failures == 0 ? 0 : 1;
    }

    if (usable_mb < 2500) {
        std::printf("SKIP full-memory test (%.0f MB usable, 2500 MB needed; reserve huge pages or free RAM)\n", usable_mb);
        std::printf(failures == 0 ? "\nall API checks passed\n" : "\n%d FAILURES\n", failures);

        return failures == 0 ? 0 : 1;
    }

    xmo_engine *full = xmo_engine_new(XMO_RX_0, /*huge|jit|full*/ 13, err, sizeof(err));
    if (!full) {
        std::printf("FAIL engine_new full: %s\n", err);
        return 1;
    }

    std::printf("dataset bytes: %zu (items %lu)\n", xmo_engine_dataset_size(full),
                static_cast<unsigned long>(xmo_engine_dataset_size(full) / 2048));

    /* 2 GiB base dataset + 32 MiB extra used by the alternate coin configs */
    if (xmo_engine_dataset_size(full) != 2181038080ULL) {
        std::printf("FAIL dataset size\n");
        ++failures;
    }

    if (xmo_engine_seed(full, reinterpret_cast<const uint8_t *>(seed.data()), seed.size(), 2, err, sizeof(err)) != 0) {
        std::printf("FAIL seed full: %s\n", err);
        return 1;
    }

    xmo_vm *fvm = xmo_vm_new(full, 0, 0, err, sizeof(err));
    if (!fvm) {
        std::printf("FAIL vm_new full: %s\n", err);
        return 1;
    }

    uint8_t fA[32] = {};
    xmo_hash(fvm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), fA);
    check("rx/0 full-mem hash A", fA, wantA);

    /* commitments are used by Monero's v2 proof of work */
    uint8_t com[32] = {};
    xmo_commitment(reinterpret_cast<const uint8_t *>(inC.data()), inC.size(), fA, com);
    std::printf("commitment A: ");
    for (int i = 0; i < 32; ++i) std::printf("%02x", com[i]);
    std::printf("\n");

    xmo_vm_free(fvm);
    xmo_engine_free(full);

    /* --- full memory has to agree with light mode for every coin -----------
     * Light mode derives the dataset line by line from the cache; fast mode
     * reads it from a 2 GiB table built once. If those two ever disagree, the
     * miner hashes one thing and the pool expects another, and the only
     * symptom is rejected shares. Until now nothing exercised the dataset
     * path for anything but rx/0. */
    for (const auto &variant : algoVectors) {
        if (variant.algo == XMO_RX_0) continue;   /* tested above, with commitments */

        char name[64];
        xmo_engine *e = xmo_engine_new(variant.algo, /*huge|jit|full*/ 13, err, sizeof(err));
        if (!e) {
            std::printf("FAIL %s full engine: %s\n", variant.name, err);
            ++failures;

            continue;
        }

        if (xmo_engine_seed(e, reinterpret_cast<const uint8_t *>(seed.data()), seed.size(), 2, err, sizeof(err)) != 0) {
            std::printf("FAIL %s full seed: %s\n", variant.name, err);
            ++failures;
            xmo_engine_free(e);

            continue;
        }

        xmo_vm *v = xmo_vm_new(e, 0, 0, err, sizeof(err));
        if (!v) {
            std::printf("FAIL %s full vm: %s\n", variant.name, err);
            ++failures;
            xmo_engine_free(e);

            continue;
        }

        uint8_t want[32];
        uint8_t got[32] = {};
        unhex(variant.hex, want);
        xmo_hash(v, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), got);

        std::snprintf(name, sizeof(name), "%s full-mem hash equals light mode", variant.name);
        check(name, got, want);

        xmo_vm_free(v);
        xmo_engine_free(e);
    }

    std::printf(failures == 0 ? "\nall API checks passed\n" : "\n%d FAILURES\n", failures);

    return failures == 0 ? 0 : 1;
}
