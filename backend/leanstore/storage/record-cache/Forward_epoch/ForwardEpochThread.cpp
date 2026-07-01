#include "../RecordCache.hpp"
#include <chrono>
#include <pthread.h>
#include <span>
#include <string>
#include <thread>

namespace leanstore {
namespace storage {
namespace recordcache {

void RecordCache::forwardEpochThread()
{
    std::string thread_name("rc_forward_epoch");
    pthread_setname_np(pthread_self(), thread_name.c_str());

    std::vector<InvalidationEntry> local_invalidation_retry_queue;
    local_invalidation_retry_queue.reserve(1024);

    while (bg_threads_keep_running.load(std::memory_order_acquire)) {
        // avoid busy-waiting
        std::this_thread::sleep_for(std::chrono::milliseconds(1));

        // [1] periodically advance global epoch
        epoch_manager.periodically_advance_global_epoch();

        // [2] Obtain local entries from InvalidationQueue
        std::vector<InvalidationEntry> this_turn_new_invalidation = invalidation_queue.pop_all();

        // [2.1] Combine new entries to local_invalidation_retry_queue
        if (!this_turn_new_invalidation.empty()) {
            local_invalidation_retry_queue.insert(local_invalidation_retry_queue.end(),
                                                  this_turn_new_invalidation.begin(),
                                                  this_turn_new_invalidation.end());
        }

        // [2.2] If there are no entries to process, continue to next iteration
        if (local_invalidation_retry_queue.empty()) {
            continue;
        }

        // [2.3] traverse all InvalidationEntry in local_invalidation_retry_queue
        std::vector<InvalidationEntry> next_turn_retry_queue;
        next_turn_retry_queue.reserve(local_invalidation_retry_queue.size());

        for (const auto& item : local_invalidation_retry_queue) {
            // Check the RecordCacheEntry when logically deleted, whether it can safely be physically reclaimed.
            if (epoch_manager.is_safe_to_invalidate(item.update_epoch)) {
                // [3.1] Safe, unlink by pointer from per-key chain.
                std::span<const u8> delete_key_span = item.entry_pointer->getKeySpan();
                const u64 hash_value = HashBytes(delete_key_span);
                auto& target_shard = getShardByHash(hash_value);
                bool removed = false;
                {
                    std::unique_lock<std::shared_mutex> lock(target_shard.mutex);
                    std::string key_str(reinterpret_cast<const char*>(delete_key_span.data()),
                                        delete_key_span.size());
                    auto it = target_shard.hash_map_shard.find(key_str);
                    if (it != target_shard.hash_map_shard.end()) {
                        RecordCacheEntry* prev = nullptr;
                        RecordCacheEntry* cur = it->second;
                        while (cur != nullptr) {
                            if (cur == item.entry_pointer) {
                                if (prev == nullptr) {
                                    it->second = cur->next;
                                } else {
                                    prev->next = cur->next;
                                }
                                cur->next = nullptr;
                                if (it->second == nullptr) {
                                    target_shard.hash_map_shard.erase(it);
                                }
                                removed = true;
                                break;
                            }
                            prev = cur;
                            cur = cur->next;
                        }
                    }
                }

                if (removed) {
                    // [3.2] Successfully removed from hash table, update the Type
                    // LogicallyDeletedButStillInHashTable -> RemovedFromHashTableButWaitForPhysicalMemoryDeallocation
                    item.entry_pointer->entry_type.store(RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation, std::memory_order_release);
                    // [FIX-C] One more entry transitioned 011->100 — signal SIEVE
                    // that there is a known-dead entry waiting in the FIFO.
                    IncrementPendingStateInvalidatedFromHash();
                } else {
                    // If the entry has already reached state=100 by another path,
                    // it no longer needs forward-epoch retry.
                    auto t = item.entry_pointer->entry_type.load(std::memory_order_acquire);
                    if (t != RecordCacheType::RemovedFromHashTableButWaitForPhysicalMemoryDeallocation) {
                        // Failed to remove (e.g., key replaced concurrently), retry later.
                        next_turn_retry_queue.push_back(item);
                    }
                }

            } else {
                // Unsafe, there are still worker threads working on it.
                next_turn_retry_queue.push_back(item);
            }
        }

        // [4] Update local_invalidation_retry_queue
        local_invalidation_retry_queue = std::move(next_turn_retry_queue);
    }

    // Thread is exiting, decrement counter
    bg_threads_counter.fetch_sub(1, std::memory_order_release);
}

}  // namespace recordcache
}  // namespace storage
}  // namespace leanstore