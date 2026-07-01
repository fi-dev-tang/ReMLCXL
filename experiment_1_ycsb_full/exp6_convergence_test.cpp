// =============================================================================
// exp6_convergence_test.cpp
//
// Exp6: RecordCache convergence time measurement.
//
// Measures the time from RecordCache cold-start (after B-tree warmup) until
// slab usage first reaches EvictionWaterMark (0.95). A monitor thread samples
// fill rate at configurable intervals and writes a convergence timeline CSV.
//
// Workflow:
//   Phase 1: Bulk load data (B-tree populated on CXL/SSD)
//   Phase 2: Warmup lookups WITHOUT RecordCache threads
//            (--delay_admission_recordcache_threads_start=true)
//   Phase 3: Enable RC threads, start monitor, run YCSB-C lookups until
//            convergence or timeout
//
// Key output:
//   - TIME_TO_WATERMARK_MS=<value> on stdout (grep-friendly)
//   - Full timeline CSV via --test_convergence_csv
//
// Uses only two_level admission mode, YCSB-C (100% read).
// =============================================================================

#include "../frontend/shared/LeanStoreAdapter.hpp"
#include "../frontend/shared/Schema.hpp"
#include "Units.hpp"
#include "leanstore/Config.hpp"
#include "leanstore/LeanStore.hpp"
#include "leanstore/utils/Parallelize.hpp"
#include "leanstore/utils/RandomGenerator.hpp"
#include "leanstore/storage/buffer-manager/BufferManager.hpp"
#include "leanstore/storage/record-cache/RecordCacheEntry.hpp"
#include "leanstore/storage/record-cache/RecordCache.hpp"
#include "leanstore/storage/record-cache/RecordCacheSlabAllocator.hpp"

#include <gflags/gflags.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <numeric>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace leanstore;
using u64 = std::uint64_t;

using YCSBKey     = u64;
using YCSBPayload = BytesPayload<600>;
using YCSBTable   = Relation<YCSBKey, YCSBPayload>;

constexpr u64 GiB = 1024ULL * 1024ULL * 1024ULL;

// ============================================================================
// gflags
// ============================================================================
DEFINE_double(test_working_set_gib,        14.0,  "Target working set size in GiB");
DEFINE_double(test_zipf_theta,             0.90,  "Zipfian skew parameter");
DEFINE_uint64(test_payload_size_bytes,     100,   "Payload bytes per record");
DEFINE_double(test_fill_factor,            0.5,   "B+Tree leaf page fill factor");
DEFINE_uint64(test_warmup_lookups,         200000000ULL, "Warmup lookup count (RC threads NOT running)");
DEFINE_uint64(test_warmup_progress_interval, 2000000ULL, "Print warmup progress every N lookups");
DEFINE_uint64(test_seed,                   42ULL, "Random seed");
DEFINE_string(test_admission_mode,         "two_level", "Only two_level is supported");

DEFINE_string(test_convergence_csv,        "convergence_timeline.csv", "Output CSV path");
DEFINE_uint64(test_monitor_interval_ms,    100,   "Monitor sampling interval in ms");
DEFINE_uint64(test_max_convergence_secs,   600,   "Max time to wait for convergence");
DEFINE_uint64(test_post_converge_secs,     30,    "Continue running after convergence for stability check");

// ============================================================================
// Helpers
// ============================================================================
namespace Color {
const char* RESET   = "\033[0m";
const char* RED     = "\033[31m";
const char* GREEN   = "\033[32m";
const char* YELLOW  = "\033[33m";
const char* CYAN    = "\033[36m";
const char* MAGENTA = "\033[35m";
const char* BOLD    = "\033[1m";
}

void print_info(const std::string& msg)  { std::cout << Color::CYAN   << "[INFO] " << Color::RESET << msg << "\n"; }
void print_pass(const std::string& msg)  { std::cout << Color::GREEN  << "[PASS] " << Color::RESET << msg << "\n"; }
void print_fail(const std::string& msg)  { std::cout << Color::RED    << "[FAIL] " << Color::RESET << msg << "\n"; }
void print_phase(const std::string& msg) {
   std::cout << "\n" << Color::BOLD << Color::MAGENTA
             << "========================================\n"
             << "  " << msg << "\n"
             << "========================================" << Color::RESET << "\n";
}

