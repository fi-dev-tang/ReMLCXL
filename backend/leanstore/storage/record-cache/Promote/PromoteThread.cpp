#include "../RecordCache.hpp"
#include<span>
#include<pthread.h>
#include"../RecordCacheEntry.hpp"
#include"../RecordCacheSlabAllocator.hpp"
#include"Units.hpp"
#include"../../btree/BTreeVI.hpp"
#include"../../btree/core/BTreeNode.hpp"
#include"../../buffer-manager/BMPlainGuard.hpp"

namespace leanstore{
namespace storage{
namespace recordcache{

// Condition_variable wait signal.
void RecordCache::promoteThread(){
    std::string thread_name("rc_promote");
    pthread_setname_np(pthread_self(), thread_name.c_str());

    while(bg_threads_keep_running.load(std::memory_order_acquire)){
        PromoteRequestMessage request;

        // Accept Signal from WorkerThread(lookup procedure)
        {
            std::unique_lock<std::mutex> lock(promote_request_queue_mutex);

            promote_request_cv.wait(lock,[this]{
                return !promote_request_message_queue.empty() || !bg_threads_keep_running.load(std::memory_order_acquire);
            });

            if(!bg_threads_keep_running.load(std::memory_order_acquire) && promote_request_message_queue.empty()){
                break;
            }
            request = std::move(promote_request_message_queue.front());
            promote_request_message_queue.pop();
        }
        processOnPromotionRequest(request);
        {
            std::lock_guard<std::mutex> lock(promote_request_queue_mutex);
            inflight_promote_keys.erase(request.key);
        }
    }
    bg_threads_counter.fetch_sub(1, std::memory_order_release);
}

//-----------------------------------[Added].----------------------------------------
// Core function:
// Promote thread has the only function as Promote, it does not handle physical memory deallocation(EvictionThread's responsibility).
// Here we avoid all the conflict situation, only does the three thing
// 1. Check if the inserted key is not in RecordCache(Only NotFond or RemovedFromHashTableButWaitForPhysicalMemoryDeallocation)
// 2. If not found, then we read CXL BufferFrame to our thread_local_cache(without holding lock)
// 3. Hold lock, double-check if conflict
//    Not conflict, then finish the Promotion Procedure.
// [Only Two cases allowed] Type Machine: Not Found or RemovedFromHashTableButWaitForPhysicalMemoryDeallocation
void RecordCache::processOnPromotionRequest(const PromoteRequestMessage& request){
    // [FIX-B] Producer-side hard backpressure against OOM.
    static constexpr double kPromoteHardWatermark = 0.95;
    if (allocator.getUsageRatio() > kPromoteHardWatermark) {
        promote_rejected_high_water.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    std::span<const u8> key_span(reinterpret_cast<const u8*>(request.key.data()),
    request.key.size());

    const u64 hash_value = HashBytes(key_span);
    auto& target_shard = getShardByHash(hash_value);

    RecordCacheEntry *new_entry = nullptr;
    const u16 key_len = static_cast<u16>(request.key.size());
    const u16 value_len = static_cast<u16>(request.value_length);
    size_t total_record_size = sizeof(RecordCacheEntry) + key_len + value_len;

    // lambda expression for allocation new_entry
    auto allocate_new_entry = [&]() -> RecordCacheEntry*{
        // [B-mover v5] allocator.allocate now invokes the rescue callback on
        // exhaustion. If rescue also fails, bad_alloc is thrown. Catch it and
        // silently drop the promote — worker will serve from CXL B+Tree.
        void *mem = nullptr;
        try {
            mem = allocator.allocate(total_record_size, alignof(RecordCacheEntry));
        } catch (const std::bad_alloc&) {
            return nullptr;
        }
        if(!mem){
            return nullptr;
        }

        auto *entry = new (mem) RecordCacheEntry();
        entry -> tx_ts = 0;
        entry -> last_modified_worker_id = 0;
        entry -> key_length = key_len;
        entry -> value_length = value_len;
        entry -> visited.store(false, std::memory_order_relaxed);
        entry -> next = nullptr;
        entry -> setType(RecordCacheType::PromoteThreadHoldingThePosition);

        std::memcpy(entry -> payload, request.key.data(), key_len);
        return entry;
    };

    //==============================================================================================
    //      Phase 1: Pre-allocate OUTSIDE shard lock, then decide under lock.
    //
    // CRITICAL deadlock fix: allocate_new_entry() may invoke
    // tryRescueSlabForAllocator() which iterates ALL shards and takes each
    // shard.mutex as unique_lock. If we held target_shard.mutex here, that
    // would self-deadlock. Pre-allocate before taking the shard lock.
    //==============================================================================================
    RecordCacheEntry* preallocated = allocate_new_entry();
    if(preallocated == nullptr){
        promote_alloc_failed.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    bool preallocated_consumed = false;
    {
        std::unique_lock<std::shared_mutex> lock(target_shard.mutex);

        auto existing_item = target_shard.hash_map_shard.find(request.key);
        if(existing_item != target_shard.hash_map_shard.end()){
            RecordCacheEntry * existing_head = existing_item -> second;
            auto head_type = existing_head->entry_type.load(std::memory_order_acquire);

            // Fast-path re-promotion:
            // if old head is logically deleted(011) or already removed(100),
            // install new entry as head immediately and keep old in chain.
            if(head_type == RecordCacheType::LogicallyDeletedButStillInHashTable ||
               head_type == RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation){
                preallocated->next = existing_head;
                existing_item -> second = preallocated;
                new_entry = preallocated;
                preallocated_consumed = true;
            }
        }else{
            preallocated->next = nullptr;
            target_shard.hash_map_shard.emplace(request.key, preallocated);
            new_entry = preallocated;
            preallocated_consumed = true;
        }

    }   // Release shard lock as soon as possible.

    if(!preallocated_consumed){
        promote_head_still_live.fetch_add(1, std::memory_order_relaxed);
        if (request.is_direct_update) {
            direct_update_head_still_live.fetch_add(1, std::memory_order_relaxed);
        }
        const size_t alloc_size = preallocated->totalSizeForRecordCacheEntry();
        preallocated->~RecordCacheEntry();
        allocator.deallocate(preallocated, alloc_size, alignof(RecordCacheEntry));
        return;
    }
    // [FIX-A] active_entry_count tracks allocated entries in slabs.
    active_entry_count.fetch_add(1, std::memory_order_relaxed);

    // FIFO enqueue outside shard lock(avoid deadlock with eviction path).
    if(new_entry != nullptr) sieve_fifo_queue.InsertIntoSieveFIFO(new_entry);

    //==========================================================================================================================================
    // Core Execution:
    // Phase 2: Not Holding lock,
    // Reading context from CXL BufferFrame to thread_local_cache.
    // Protected by OptimisticGuard: if the page is concurrently modified (split/compact/update),
    // the recheck() will longjmp and we abort this promote attempt.
    //==========================================================================================================================================
    std::vector<u8> local_value_buffer;
    local_value_buffer.resize(value_len);

    u64 local_tx_ts = 0;
    u16 local_worker_id = 0;
    bool cxl_read_success = false;

    jumpmuTry() {
        BMOptimisticGuard cxl_opt_guard(request.bf->header.latch);

        if (request.bf->header.pid != request.pid ||
            request.bf->header.state != leanstore::storage::BufferFrame::STATE::HOT) {
            jumpmu_return;
        }

        auto* btree_node = reinterpret_cast<leanstore::storage::btree::BTreeNode*>(request.bf->page.dt);
        if (request.slot_id >= btree_node->count) {
            jumpmu_return;
        }

        // Phase 2 recheck: verify the slot still holds the key we were asked
        // to promote. Concurrent insert/split/merge can shift slots between
        // admission and now, leaving a DIFFERENT key at request.slot_id.
        //
        // [v4-a fix] request.key carries the SAME bytes that BuildPrefixedKeyOwning
        // produced for the lookup path. When FLAGS_rc_skip_dt_id_prefix=true
        // (YCSB / single-table), there is NO 2-byte dt_id prefix and the request
        // key matches the on-page key 1:1. When false (TPC-C / multi-table), the
        // first 2 bytes are dt_id and must be stripped before comparing.
        {
            const u16 prefix_bytes  = FLAGS_rc_skip_dt_id_prefix ? 0 : 2;
            const u16 page_key_len  = btree_node->getFullKeyLen(request.slot_id);
            if (request.key_length < prefix_bytes
                || page_key_len != static_cast<u16>(request.key_length - prefix_bytes)) {
                jumpmu_return;
            }
            constexpr u16 kMaxKeyBytes = 256;
            if (page_key_len > kMaxKeyBytes) {
                jumpmu_return;
            }
            u8 page_key_buf[kMaxKeyBytes];
            btree_node->copyFullKey(request.slot_id, page_key_buf);
            if (std::memcmp(page_key_buf,
                            reinterpret_cast<const u8*>(request.key.data()) + prefix_bytes,
                            page_key_len) != 0) {
                jumpmu_return;
            }
        }

        u8* payload = btree_node->getPayload(request.slot_id);
        auto* tuple = reinterpret_cast<leanstore::storage::btree::BTreeVI::Tuple*>(payload);

        using TupleFormat = leanstore::storage::btree::BTreeVI::TupleFormat;

        local_tx_ts = tuple->tx_ts;
        local_worker_id = tuple->worker_id;

        if (tuple->tuple_format == TupleFormat::CHAINED) {
            auto* chained_tuple = reinterpret_cast<leanstore::storage::btree::BTreeVI::ChainedTuple*>(payload);
            std::memcpy(local_value_buffer.data(), chained_tuple->payload, value_len);
        } else if (tuple->tuple_format == TupleFormat::FAT_TUPLE_DIFFERENT_ATTRIBUTES) {
            auto* fat_tuple = reinterpret_cast<leanstore::storage::btree::BTreeVI::FatTupleDifferentAttributes*>(payload);
            std::memcpy(local_value_buffer.data(), fat_tuple->getValue(), value_len);
        } else {
            std::memcpy(local_value_buffer.data(), payload + sizeof(leanstore::storage::btree::BTreeVI::Tuple), value_len);
        }

        cxl_opt_guard.recheck();
        cxl_read_success = true;
    } jumpmuCatch() {
        // Optimistic read failed (page was concurrently modified) — abort this promote.
    }

    if (!cxl_read_success) {
        promote_cxl_read_failed.fetch_add(1, std::memory_order_relaxed);
        // Clean up: new_entry is ALREADY in sieve_fifo_queue, so we cannot
        // directly deallocate. Hand off to InvalidationQueue so ForwardEpoch
        // removes from hash → SIEVE frees slab.
        {
            std::unique_lock<std::shared_mutex> lock(target_shard.mutex);
            auto it = target_shard.hash_map_shard.find(request.key);
            if (it != target_shard.hash_map_shard.end()) {
                RecordCacheEntry* prev = nullptr;
                RecordCacheEntry* cur = it->second;
                while (cur != nullptr) {
                    if (cur == new_entry) {
                        if (prev == nullptr) {
                            it->second = cur->next;
                        } else {
                            prev->next = cur->next;
                        }
                        cur->next = nullptr;
                        if (it->second == nullptr) {
                            target_shard.hash_map_shard.erase(it);
                        }
                        break;
                    }
                    prev = cur;
                    cur = cur->next;
                }
                // [FIX-A] do NOT decrement active_entry_count here — slab is still
                // allocated; SIEVE Case A will release it (and decrement).
            }
        }
        new_entry->setType(RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation);
        // [FIX-C] entry dropped directly to state=100; signal SIEVE
        IncrementPendingStateInvalidatedFromHash();
        return;
    }

    //==========================================================================================================================================
    // Core Execution:
    // Phase 3: Holding lock,
    // double-check, write value back to new_entry
    // PromoteThreadHoldingThePosition -> ReadOnly: success (if no concurrent update)
    // LogicallyDeletedButStillInHashTable -> RemovedFromHashTableButWaitForPhysicalMemoryDeallocation: Eviction Thread handle it.
    //==========================================================================================================================================
    {
        std::unique_lock<std::shared_mutex> lock(target_shard.mutex);

        auto current_type = new_entry -> entry_type.load(std::memory_order_acquire);
        if(current_type == RecordCacheType::PromoteThreadHoldingThePosition){
            // Check if a concurrent update happened during our promotion (Phase 2 CXL read).
            // If so, the data we read may be stale — cancel this promotion.
            if (new_entry->update_during_promote.load(std::memory_order_acquire)) {
                promote_cancelled_before_publish.fetch_add(1, std::memory_order_relaxed);
                // Unlink from hash chain
                auto it = target_shard.hash_map_shard.find(request.key);
                if(it != target_shard.hash_map_shard.end()){
                    RecordCacheEntry* prev = nullptr;
                    RecordCacheEntry* cur = it->second;
                    while (cur != nullptr) {
                        if (cur == new_entry) {
                            if (prev == nullptr) {
                                it->second = cur->next;
                            } else {
                                prev->next = cur->next;
                            }
                            cur->next = nullptr;
                            if (it->second == nullptr) {
                                target_shard.hash_map_shard.erase(it);
                            }
                            break;
                        }
                        prev = cur;
                        cur = cur->next;
                    }
                }
                new_entry -> setType(RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation);
                IncrementPendingStateInvalidatedFromHash();
                return;
            }
            // double-check succeed — no concurrent update, publish the entry.
            std::memcpy(new_entry -> payload + key_len, local_value_buffer.data(), value_len);
            new_entry -> tx_ts = local_tx_ts;
            new_entry -> last_modified_worker_id = local_worker_id;
            new_entry -> setType(RecordCacheType::ReadOnlyMode);
            promote_success.fetch_add(1, std::memory_order_relaxed);
            if (request.is_direct_update) {
                direct_update_promote_success.fetch_add(1, std::memory_order_relaxed);
            }
            return;
        }
        else if(current_type == RecordCacheType::LogicallyDeletedButStillInHashTable){
            promote_cancelled_before_publish.fetch_add(1, std::memory_order_relaxed);
            auto it = target_shard.hash_map_shard.find(request.key);
            if(it != target_shard.hash_map_shard.end()){
                RecordCacheEntry* prev = nullptr;
                RecordCacheEntry* cur = it->second;
                while (cur != nullptr) {
                    if (cur == new_entry) {
                        if (prev == nullptr) {
                            it->second = cur->next;
                        } else {
                            prev->next = cur->next;
                        }
                        cur->next = nullptr;
                        if (it->second == nullptr) {
                            target_shard.hash_map_shard.erase(it);
                        }
                        break;
                    }
                    prev = cur;
                    cur = cur->next;
                }
            }
            new_entry -> setType(RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation);
            // [FIX-C] entry dropped directly to state=100; signal SIEVE
            IncrementPendingStateInvalidatedFromHash();
            return;
        }
        else if(current_type == RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation){
            // A concurrent eviction unlinked us before we finished promoting.
            return;
        }
        else{
            assert(false && "Error, Promote Thread will not create other logic");
        }
    }
}
}
}
}