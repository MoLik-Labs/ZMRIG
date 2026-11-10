/* ZMRIG (by @nggkhaiz) - hash engine C API
 *
 * Exposes the RandomX implementation that ships in this repository
 * (src/crypto/randomx, the MoneroOcean fork with all coin configurations) to
 * the Zig miner through a plain C ABI. Nothing else from XMRig is linked: the
 * library contains the hash core, the XMRig memory allocator it needs and the
 * algorithm configuration table.
 *
 * Memory ownership: the caller (zmrig) never touches RandomX internals. One
 * engine owns the cache and the dataset; every mining thread owns one VM.
 *
 * Copyright (c) 2018-2026 XMRig, tevador, MoneroOcean and contributors.
 * GPL-3.0, see LICENSE.
 */
#ifndef XMO_RANDOMX_H
#define XMO_RANDOMX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xmo_engine xmo_engine;
typedef struct xmo_vm     xmo_vm;

/* RandomX algorithm ids, mirroring xmrig::Algorithm::Id. */
enum xmo_algo {
    XMO_RX_0     = 0,
    XMO_RX_2     = 1,
    XMO_RX_WOW   = 2,
    XMO_RX_ARQ   = 3,
    XMO_RX_GRAFT = 4,
    XMO_RX_SFX   = 5,
    XMO_RX_YADA  = 6,
    XMO_RX_XLA   = 7
};

/*
 * flags: bit 0 = huge pages for the dataset/cache, bit 1 = huge pages for the
 *        JIT code, bit 2 = full memory mode (dataset), bit 3 = JIT compiler.
 * The cache is always allocated, full memory mode additionally allocates the
 * 2 GiB dataset.
 */
xmo_engine *xmo_engine_new(int algo, int flags, char *err, size_t errlen);

/* Make `engine`'s algorithm the active RandomX configuration. Called with the
 * workers stopped; required after switching to an engine that was created
 * earlier, because the configuration is process-wide. */
void xmo_engine_activate(xmo_engine *engine);
void        xmo_engine_free(xmo_engine *engine);

/* Number of bytes the dataset and the cache need for this algorithm. */
size_t xmo_engine_dataset_size(const xmo_engine *engine);
size_t xmo_engine_cache_size(const xmo_engine *engine);

/*
 * Bytes an engine for `algo` will map, without creating one: the cache always,
 * the dataset too when full_memory is non-zero. The seven configurations in
 * this repository are not the same size — Monero, Wownero, ArqmA, Graft, Safex
 * and Yada need 2336 MiB, Panthera/Scala needs 160 — so anything that reserves
 * memory or huge pages has to ask per algorithm instead of assuming Monero's.
 */
size_t xmo_algo_memory(int algo, int full_memory);
size_t xmo_algo_dataset_memory(int algo);
size_t xmo_algo_cache_memory(int algo);

/* (Re)initialise cache + dataset for a new seed. threads >= 1. */
int  xmo_engine_seed(xmo_engine *engine, const uint8_t *seed, size_t seed_len,
                     int threads, char *err, size_t errlen);

/* Telemetry: bytes actually backed by explicit huge pages, bytes that asked for
 * them, and the total the engine mapped. When the kernel has no reserved pages
 * the first is 0 while the second is non-zero: that is a fallback, and the
 * miner reports it as one. */
size_t xmo_engine_huge_pages(const xmo_engine *engine);
size_t xmo_engine_huge_pages_total(const xmo_engine *engine);

/* The page size that backed the mapping: 0 for ordinary pages, 2048 for 2 MiB
 * pages, 1048576 for 1 GiB pages. A 1 GiB mapping reports "explicit" only when
 * the kernel really did hand pages out of the gigantic pool. */
size_t xmo_engine_huge_page_kb(const xmo_engine *engine);
size_t xmo_engine_total_memory(const xmo_engine *engine);

/* RandomX memory-latency fix. These return 0 on success, 1 when this machine
 * cannot do it (VM without MSR passthrough, missing module, not root) and 2
 * for a partial success; `report` always receives one human-readable line. */
int xmo_msr_apply(int save, char *report, size_t report_len);
int xmo_msr_restore(char *report, size_t report_len);
int xmo_msr_probe(char *report, size_t report_len);

xmo_vm *xmo_vm_new(xmo_engine *engine, int flags, uint32_t numa_node,
                   char *err, size_t errlen);
void    xmo_vm_free(xmo_vm *vm);

/* One-shot hash. out receives 32 bytes. */
void xmo_hash(xmo_vm *vm, const uint8_t *blob, size_t len, uint8_t *out);

/* Pipelined hashing, same order as XMRig's worker loop: the first call only
 * prepares the scratchpad, each following call hashes the *next* blob. */
void xmo_hash_first(xmo_vm *vm, const uint8_t *blob, size_t len, uint64_t *temp);
/* `temp` is both input and output: RandomX fills it with the state of `blob`
 * for the next call. It must stay valid and untouched between the two calls. */
void xmo_hash_next(xmo_vm *vm, uint64_t *temp, const uint8_t *blob,
                   size_t len, uint8_t *out);

/* Commitments are part of the Monero v2 proof of work. */
void xmo_commitment(const uint8_t *blob, size_t len, const uint8_t *hash_in,
                    uint8_t *out);

/* JIT / dataset tuning knobs (see crypto/randomx/randomx.h). */
void xmo_set_scratchpad_prefetch(int mode);
void xmo_set_huge_pages_jit(int enabled);
void xmo_set_optimized_dataset_init(int value);

const char *xmo_engine_name(void);

#ifdef __cplusplus
}
#endif

#endif /* XMO_RANDOMX_H */