// ============================================================================
// Config
// ============================================================================
struct Config {
   double fill_factor         = 0.5;
   double working_set_gib     = 14.0;
   double record_cache_gib    = 1.0;
   double zipf_theta          = 0.90;
   u64    payload_size_bytes   = 100;
   u64    seed                 = 42ULL;

   static constexpr u64 BTREE_PAGE_SIZE             = 16384;
   static constexpr u64 BTREE_EFFECTIVE_PAGE_SIZE   = 16352;
   static constexpr u64 BTREE_NODE_HEADER_BYTES     = 96;
   static constexpr u64 BTREE_SLOT_BYTES            = 10;
   static constexpr u64 BTREE_CHAINED_TUPLE_BYTES   = 25;
   static constexpr u64 RECORD_CACHE_ENTRY_BYTES    = 16;
   static constexpr u64 BTREE_USABLE_BYTES_PER_PAGE =
       BTREE_EFFECTIVE_PAGE_SIZE - BTREE_NODE_HEADER_BYTES;

   u64 per_record_on_page_bytes() const {
      return BTREE_SLOT_BYTES + sizeof(YCSBKey) + BTREE_CHAINED_TUPLE_BYTES + payload_size_bytes;
   }
   u64 records_per_page() const {
      return static_cast<u64>(
          static_cast<double>(BTREE_USABLE_BYTES_PER_PAGE) * fill_factor /
          static_cast<double>(per_record_on_page_bytes()));
   }
   u64 total_pages() const {
      return static_cast<u64>(working_set_gib * GiB) / BTREE_PAGE_SIZE;
   }
   u64 total_records() const {
      return total_pages() * records_per_page();
   }
   u64 rc_entry_bytes() const {
      return RECORD_CACHE_ENTRY_BYTES + sizeof(YCSBKey) + payload_size_bytes;
   }
};

Config build_config_from_flags() {
   Config cfg;
   cfg.fill_factor       = FLAGS_test_fill_factor;
   cfg.working_set_gib   = FLAGS_test_working_set_gib;
   cfg.record_cache_gib  = FLAGS_dram_recordcache_gib;
   cfg.zipf_theta        = FLAGS_test_zipf_theta;
   cfg.payload_size_bytes = FLAGS_test_payload_size_bytes;
   cfg.seed              = FLAGS_test_seed;
   return cfg;
}

// ============================================================================
// SplitMix64
// ============================================================================
class SplitMix64 {
public:
   explicit SplitMix64(u64 seed) : state_(seed) {}
   u64 next() {
      u64 z = (state_ += 0x9e3779b97f4a7c15ULL);
      z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
      z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
      return z ^ (z >> 31);
   }
   double next01() {
      return static_cast<double>(next()) /
             static_cast<double>(std::numeric_limits<u64>::max());
   }
private:
   u64 state_;
};

// ============================================================================
// ZipfGenerator + ScrambledZipfGenerator (same as experiment1_ycsb_c)
// ============================================================================
static u64 fnvHash64(u64 val) {
   constexpr u64 FNV_OFFSET_BASIS = 0xCBF29CE484222325ULL;
   constexpr u64 FNV_PRIME        = 1099511628211ULL;
   u64 h = FNV_OFFSET_BASIS;
   for (int i = 0; i < 8; i++) {
      h ^= (val & 0xffULL);
      h *= FNV_PRIME;
      val >>= 8;
   }
   return h;
}

class ZipfGenerator {
public:
   ZipfGenerator() = default;
   ZipfGenerator(u64 n, double theta) { reset(n, theta); }
   void reset(u64 n, double theta) {
      n_ = n; theta_ = theta;
      alpha_ = 1.0 / (1.0 - theta);
      zetan_ = zeta(n, theta);
      eta_   = (1.0 - std::pow(2.0 / static_cast<double>(n), 1.0 - theta)) /
               (1.0 - zeta(2, theta) / zetan_);
   }
   u64 next(SplitMix64& rng) const {
      const double u  = rng.next01();
      const double uz = u * zetan_;
      if (uz < 1.0) return 1;
      if (uz < 1.0 + std::pow(0.5, theta_)) return 2;
      return 1 + static_cast<u64>(
          static_cast<double>(n_) * std::pow(eta_ * u - eta_ + 1.0, alpha_));
   }
private:
   static double zeta(u64 n, double theta) {
      double sum = 0.0;
      for (u64 i = 1; i <= n; i++) sum += std::pow(1.0 / static_cast<double>(i), theta);
      return sum;
   }
   u64 n_ = 0; double theta_ = 0, alpha_ = 0, zetan_ = 0, eta_ = 0;
};

