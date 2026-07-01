#include "RecordCache.hpp"
#include "Units.hpp"
#include "../../Config.hpp"
#include <thread>
#include <chrono>
#include <cstring>

#include "leanstore/concurrency-recovery/Worker.hpp"
#include "leanstore/concurrency-recovery/CRMG.hpp"

namespace leanstore {
namespace storage {
namespace recordcache {

namespace {
struct UpdatableLookupResult {
    RecordCacheEntry* target{nullptr};
    bool skipped_placeholder{false};
    bool found_readonly_next{false};
};

inline UpdatableLookupResult FindFirstUpdatableEntry(RecordCacheEntry* head) {
    // Strict rule:
    // 1) Only return ReadOnlyMode entries as updatable targets
    // 2) At most check two layers (head and head->next)
    // 3) When encountering PromoteThreadHoldingThePosition, set dirty flag and skip
    // This avoids invalidating in-flight promote entries.
    if (head == nullptr) {
        return {};
    }

    auto t0 = head->entry_type.load(std::memory_order_acquire);
    if (t0 == RecordCacheType::ReadOnlyMode) {
        return {head, false, false};
    }

    // Head is not ReadOnly — check if it's a placeholder
    if (t0 == RecordCacheType::PromoteThreadHoldingThePosition) {
        // Set dirty flag so PromoteThread Phase 3 can detect the concurrent update
        head->update_during_promote.store(true, std::memory_order_release);

        RecordCacheEntry* second = head->next;
        if (second != nullptr) {
            auto t1 = second->entry_type.load(std::memory_order_acquire);
            if (t1 == RecordCacheType::ReadOnlyMode) {
                // Found a ReadOnly entry at next position — can invalidate it
                return {second, true, true};
            }
        }
        // No updatable ReadOnly entry found
        return {nullptr, true, false};
    }

    // Head is in some other state (e.g. LogicallyDeleted) — check next
    RecordCacheEntry* second = head->next;
    if (second != nullptr) {
        auto t1 = second->entry_type.load(std::memory_order_acquire);
        if (t1 == RecordCacheType::ReadOnlyMode) {
            return {second, false, true};
        }
    }

    return {nullptr, false, false};
}
} // namespace

void RecordCache::startBackgroundThreads()
{
    if (FLAGS_cxl_tiering_enabled) {
        // [B-mover v5] Wire allocator → RecordCache rescue. Must happen before
        // any promote/eviction thread spins up, because PromoteThread may call
        // allocator.allocate (which now expects the callback to be live).
        allocator.setSlabRescueCallback([this]() {
            return tryRescueSlabForAllocator();
        });

        if (FLAGS_forward_epoch_thread) {
            for (u64 t_i = 0; t_i < FLAGS_forward_epoch_thread; t_i++) {
                record_cache_background_threads.emplace_back([this]() {
                    forwardEpochThread();
                });
                bg_threads_counter.fetch_add(1, std::memory_order_relaxed);
            }
        }
        if(FLAGS_sieve_eviction_thread){
            for(u64 t_i = 0; t_i < FLAGS_sieve_eviction_thread; t_i++){
                record_cache_background_threads.emplace_back([this](){
                    sieveEvictionThread();
                });
                bg_threads_counter.fetch_add(1, std::memory_order_relaxed);
            }
        }
        if(FLAGS_record_cache_promote_thread){
            for (u64 t_i = 0; t_i < FLAGS_record_cache_promote_thread; t_i++) {
                record_cache_background_threads.emplace_back([this]() {
                    promoteThread();
                });
                bg_threads_counter.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
}

void RecordCache::stopBackgroundThreads()
{
    bg_threads_keep_running.store(false, std::memory_order_release);

    promote_request_cv.notify_all();        // Wakeup all promoteThread waiting on condition_variable.
    
    // Join all forward_epoch threads to ensure they fully exit before destruction
    for (auto& thread : record_cache_background_threads) {
        if (thread.joinable()) {
            thread.join();
        }
    }
    record_cache_background_threads.clear();
}

//===================================[Added].==========================================================
//                      Lookup Interceptor: tryLookupInRecordCache
//======================================================================================================
bool RecordCache::tryLookupInRecordCache(u16 dt_id, std::span<const u8> key, 
        const std::function<void(const u8*, u16)>& payload_callback, u64 worker_id)
{
    // 1. Worker thread enterEpoch, {active, current_epoch}
    enterEpoch(worker_id);

    // 2. Build (dt_id || key) on the stack for multi-table key namespacing.
    u8 prefixed_buf[128];
    assert(2 + key.size() <= sizeof(prefixed_buf));
    std::span<const u8> prefixed_key = BuildPrefixedKey(dt_id, key, prefixed_buf);

    const u64 hash_value = HashBytes(prefixed_key);
    const auto& target_shard = getShardByHash(hash_value);
    std::string key_str(reinterpret_cast<const char*>(prefixed_key.data()), prefixed_key.size());

    {
        std::shared_lock lock(target_shard.mutex);
        auto it = target_shard.hash_map_shard.find(key_str);
        if (it != target_shard.hash_map_shard.end()) {
            RecordCacheEntry* entry = it->second;
            while (entry != nullptr) {
                RecordCacheType current_type = entry->entry_type.load(std::memory_order_acquire);
                if (current_type == RecordCacheType::ReadOnlyMode) {
                    const u16 entry_last_modified_worker_id = entry->last_modified_worker_id;
                    const u64 entry_tx_ts = entry->tx_ts;
                    const bool is_visible =
                        cr::Worker::my().cc.isVisibleForMe(entry_last_modified_worker_id, entry_tx_ts, false);
                    if (is_visible) {
                        const u8* payload_ptr =
                            reinterpret_cast<const u8*>(entry) + sizeof(RecordCacheEntry) + entry->key_length;
                        payload_callback(payload_ptr, entry->value_length);
                        SieveFIFOQueue::OnSieveFIFOAccess(entry);
                        leaveEpoch(worker_id);
                        return true;
                    }
                }
                entry = entry->next;
            }
        }
    }

    leaveEpoch(worker_id);
    return false;
}
//===================================[Added].==========================================================
//                      Update Interceptor: tryUpdateAndInvalidateRecordCache
//======================================================================================================
bool RecordCache::tryUpdateAndInvalidateRecordCache(u16 dt_id, std::span<const u8> key, u64 worker_id){
    // 1. Worker thread enterEpoch, {active, current_epoch}
    enterEpoch(worker_id);

    // 2. Build (dt_id || key) on the stack for multi-table key namespacing.
    u8 prefixed_buf[128];
    assert(2 + key.size() <= sizeof(prefixed_buf));
    std::span<const u8> prefixed_key = BuildPrefixedKey(dt_id, key, prefixed_buf);

    const u64 hash_value = HashBytes(prefixed_key);
    const auto& target_shard = getShardByHash(hash_value);
    std::string key_str(reinterpret_cast<const char*>(prefixed_key.data()), prefixed_key.size());
    UpdatableLookupResult lookup_result;

    {
        std::shared_lock lock(target_shard.mutex);
        auto it = target_shard.hash_map_shard.find(key_str);
        if (it != target_shard.hash_map_shard.end()) {
            lookup_result = FindFirstUpdatableEntry(it->second);
        }
    }
    if (lookup_result.skipped_placeholder) {
        update_skip_placeholder.fetch_add(1, std::memory_order_relaxed);
    }
    if (lookup_result.found_readonly_next) {
        update_found_readonly_next.fetch_add(1, std::memory_order_relaxed);
    }
    RecordCacheEntry* target = lookup_result.target;
    if (target == nullptr) {
        update_no_updatable_readonly.fetch_add(1, std::memory_order_relaxed);
        leaveEpoch(worker_id);
        return false;
    }

    RecordCacheType current_type = target->entry_type.load(std::memory_order_acquire);
    if (current_type == RecordCacheType::ReadOnlyMode) {
        if (target->casType(current_type, RecordCacheType::LogicallyDeletedButStillInHashTable)) {
            addToInvalidationQueue(target, getCurrentEpoch());
            leaveEpoch(worker_id);
            return true;
        }
    }
    leaveEpoch(worker_id);
    return false;
}

//===================================[Added].==========================================================
//                      Slab Rescue: B-mover v5
//
// ReadOnly adaptation: CAS ReadOnlyMode(000) → Removed(100) instead of
// WriteThroughMode(001) → Removed(100). Entries in state 011 (logically
// deleted) are also candidates: they are already invalidated by a worker
// update but still hold a slab block while ForwardEpoch hasn't removed them
// from the hash table yet. We unlink them under shard lock so ForwardEpoch's
// later EraseFromRecordCache will harmlessly return false.
//
// Unlike WriteThrough, ReadOnly has no SeqLock readers so epoch-wait after
// unlinking is still safe: any worker that entered RecordCache before our
// erase holds epoch ≤ e_unlink and will leave quickly.
//======================================================================================================
bool RecordCache::tryRescueSlabForAllocator()
{
    std::lock_guard<std::mutex> rescue_lock(slab_rescue_mutex);

    if (allocator.hasFreeSlab()) {
        return true;
    }

    constexpr size_t kMaxCandidates = 5;
    auto candidates = allocator.findRescueCandidates(kMaxCandidates);
    if (candidates.empty()) {
        return false;
    }

    for (const auto& cand : candidates) {
        const char* slab_base = cand.slab_base;
        const char* slab_end  = cand.slab_base + cand.slab_bytes;

        std::vector<RecordCacheEntry*> collected;
        collected.reserve(cand.live_count);

        for (size_t s = 0; s < num_of_shards; s++) {
            auto& shard = hash_shards[s];
            std::unique_lock<std::shared_mutex> shard_lock(shard.mutex);
            for (auto it = shard.hash_map_shard.begin(); it != shard.hash_map_shard.end(); ) {
                RecordCacheEntry* prev = nullptr;
                RecordCacheEntry* cur = it->second;
                while (cur != nullptr) {
                    RecordCacheEntry* next = cur->next;
                    const char* cp = reinterpret_cast<const char*>(cur);
                    bool unlinked = false;
                    if (cp >= slab_base && cp < slab_end) {
                        RecordCacheType expected = RecordCacheType::ReadOnlyMode;
                        if (cur->casType(expected,
                                RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation)) {
                            if (prev == nullptr) {
                                it->second = next;
                            } else {
                                prev->next = next;
                            }
                            cur->next = nullptr;
                            active_entry_count.fetch_sub(1, std::memory_order_relaxed);
                            collected.push_back(cur);
                            unlinked = true;
                        } else {
                            expected = RecordCacheType::LogicallyDeletedButStillInHashTable;
                            if (cur->casType(expected,
                                    RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation)) {
                                if (prev == nullptr) {
                                    it->second = next;
                                } else {
                                    prev->next = next;
                                }
                                cur->next = nullptr;
                                active_entry_count.fetch_sub(1, std::memory_order_relaxed);
                                collected.push_back(cur);
                                unlinked = true;
                            }
                        }
                    }
                    if (!unlinked) {
                        prev = cur;
                    }
                    cur = next;
                }
                if (it->second == nullptr) {
                    it = shard.hash_map_shard.erase(it);
                } else {
                    ++it;
                }
            }
        }

        if (collected.empty()) {
            continue;
        }

        sieve_fifo_queue.markSlabEntriesAsNull(slab_base, slab_end);

        const u64 e_unlink = epoch_manager.get_global_epoch();
        epoch_manager.periodically_advance_global_epoch();

        constexpr int kMaxPoll = 1000;
        bool safe = false;
        for (int i = 0; i < kMaxPoll; i++) {
            if (epoch_manager.is_safe_to_invalidate(e_unlink)) {
                safe = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }

        if (!safe) {
            for (auto* entry : collected) {
                addToInvalidationQueue(entry, e_unlink);
            }
            fprintf(stderr,
                "[N4-DIAG][SLAB-RESCUE] timeout waiting for epoch slab_idx=%zu unlinked=%zu — handed off to InvalidationQueue\n",
                cand.slab_idx, collected.size());
            fflush(stderr);
            continue;
        }

        for (auto* entry : collected) {
            const size_t entry_size = entry->totalSizeForRecordCacheEntry();
            allocator.deallocate(entry, entry_size, alignof(RecordCacheEntry));
        }

        if (allocator.hasFreeSlab()) {
            fprintf(stderr,
                "[N4-DIAG][SLAB-RESCUE] success slab_idx=%zu block_size=%zu unlinked=%zu\n",
                cand.slab_idx, cand.block_size, collected.size());
            fflush(stderr);
            return true;
        }
    }

    return allocator.hasFreeSlab();
}

}  // namespace recordcache
}  // namespace storage
}  // namespace leanstore