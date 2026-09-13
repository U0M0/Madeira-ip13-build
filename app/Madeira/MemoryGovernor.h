// Process-wide, conservative memory policy for Madeira on iPhone 13.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum madeira_memory_state {
    MADEIRA_MEMORY_NORMAL = 0,
    MADEIRA_MEMORY_WATCH,
    MADEIRA_MEMORY_WARNING,
    MADEIRA_MEMORY_PRESSURE,
    MADEIRA_MEMORY_CRITICAL,
} madeira_memory_state_t;

typedef struct madeira_memory_sample {
    uint64_t phys_footprint;
    uint64_t resident_size;
    uint64_t ios_available;
    uint64_t estimated_ios_limit;
    madeira_memory_state_t state;
} madeira_memory_sample_t;

typedef void (*madeira_memory_reclaim_callback_t)(madeira_memory_state_t state, void *context);

void madeira_memory_governor_start(void);
void madeira_memory_governor_stop(void);
madeira_memory_sample_t madeira_memory_governor_sample(void);
// Cached values from the governor's sampler. These do not trigger reclaim work and
// are intended for lightweight UI/telemetry reads from Swift.
uint64_t madeira_memory_governor_current_footprint(void);
uint64_t madeira_memory_governor_current_available(void);
uint64_t madeira_memory_governor_current_limit(void);
bool madeira_memory_governor_register_reclaimer(madeira_memory_reclaim_callback_t callback,
                                                void *context);
// Admission check for optional/large allocations. It never replaces normal error checks.
bool madeira_memory_governor_admit_allocation(size_t bytes, const char *owner);

#ifdef __cplusplus
}
#endif