class ScrambledZipfGenerator {
public:
   ScrambledZipfGenerator() = default;
   ScrambledZipfGenerator(u64 n, double theta) { reset(n, theta); }
   void reset(u64 n, double theta) { n_ = n; zipf_.reset(n, theta); }
   u64 next(SplitMix64& rng) const { return fnvHash64(zipf_.next(rng)) % n_; }
   u64 size() const { return n_; }
private:
   u64 n_ = 0;
   ZipfGenerator zipf_;
};

// ============================================================================
// Monitor sample
// ============================================================================
struct MonitorSample {
   double elapsed_ms;
   double slab_usage_pct;
   u64    active_entries;
   u64    logical_capacity;
   double fill_ratio_pct;
   u64    sieve_evictions;
   u64    rc_hit;
   u64    cxl_hit;
   u64    ssd_miss;
};

// ============================================================================
// Phase 1: Bulk load
// ============================================================================
void phase1_load_data(cr::CRManager& crm,
                      LeanStoreAdapter<YCSBTable>& table,
                      u64 tuple_count, u64 payload_size_bytes)
{
   print_phase("Phase 1: Load Data");
   auto t0 = std::chrono::high_resolution_clock::now();

   utils::Parallelize::range(
       FLAGS_worker_threads, tuple_count,
       [&](u64 t_i, u64 range_begin, u64 range_end) {
          crm.scheduleJobAsync(t_i, [&, range_begin, range_end]() {
             for (u64 i = range_begin; i < range_end; i++) {
                YCSBPayload payload;
                std::memset(payload.value, 0, sizeof(payload.value));
                utils::RandomGenerator::getRandString(payload.value, payload_size_bytes);
                cr::Worker::my().startTX(TX_MODE::OLTP,
                                         TX_ISOLATION_LEVEL::SNAPSHOT_ISOLATION);
                table.insert_var({i}, {payload}, payload_size_bytes);
                cr::Worker::my().commitTX();
             }
          });
       });
   crm.joinAll();

   const double secs = std::chrono::duration<double>(
       std::chrono::high_resolution_clock::now() - t0).count();
   print_info("Loaded " + std::to_string(tuple_count) + " records in " +
              std::to_string(secs) + " s (" +
              std::to_string(tuple_count / secs / 1e6) + " M rec/s)");
}

