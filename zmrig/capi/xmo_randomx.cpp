/* ZMRIG (by @nggkhaiz) - hash engine C API implementation.
 *
 * Thin, allocation-aware wrapper around the RandomX build in this repository.
 * Everything performance relevant happens inside RandomX itself; this file only
 * decides where the cache/dataset/scratchpad memory lives (huge pages when the
 * kernel has them) and how many threads initialise the dataset.
 */

#include "xmo_randomx.h"

#include "backend/cpu/Cpu.h"
#include "base/crypto/Algorithm.h"
#include "crypto/common/Assembly.h"
#include "crypto/randomx/configuration.h"
#include "crypto/randomx/randomx.h"
#include "crypto/rx/RxAlgo.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#ifdef __linux__
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace {

constexpr size_t kHugePageSize = 2 * 1024 * 1024;
#ifndef _WIN32
/* x86-64's gigantic page, and the encoding that asks for it. MAP_HUGE_SHIFT is
 * 26 on Linux for every architecture that has MAP_HUGETLB; the size given to
 * mmap must be a multiple of 1 GiB or the call is EINVAL. Guarded because the
 * Windows build has neither mmap nor these names, and an unused constant there
 * is a warning at best. */
constexpr size_t kGiganticPageSize = 1024ULL * 1024 * 1024;
#ifndef MAP_HUGE_SHIFT
#define MAP_HUGE_SHIFT 26
#endif
constexpr int kGiganticShift = 30;
#endif
constexpr size_t kScratchpad   = RANDOMX_SCRATCHPAD_L3_MAX_SIZE;

/* One mapping. `mmap` returns zeroed pages for free, so the 2 GiB fallback no
 * longer memsets 2 GiB before the dataset initialiser overwrites it anyway. */
struct Mapping {
    uint8_t *ptr = nullptr;
    size_t   bytes = 0;
    bool     explicit_huge = false;
    bool     via_mmap = false;
    /* The page size that backed it: 2 MiB, 1 GiB, or 0 for ordinary pages.
     * Two mappings of the same byte count do not perform the same, so the
     * number is worth carrying to the log. */
    size_t   page_kb = 0;
};


/* Backed by reserved huge pages when the kernel has them, 1 GiB ones first.
 *
 * A 2 GiB RandomX dataset is 1 024 four-KiB TLB entries' worth of random reads
 * per hash, and 2 MiB pages turn that into 1 024 lookups spread over a TLB that
 * typically holds that many: a 1 GiB page turns it into two. But gigantic pages
 * cannot be reserved after the machine has been up for a while — the pool has to
 * exist before memory fragments — so this only *uses* them: when the operator
 * reserved a pool (`nr_hugepages` under `hugepages-1048576kB`) and it is big
 * enough, the mapping comes from it, and when it is not, the next attempt is the
 * 2 MiB pool, then anonymous memory with a THP hint, which is what a stock
 * XMRig build ends up with on a host without reserved pages. Every step down is
 * silent to the caller and visible in the page size this records. */
Mapping mapPages(size_t bytes, bool huge, size_t *mapped)
{
    const size_t aligned = (bytes + kHugePageSize - 1) & ~(kHugePageSize - 1);
    Mapping out;

#ifdef _WIN32
    (void) huge;
    void *p = nullptr;
    if (posix_memalign(&p, kHugePageSize, aligned) != 0) {
        return out;
    }
    std::memset(p, 0, aligned);
    out.ptr = static_cast<uint8_t *>(p);
    out.bytes = aligned;
    *mapped = aligned;

    return out;
#else
    if (huge && aligned >= kGiganticPageSize) {
        const size_t gigantic = (aligned + kGiganticPageSize - 1) & ~(kGiganticPageSize - 1);
        void *p = mmap(nullptr, gigantic, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | (kGiganticShift << MAP_HUGE_SHIFT), -1, 0);
        if (p != MAP_FAILED) {
            out.ptr = static_cast<uint8_t *>(p);
            out.bytes = gigantic;
            out.explicit_huge = true;
            out.via_mmap = true;
            out.page_kb = kGiganticPageSize / 1024;
            *mapped = gigantic;

            return out;
        }

        /* ENOMEM: no 1 GiB pool, or not enough pages left in it. Nothing to
         * report — the 2 MiB pool is the next thing tried. */
    }

    if (huge) {
        void *p = mmap(nullptr, aligned, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
        if (p != MAP_FAILED) {
            out.ptr = static_cast<uint8_t *>(p);
            out.bytes = aligned;
            out.explicit_huge = true;
            out.via_mmap = true;
            out.page_kb = kHugePageSize / 1024;
            *mapped = aligned;

            return out;
        }

        /* ENOMEM means the pages are not reserved; EINVAL means MAP_HUGETLB is
         * not available at all (some container runtimes). Either way the caller
         * needs to know that this is a fallback, not a huge page mapping. */
    }

    void *p = mmap(nullptr, aligned, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        return out;
    }

    /* The kernel hands out zero pages lazily: no memset, and nothing resident
     * until the cache/dataset initialisers write it. */
    if (huge) {
        madvise(p, aligned, MADV_HUGEPAGE);
    }

    out.ptr = static_cast<uint8_t *>(p);
    out.bytes = aligned;
    out.via_mmap = true;
    *mapped = aligned;

    return out;
#endif
}


/* Free with the allocator that produced the mapping.
 *
 * This used to call munmap() unconditionally, including for the posix_memalign
 * fallback. On the fallback path munmap fails with EINVAL and nothing is freed,
 * so a rig that switched algorithms a few times leaked 2336 MiB per switch and
 * eventually failed to allocate at all. */
void unmapPages(Mapping &mapping)
{
    if (!mapping.ptr) {
        return;
    }

#ifdef _WIN32
    free(mapping.ptr);
#else
    if (mapping.via_mmap) {
        munmap(mapping.ptr, mapping.bytes);
    } else {
        free(mapping.ptr);
    }
#endif

    mapping.ptr = nullptr;
}


void setError(char *err, size_t errlen, const char *message)
{
    if (!err || errlen == 0) {
        return;
    }

    std::snprintf(err, errlen, "%s", message);
}


xmrig::Algorithm toAlgorithm(int algo)
{
    switch (algo) {
    case XMO_RX_2:     return xmrig::Algorithm(xmrig::Algorithm::RX_V2);
    case XMO_RX_WOW:   return xmrig::Algorithm(xmrig::Algorithm::RX_WOW);
    case XMO_RX_ARQ:   return xmrig::Algorithm(xmrig::Algorithm::RX_ARQ);
    case XMO_RX_GRAFT: return xmrig::Algorithm(xmrig::Algorithm::RX_GRAFT);
    case XMO_RX_SFX:   return xmrig::Algorithm(xmrig::Algorithm::RX_SFX);
    case XMO_RX_YADA:  return xmrig::Algorithm(xmrig::Algorithm::RX_YADA);
    case XMO_RX_XLA:   return xmrig::Algorithm(xmrig::Algorithm::RX_XLA);
    default:           return xmrig::Algorithm(xmrig::Algorithm::RX_0);
    }
}

} // namespace


struct xmo_engine {
    xmrig::Algorithm algorithm;
    int   algo_id       = XMO_RX_0;
    bool  huge          = false;
    /* Bytes that really came from MAP_HUGETLB, and bytes that asked for it.
     * Reporting the requested size as if it had been granted is how a miner
     * ends up claiming "huge pages 2336 MB" while running on 4 KiB pages. */
    size_t huge_explicit = 0;
    size_t huge_requested = 0;
    /* 0 when the mapping is on ordinary pages, else 2048 or 1048576. */
    size_t huge_page_kb = 0;
    bool  full_mem      = true;
    bool  jit           = true;
    /* `randomx_set_huge_pages_jit` is a process-wide switch, so an engine that
     * is activated later has to be able to restore its own value. */
    bool  huge_pages_jit = true;
    /* The mapping and the size the algorithm really needs. They differ per
     * coin: Monero's cache is 256 MiB, Panthera's is 128. */
    Mapping cache{};
    Mapping data{};
    size_t  cache_bytes = 0;
    size_t  data_bytes  = 0;
    randomx_cache   *cache_handle = nullptr;
    randomx_dataset *dataset      = nullptr;
};


struct xmo_vm {
    randomx_vm *vm         = nullptr;
    xmrig::Algorithm algorithm;
    Mapping   scratch{};
    size_t    scratch_bytes = 0;
};


/* Which RandomX configuration is active is process-wide state
 * (`RandomX_CurrentConfig`), not per-engine: cache initialisation, the JIT
 * program and even `randomx_calculate_hash_next` (it reads ProgramCount) all
 * take it from there. One process used to have exactly one engine, so
 * `xmo_engine_new` applying it once was enough. Now that a miner can keep the
 * previous algorithm's dataset mapped and switch back to it, "the last engine
 * that was created" and "the engine that is hashing" can be different
 * configurations - and hashing Monero's dataset under Panthera's parameters
 * produces wrong hashes rather than slow ones.
 *
 * So every transition that changes which engine is live calls this, with the
 * workers stopped. It is a constant-size copy of a configuration, not a
 * dataset build. */
void xmo_engine_activate(xmo_engine *engine)
{
    if (!engine) {
        return;
    }

    xmrig::RxAlgo::apply(engine->algorithm.id());
    randomx_set_optimized_dataset_init(engine->algo_id == XMO_RX_XLA ? 0 : -1);
    randomx_set_huge_pages_jit(engine->huge_pages_jit ? 1 : 0);
}


xmo_engine *xmo_engine_new(int algo, int flags, char *err, size_t errlen)
{
    auto *engine = new xmo_engine();

    engine->algo_id  = algo;
    engine->algorithm = toAlgorithm(algo);
    engine->huge     = (flags & 1) != 0;
    engine->full_mem = (flags & 4) != 0;
    engine->jit      = (flags & 8) != 0;

    // Select the per-coin RandomX configuration before touching any sizes.
    engine->huge_pages_jit = (flags & 2) != 0;
    xmo_engine_activate(engine);

    const int cache_flags = engine->jit ? RANDOMX_FLAG_JIT : RANDOMX_FLAG_DEFAULT;

    /* Size the cache from the algorithm's own configuration, not from the
     * largest one in the tree. Panthera needs half of Monero's cache and a
     * 64 MiB dataset instead of 2080, which is the difference between "needs
     * 2.3 GiB of RAM" and "runs on a 512 MiB VPS". */
    engine->cache_bytes = xmo_algo_cache_memory(algo);
    engine->cache = mapPages(engine->cache_bytes, engine->huge, &engine->cache_bytes);
    if (!engine->cache.ptr) {
        setError(err, errlen, "cannot allocate the RandomX cache");
        delete engine;

        return nullptr;
    }
    if (engine->huge) {
        engine->huge_requested += engine->cache.bytes;
        if (engine->cache.explicit_huge) {
            engine->huge_explicit += engine->cache.bytes;
            engine->huge_page_kb = engine->cache.page_kb;
        }
    }

    engine->cache_handle = randomx_create_cache(static_cast<randomx_flags>(cache_flags), engine->cache.ptr);
    if (!engine->cache_handle) {
        engine->cache_handle = randomx_create_cache(RANDOMX_FLAG_DEFAULT, engine->cache.ptr);
    }

    if (!engine->cache_handle) {
        setError(err, errlen, "randomx_create_cache failed");
        unmapPages(engine->cache);
        delete engine;

        return nullptr;
    }

    if (engine->full_mem) {
        engine->data_bytes = xmo_algo_dataset_memory(algo);
        engine->data = mapPages(engine->data_bytes, engine->huge, &engine->data_bytes);
        if (!engine->data.ptr) {
            setError(err, errlen, "cannot allocate the RandomX dataset");
            randomx_release_cache(engine->cache_handle);
            unmapPages(engine->cache);
            delete engine;

            return nullptr;
        }
        if (engine->huge) {
            engine->huge_requested += engine->data.bytes;
            if (engine->data.explicit_huge) {
                engine->huge_explicit += engine->data.bytes;
                engine->huge_page_kb = engine->data.page_kb;
            }
        }

        engine->dataset = randomx_create_dataset(engine->data.ptr);
        if (!engine->dataset) {
            setError(err, errlen, "randomx_create_dataset failed");
            randomx_release_cache(engine->cache_handle);
            unmapPages(engine->data);
            unmapPages(engine->cache);
            delete engine;

            return nullptr;
        }
    }

    return engine;
}


void xmo_engine_free(xmo_engine *engine)
{
    if (!engine) {
        return;
    }

    if (engine->dataset) {
        randomx_release_dataset(engine->dataset);
    }
    if (engine->cache_handle) {
        randomx_release_cache(engine->cache_handle);
    }

    unmapPages(engine->data);
    unmapPages(engine->cache);

    delete engine;
}


size_t xmo_engine_dataset_size(const xmo_engine *engine) { return engine ? engine->data_bytes : 0; }
size_t xmo_engine_cache_size(const xmo_engine *engine)   { return engine ? engine->cache_bytes : 0; }


/* Pure queries: they read the configuration table without touching the global
 * RandomX state, so `--check`, the huge-page reservation and the JSON report can
 * all ask "how much memory does Scala need" without side effects. */
size_t xmo_algo_cache_memory(int algo)
{
    /* One Argon2 block is 1 KiB, so the cache is exactly ArgonMemory KiB. */
    return static_cast<size_t>(xmrig::RxAlgo::base(toAlgorithm(algo).id())->ArgonMemory) * 1024;
}


size_t xmo_algo_dataset_memory(int algo)
{
    const auto *config = xmrig::RxAlgo::base(toAlgorithm(algo).id());

    return static_cast<size_t>(config->DatasetBaseSize) + RandomX_ConfigurationBase::DatasetExtraSize;
}


size_t xmo_algo_memory(int algo, int full_memory)
{
    return xmo_algo_cache_memory(algo) + (full_memory ? xmo_algo_dataset_memory(algo) : 0);
}


size_t xmo_engine_huge_pages(const xmo_engine *engine)
{
    return engine ? engine->huge_explicit : 0;
}


size_t xmo_engine_huge_pages_total(const xmo_engine *engine)
{
    return engine ? engine->huge_requested : 0;
}


size_t xmo_engine_huge_page_kb(const xmo_engine *engine)
{
    return engine ? engine->huge_page_kb : 0;
}


size_t xmo_engine_total_memory(const xmo_engine *engine)
{
    if (!engine) {
        return 0;
    }

    return engine->cache_bytes + engine->data_bytes;
}


int xmo_engine_seed(xmo_engine *engine, const uint8_t *seed, size_t seed_len,
                    int threads, char *err, size_t errlen)
{
    if (!engine || !seed || seed_len == 0) {
        setError(err, errlen, "invalid seed");

        return -1;
    }

    /* The dataset size, the cache parameters and the AES keys all come from
     * the active configuration, so this cannot be left to whichever engine was
     * created last. */
    xmo_engine_activate(engine);

    randomx_init_cache(engine->cache_handle, seed, seed_len);

    if (!engine->dataset) {
        return 0;
    }

    if (threads < 1) {
        threads = 1;
    }

    const unsigned long total = randomx_dataset_item_count();
    const unsigned long per   = total / static_cast<unsigned long>(threads);

    if (threads == 1) {
        randomx_init_dataset(engine->dataset, engine->cache_handle, 0, total);

        return 0;
    }

    std::vector<std::thread> workers;
    workers.reserve(static_cast<size_t>(threads));

    for (int i = 0; i < threads; ++i) {
        const unsigned long start = per * static_cast<unsigned long>(i);
        const unsigned long count = (i == threads - 1) ? (total - start) : per;

        workers.emplace_back([engine, start, count]() {
            randomx_init_dataset(engine->dataset, engine->cache_handle, start, count);
        });
    }

    for (auto &worker : workers) {
        worker.join();
    }

    return 0;
}


xmo_vm *xmo_vm_new(xmo_engine *engine, int flags, uint32_t numa_node,
                   char *err, size_t errlen)
{
    if (!engine) {
        setError(err, errlen, "no engine");

        return nullptr;
    }

    /* `randomx_create_vm` compiles the JIT program against the active
     * configuration, so a VM for the engine that is about to hash has to be
     * created under that engine's parameters - not under those of whichever
     * engine was built most recently. */
    xmo_engine_activate(engine);

    auto *result = new xmo_vm();
    result->algorithm = engine->algorithm;

    const bool huge = (flags & 1) != 0;
    result->scratch = mapPages(kScratchpad, huge, &result->scratch_bytes);
    if (!result->scratch.ptr) {
        setError(err, errlen, "cannot allocate the scratchpad");
        delete result;

        return nullptr;
    }

    int vm_flags = RANDOMX_FLAG_HARD_AES;
    /* The JIT emits a different, cheaper CFROUND sequence on AMD because of how
     * the family handles precision-control register writes. Upstream XMRig picks
     * this from the CPU it detected; without it an AMD host runs the Intel
     * sequence, which costs a little on every CFROUND instruction — and this
     * codebase is all about a little. The hashes are identical either way. */
    switch (xmrig::Cpu::info()->assembly()) {
        case xmrig::Assembly::RYZEN:
        case xmrig::Assembly::BULLDOZER:
            vm_flags |= RANDOMX_FLAG_AMD;
            break;
        default:
            break;
    }
    if (engine->full_mem) {
        vm_flags |= RANDOMX_FLAG_FULL_MEM;
    }
    if (engine->jit) {
        vm_flags |= RANDOMX_FLAG_JIT;
    }

    result->vm = randomx_create_vm(static_cast<randomx_flags>(vm_flags),
                                   engine->cache_handle, engine->dataset,
                                   result->scratch.ptr, numa_node);
    if (!result->vm) {
        setError(err, errlen, "randomx_create_vm failed");
        unmapPages(result->scratch);
        delete result;

        return nullptr;
    }

    return result;
}


void xmo_vm_free(xmo_vm *vm)
{
    if (!vm) {
        return;
    }

    if (vm->vm) {
        randomx_destroy_vm(vm->vm);
    }

    unmapPages(vm->scratch);
    delete vm;
}


void xmo_hash(xmo_vm *vm, const uint8_t *blob, size_t len, uint8_t *out)
{
    randomx_calculate_hash(vm->vm, blob, len, out, vm->algorithm);
}


/* The pipeline state is fed to AES intrinsics with aligned 16-byte loads, so it
 * must live in aligned memory. Callers that cannot guarantee 64 bytes get a
 * bounce buffer instead of a general protection fault. */
static inline bool isAligned64(const void *p)
{
    return (reinterpret_cast<uintptr_t>(p) & 63) == 0;
}


void xmo_hash_first(xmo_vm *vm, const uint8_t *blob, size_t len, uint64_t *temp)
{
    if (isAligned64(temp)) {
        randomx_calculate_hash_first(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(temp), blob, len, vm->algorithm);

        return;
    }

    uint64_t local[8] __attribute__((aligned(64))) = {};
    randomx_calculate_hash_first(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(local), blob, len, vm->algorithm);
    std::memcpy(temp, local, sizeof(local));
}


void xmo_hash_next(xmo_vm *vm, uint64_t *temp, const uint8_t *blob, size_t len, uint8_t *out)
{
    if (isAligned64(temp)) {
        randomx_calculate_hash_next(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(temp), blob, len, out, vm->algorithm);

        return;
    }

    // RandomX wants a 64-byte aligned staging block, so hash through a local
    // copy - and copy the *updated* state back, otherwise the next call would
    // start from the previous blob and every hash after the first one would be
    // wrong. (That is not theoretical: it produced one bad share in ~300
    // before it was found.)
    uint64_t local[8] __attribute__((aligned(64)));
    std::memcpy(local, temp, sizeof(local));
    randomx_calculate_hash_next(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(local), blob, len, out, vm->algorithm);
    std::memcpy(temp, local, sizeof(local));
}


void xmo_commitment(const uint8_t *blob, size_t len, const uint8_t *hash_in, uint8_t *out)
{
    randomx_calculate_commitment(blob, len, hash_in, out);
}


void xmo_set_scratchpad_prefetch(int mode)        { randomx_set_scratchpad_prefetch_mode(mode); }
void xmo_set_huge_pages_jit(int enabled)          { randomx_set_huge_pages_jit(enabled != 0); }
void xmo_set_optimized_dataset_init(int value)    { randomx_set_optimized_dataset_init(value); }


const char *xmo_engine_name(void)
{
    return "RandomX (ZMRIG)";
}
