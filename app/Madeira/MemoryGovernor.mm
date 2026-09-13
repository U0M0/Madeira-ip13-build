// Process-wide memory governor. Uses iOS's dynamic app envelope, never a presumed RAM size.
#import "MemoryGovernor.h"

#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <os/lock.h>
#import <os/log.h>
#import <os/proc.h>
#include <stdatomic.h>

static const uint64_t MiB = 1024ULL * 1024ULL;
// Conservative for iPhone 13. Keep headroom below an approximately 2 GiB jetsam point.
static const uint64_t kWatchFootprint    = 1400ULL * MiB;
static const uint64_t kWarningFootprint  = 1520ULL * MiB;
static const uint64_t kPressureFootprint = 1620ULL * MiB;
static const uint64_t kCriticalFootprint = 1720ULL * MiB;
static const uint64_t kAdmissionCeiling  = 1800ULL * MiB;
static const uint64_t kSystemReserve     = 128ULL * MiB;
enum { kMaxReclaimers = 16 };

typedef struct { madeira_memory_reclaim_callback_t callback; void *context; } reclaimer_t;
static reclaimer_t g_reclaimers[kMaxReclaimers];
static _Atomic uint32_t g_reclaimer_count = 0;
static os_unfair_lock g_reclaimer_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic bool g_started = false;
static _Atomic uint64_t g_footprint = 0, g_resident = 0, g_available = 0, g_limit = 0;
static _Atomic int g_state = MADEIRA_MEMORY_NORMAL;
static dispatch_queue_t g_queue;
static dispatch_source_t g_timer, g_pressure;

static os_log_t memory_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.madeira.emulator", "memory"); });
    return log;
}

static madeira_memory_state_t state_for(uint64_t footprint, uint64_t available) {
    madeira_memory_state_t state = MADEIRA_MEMORY_NORMAL;
    if (footprint >= kWatchFootprint) state = MADEIRA_MEMORY_WATCH;
    if (footprint >= kWarningFootprint) state = MADEIRA_MEMORY_WARNING;
    if (footprint >= kPressureFootprint) state = MADEIRA_MEMORY_PRESSURE;
    if (footprint >= kCriticalFootprint) state = MADEIRA_MEMORY_CRITICAL;
    // A reported zero is not "no memory": it means unavailable or already over limit.
    if (available && available <= 384ULL * MiB && state < MADEIRA_MEMORY_WARNING) state = MADEIRA_MEMORY_WARNING;
    if (available && available <= 256ULL * MiB && state < MADEIRA_MEMORY_PRESSURE) state = MADEIRA_MEMORY_PRESSURE;
    if (available && available <= 160ULL * MiB) state = MADEIRA_MEMORY_CRITICAL;
    return state;
}

static void reclaim(madeira_memory_state_t state) {
    reclaimer_t local[kMaxReclaimers];
    os_unfair_lock_lock(&g_reclaimer_lock);
    uint32_t count = atomic_load_explicit(&g_reclaimer_count, memory_order_acquire);
    for (uint32_t i = 0; i < count; ++i) local[i] = g_reclaimers[i];
    os_unfair_lock_unlock(&g_reclaimer_lock);
    for (uint32_t i = 0; i < count; ++i) local[i].callback(state, local[i].context);
}

static void sample_and_apply(void) {
    task_vm_info_data_t vm = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) return;
    uint64_t footprint = vm.phys_footprint;
    uint64_t available = os_proc_available_memory();
    madeira_memory_state_t next = state_for(footprint, available);
    madeira_memory_state_t previous = (madeira_memory_state_t)atomic_exchange(&g_state, next);
    atomic_store(&g_footprint, footprint);
    atomic_store(&g_resident, vm.resident_size);
    atomic_store(&g_available, available);
    atomic_store(&g_limit, available ? footprint + available : 0);
    if (next > previous) {
        os_log(memory_log(), "state %{public}d -> %{public}d; footprint=%{public}.1f MiB, available=%{public}.1f MiB",
               previous, next, (double)footprint / MiB, (double)available / MiB);
        reclaim(next);
    }
}

void madeira_memory_governor_start(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_started, &expected, true)) return;
    g_queue = dispatch_queue_create("com.madeira.emulator.memory", DISPATCH_QUEUE_SERIAL);
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_queue);
    dispatch_source_set_timer(g_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(g_timer, ^{ sample_and_apply(); });
    dispatch_resume(g_timer);
    g_pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, g_queue);
    dispatch_source_set_event_handler(g_pressure, ^{
        unsigned long flags = dispatch_source_get_data(g_pressure);
        sample_and_apply();
        if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) reclaim(MADEIRA_MEMORY_CRITICAL);
        else if (flags & DISPATCH_MEMORYPRESSURE_WARN) reclaim(MADEIRA_MEMORY_PRESSURE);
    });
    dispatch_resume(g_pressure);
    sample_and_apply();
}

void madeira_memory_governor_stop(void) {
    if (!atomic_exchange(&g_started, false)) return;
    if (g_timer) { dispatch_source_cancel(g_timer); g_timer = nil; }
    if (g_pressure) { dispatch_source_cancel(g_pressure); g_pressure = nil; }
}

madeira_memory_sample_t madeira_memory_governor_sample(void) {
    sample_and_apply();
    return (madeira_memory_sample_t){ atomic_load(&g_footprint), atomic_load(&g_resident),
        atomic_load(&g_available), atomic_load(&g_limit), (madeira_memory_state_t)atomic_load(&g_state) };
}

uint64_t madeira_memory_governor_current_footprint(void) {
    return atomic_load_explicit(&g_footprint, memory_order_relaxed);
}

uint64_t madeira_memory_governor_current_available(void) {
    return atomic_load_explicit(&g_available, memory_order_relaxed);
}

uint64_t madeira_memory_governor_current_limit(void) {
    return atomic_load_explicit(&g_limit, memory_order_relaxed);
}

bool madeira_memory_governor_register_reclaimer(madeira_memory_reclaim_callback_t callback, void *context) {
    if (!callback) return false;
    os_unfair_lock_lock(&g_reclaimer_lock);
    uint32_t slot = atomic_load_explicit(&g_reclaimer_count, memory_order_relaxed);
    if (slot >= kMaxReclaimers) { os_unfair_lock_unlock(&g_reclaimer_lock); return false; }
    g_reclaimers[slot] = (reclaimer_t){ callback, context };
    atomic_store_explicit(&g_reclaimer_count, slot + 1, memory_order_release);
    os_unfair_lock_unlock(&g_reclaimer_lock);
    return true;
}

bool madeira_memory_governor_admit_allocation(size_t bytes, const char *owner) {
    madeira_memory_sample_t s = madeira_memory_governor_sample();
    bool exceeds_ceiling = s.phys_footprint + bytes > kAdmissionCeiling;
    bool consumes_reserve = s.ios_available && bytes + kSystemReserve > s.ios_available;
    if (!exceeds_ceiling && !consumes_reserve) return true;
    os_log(memory_log(), "reject %{public}s allocation: request=%{public}.1f MiB, footprint=%{public}.1f MiB, available=%{public}.1f MiB",
           owner ?: "unknown", (double)bytes / MiB, (double)s.phys_footprint / MiB, (double)s.ios_available / MiB);
    reclaim(MADEIRA_MEMORY_CRITICAL);
    return false;
}