// ============================================================================
// Reset diagnostic counters
// ============================================================================
static void reset_diag_counters()
{
   auto& bm = *storage::BMC::global_bf;
   bm.diag.record_cache_hit.store(0,       std::memory_order_relaxed);
   bm.diag.record_cache_miss.store(0,      std::memory_order_relaxed);
   bm.diag.dram_buffer_pool_hit.store(0,   std::memory_order_relaxed);
   bm.diag.cxl_buffer_pool_hit.store(0,    std::memory_order_relaxed);
   bm.diag.ssd_miss.store(0,              std::memory_order_relaxed);
   bm.diag.cxl_to_dram_promotions.store(0, std::memory_order_relaxed);
   bm.diag.evictions.store(0,             std::memory_order_relaxed);
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv)
{
   gflags::SetUsageMessage("Exp6: RecordCache convergence time measurement");
   gflags::ParseCommandLineFlags(&argc, &argv, true);

   if (FLAGS_test_admission_mode != "two_level") {
      print_fail("exp6 only supports --test_admission_mode=two_level");
      return 1;
   }

   FLAGS_admission_mode = "two_level";

   const Config cfg = build_config_from_flags();

   if (cfg.records_per_page() == 0 || cfg.total_records() < 2) {
      print_fail("Invalid config: check working_set/payload/fill_factor");
      return 1;
   }

   // Banner
   print_phase("Exp6: RecordCache Convergence Time");
   print_info("working_set_gib       = " + std::to_string(cfg.working_set_gib));
   print_info("dram_buffer_pool_gib  = " + std::to_string(FLAGS_dram_buffer_pool_gib));
   print_info("dram_recordcache_gib  = " + std::to_string(FLAGS_dram_recordcache_gib));
   print_info("cxl_gib               = " + std::to_string(FLAGS_cxl_gib));
   print_info("zipf_theta            = " + std::to_string(cfg.zipf_theta));
   print_info("total_records         = " + std::to_string(cfg.total_records()));
   print_info("total_pages           = " + std::to_string(cfg.total_pages()));
   print_info("rc_entry_bytes        = " + std::to_string(cfg.rc_entry_bytes()));
   print_info("warmup_lookups        = " + std::to_string(FLAGS_test_warmup_lookups));
   print_info("monitor_interval_ms   = " + std::to_string(FLAGS_test_monitor_interval_ms));
   print_info("max_convergence_secs  = " + std::to_string(FLAGS_test_max_convergence_secs));
   print_info("post_converge_secs    = " + std::to_string(FLAGS_test_post_converge_secs));
   print_info("convergence_csv       = " + FLAGS_test_convergence_csv);

   ScrambledZipfGenerator generator(cfg.total_records(), cfg.zipf_theta);

   // Initialize LeanStore
   print_phase("Initialize LeanStore");
   LeanStore db;
   auto& crm = db.getCRManager();
   LeanStoreAdapter<YCSBTable> table;
   crm.scheduleJobSync(0, [&]() {
      table = LeanStoreAdapter<YCSBTable>(db, "EXP6_CONVERGENCE");
   });
   print_pass("LeanStore initialized");

   // Phase 1: bulk load
   phase1_load_data(crm, table, cfg.total_records(), cfg.payload_size_bytes);

   // Phase 2: warmup WITHOUT RecordCache threads
   // (--delay_admission_recordcache_threads_start=true must be set)
   reset_diag_counters();

   if (FLAGS_test_warmup_lookups > 0) {
      print_phase("Phase 2: Warmup (RC threads NOT running)");

      std::atomic<u64> warmup_done{0};
      auto warmup_t0 = std::chrono::high_resolution_clock::now();

      const u64 thread_count = static_cast<u64>(FLAGS_worker_threads);
      const u64 base_quota   = FLAGS_test_warmup_lookups / thread_count;
      const u64 remainder    = FLAGS_test_warmup_lookups % thread_count;

      for (u64 t_i = 0; t_i < thread_count; t_i++) {
         const u64 quota = base_quota + (t_i < remainder ? 1 : 0);
         crm.scheduleJobAsync(t_i, [&, t_i, quota]() {
            SplitMix64 rng(cfg.seed ^ 0x9E3779B97F4A7C15ULL * (t_i + 1));
            volatile u64 local_done = 0;
            while (local_done < quota) {
               const auto rng_snapshot = rng;
               jumpmuTry() {
                  const YCSBKey key = generator.next(rng);
                  cr::Worker::my().startTX(TX_MODE::OLTP,
                                            TX_ISOLATION_LEVEL::SNAPSHOT_ISOLATION);
                  table.lookup1({key}, [&](const YCSBTable&) {});
                  cr::Worker::my().commitTX();
                  local_done++;

                  const u64 gd = warmup_done.fetch_add(1, std::memory_order_relaxed) + 1;
                  if (FLAGS_test_warmup_progress_interval > 0 &&
                      gd % FLAGS_test_warmup_progress_interval == 0) {
                     const double elapsed = std::chrono::duration<double>(
                         std::chrono::high_resolution_clock::now() - warmup_t0).count();
                     print_info("[Warmup] " + std::to_string(gd) + "/" +
                                std::to_string(FLAGS_test_warmup_lookups) +
                                " (" + std::to_string(100.0 * gd / FLAGS_test_warmup_lookups) +
                                "%) elapsed=" + std::to_string(elapsed) + "s");
                  }
               }
               jumpmuCatch() {
                  rng = rng_snapshot;
               }
            }
         });
      }
      crm.joinAll();

      const double warmup_secs = std::chrono::duration<double>(
          std::chrono::high_resolution_clock::now() - warmup_t0).count();
      print_info("Warmup done: " + std::to_string(FLAGS_test_warmup_lookups) +
                 " lookups in " + std::to_string(warmup_secs) + "s");
   }

   // Phase 3: Enable RC threads, start monitor, run until convergence
   print_phase("Phase 3: Convergence Measurement");

   reset_diag_counters();

   // Enable deferred RC + admission threads
   if (FLAGS_cxl_tiering_enabled && FLAGS_delay_admission_recordcache_threads_start) {
      print_info("Enabling RecordCache + admission threads NOW...");
      storage::BMC::global_bf->enableAdmissionAndRecordCacheThreads();
      if (storage::BMC::global_bf->global_record_cache != nullptr) {
         storage::BMC::global_bf->global_record_cache->setLogicalCapacityFromEntrySize(
             cfg.rc_entry_bytes());
      }
      print_info("RC threads enabled.");
   } else {
      print_fail("Must use --delay_admission_recordcache_threads_start=true "
                 "and --cxl_tiering_enabled=true for exp6");
      return 1;
   }

   // Shared state between monitor and workers
   std::atomic<bool> stop_flag{false};
   std::atomic<bool> converged{false};
   std::atomic<u64>  measure_lookups_done{0};

   // Convergence results
   std::vector<MonitorSample> timeline;
   timeline.reserve(FLAGS_test_max_convergence_secs * 1000 / FLAGS_test_monitor_interval_ms + 100);
   double first_watermark_ms = -1.0;
   double converged_ms       = -1.0;

   auto phase3_t0 = std::chrono::high_resolution_clock::now();

   // --- Monitor thread ---
   std::thread monitor_thread([&]() {
      pthread_setname_np(pthread_self(), "exp6_monitor");

      auto* rc = storage::BMC::global_bf->global_record_cache;
      auto& bm = *storage::BMC::global_bf;

      int consecutive_above_watermark = 0;
      constexpr int kConvergenceCount = 3;

      while (!stop_flag.load(std::memory_order_relaxed)) {
         auto now = std::chrono::high_resolution_clock::now();
         double elapsed_ms = std::chrono::duration<double, std::milli>(now - phase3_t0).count();
         double elapsed_secs = elapsed_ms / 1000.0;

         double slab_usage = 0.0;
         u64 active_entries = 0;
         u64 logical_cap = 0;
         double fill_ratio = 0.0;
         u64 sieve_evictions = 0;

         if (rc != nullptr) {
            slab_usage = bm.record_cache_allocator->getUsageRatio();
            active_entries = rc->getActiveEntryCount();
            logical_cap = rc->getLogicalCapacity();
            fill_ratio = rc->GetRecordCacheFillRatio();
            sieve_evictions = rc->getSieveEvictionEntries();
         }

         u64 rc_hit   = bm.diag.record_cache_hit.load(std::memory_order_relaxed);
         u64 cxl_hit  = bm.diag.cxl_buffer_pool_hit.load(std::memory_order_relaxed);
         u64 ssd_miss = bm.diag.ssd_miss.load(std::memory_order_relaxed);

         MonitorSample s;
         s.elapsed_ms      = elapsed_ms;
         s.slab_usage_pct  = slab_usage * 100.0;
         s.active_entries   = active_entries;
         s.logical_capacity = logical_cap;
         s.fill_ratio_pct   = fill_ratio * 100.0;
         s.sieve_evictions  = sieve_evictions;
         s.rc_hit           = rc_hit;
         s.cxl_hit          = cxl_hit;
         s.ssd_miss         = ssd_miss;
         timeline.push_back(s);

         // Check watermark
         if (slab_usage >= 0.95) {
            if (first_watermark_ms < 0) {
               first_watermark_ms = elapsed_ms;
               print_info("[MONITOR] First watermark hit at " +
                          std::to_string(elapsed_ms) + " ms (slab_usage=" +
                          std::to_string(slab_usage * 100.0) + "%)");
            }
            consecutive_above_watermark++;
            if (consecutive_above_watermark >= kConvergenceCount && !converged.load()) {
               converged_ms = elapsed_ms;
               converged.store(true, std::memory_order_release);
               print_info("[MONITOR] Converged at " + std::to_string(elapsed_ms) +
                          " ms (" + std::to_string(kConvergenceCount) +
                          " consecutive samples >= 95%)");
            }
         } else {
            consecutive_above_watermark = 0;
         }

         // Progress print every ~5 seconds
         static u64 last_print_sec = 0;
         u64 cur_sec = static_cast<u64>(elapsed_secs);
         if (cur_sec >= last_print_sec + 5) {
            last_print_sec = cur_sec;
            print_info("[MONITOR] t=" + std::to_string(elapsed_secs) +
                       "s slab=" + std::to_string(slab_usage * 100.0) +
                       "% entries=" + std::to_string(active_entries) +
                       " sieve=" + std::to_string(sieve_evictions) +
                       " rc_hit=" + std::to_string(rc_hit) +
                       " lookups=" + std::to_string(
                           measure_lookups_done.load(std::memory_order_relaxed)));
         }

         // Timeout or post-convergence cooldown
         if (elapsed_secs >= static_cast<double>(FLAGS_test_max_convergence_secs)) {
            print_info("[MONITOR] Timeout reached (" +
                       std::to_string(FLAGS_test_max_convergence_secs) + "s)");
            stop_flag.store(true, std::memory_order_release);
            break;
         }
         if (converged.load(std::memory_order_relaxed)) {
            double since_converge = elapsed_ms - converged_ms;
            if (since_converge >= static_cast<double>(FLAGS_test_post_converge_secs) * 1000.0) {
               print_info("[MONITOR] Post-convergence observation complete");
               stop_flag.store(true, std::memory_order_release);
               break;
            }
         }

         std::this_thread::sleep_for(
             std::chrono::milliseconds(FLAGS_test_monitor_interval_ms));
      }
   });

   // --- Worker threads: YCSB-C lookups until stop_flag ---
   const u64 thread_count = static_cast<u64>(FLAGS_worker_threads);
   for (u64 t_i = 0; t_i < thread_count; t_i++) {
      crm.scheduleJobAsync(t_i, [&, t_i]() {
         SplitMix64 rng(cfg.seed ^ 0xD1B54A32D192ED03ULL * (t_i + 1));
         while (!stop_flag.load(std::memory_order_relaxed)) {
            const auto rng_snapshot = rng;
            jumpmuTry() {
               const YCSBKey key = generator.next(rng);
               cr::Worker::my().startTX(TX_MODE::OLTP,
                                         TX_ISOLATION_LEVEL::SNAPSHOT_ISOLATION);
               table.lookup1({key}, [&](const YCSBTable&) {});
               cr::Worker::my().commitTX();
               measure_lookups_done.fetch_add(1, std::memory_order_relaxed);
            }
            jumpmuCatch() {
               rng = rng_snapshot;
            }
         }
      });
   }

   crm.joinAll();
   monitor_thread.join();

   const double phase3_secs = std::chrono::duration<double>(
       std::chrono::high_resolution_clock::now() - phase3_t0).count();
   const u64 total_lookups = measure_lookups_done.load();

   // ============================================================================
   // Write CSV
   // ============================================================================
   {
      std::ofstream csv(FLAGS_test_convergence_csv);
      csv << "elapsed_ms,slab_usage_pct,active_entries,logical_capacity,"
             "fill_ratio_pct,sieve_evictions,rc_hit,cxl_hit,ssd_miss\n";
      csv << std::fixed << std::setprecision(2);
      for (const auto& s : timeline) {
         csv << s.elapsed_ms << ","
             << s.slab_usage_pct << ","
             << s.active_entries << ","
             << s.logical_capacity << ","
             << s.fill_ratio_pct << ","
             << s.sieve_evictions << ","
             << s.rc_hit << ","
             << s.cxl_hit << ","
             << s.ssd_miss << "\n";
      }
      print_info("Timeline CSV written to: " + FLAGS_test_convergence_csv +
                 " (" + std::to_string(timeline.size()) + " samples)");
   }

   // ============================================================================
   // Final Summary
   // ============================================================================
   print_phase("Exp6 Summary");

   if (first_watermark_ms >= 0) {
      std::cout << "TIME_TO_WATERMARK_MS=" << std::fixed << std::setprecision(1)
                << first_watermark_ms << std::endl;
   } else {
      std::cout << "TIME_TO_WATERMARK_MS=TIMEOUT" << std::endl;
   }

   if (converged_ms >= 0) {
      std::cout << "CONVERGED_MS=" << std::fixed << std::setprecision(1)
                << converged_ms << std::endl;
   } else {
      std::cout << "CONVERGED_MS=TIMEOUT" << std::endl;
   }

   print_info("phase3_elapsed    = " + std::to_string(phase3_secs) + " s");
   print_info("total_lookups     = " + std::to_string(total_lookups));
   print_info("throughput        = " + std::to_string(total_lookups / phase3_secs / 1e6) + " Mqps");
   print_info("dram_bp_gib       = " + std::to_string(FLAGS_dram_buffer_pool_gib));
   print_info("dram_rc_gib       = " + std::to_string(FLAGS_dram_recordcache_gib));
   print_info("cxl_gib           = " + std::to_string(FLAGS_cxl_gib));

   if (!timeline.empty()) {
      const auto& last = timeline.back();
      print_info("final_slab_usage  = " + std::to_string(last.slab_usage_pct) + "%");
      print_info("final_entries     = " + std::to_string(last.active_entries));
      print_info("final_sieve       = " + std::to_string(last.sieve_evictions));
   }

   print_pass("Exp6 convergence test finished.");
   return 0;
}
