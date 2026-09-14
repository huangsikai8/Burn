#ifndef CPROC_H
#define CPROC_H

#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>

// proc_pidinfo flavor that returns a process's coalition ids. Not in the public
// headers; this is what `top` and Activity Monitor use.
#define BURN_PROC_PIDCOALITIONINFO 20
#define BURN_COALITION_TYPE_RESOURCE 0
#define BURN_COALITION_TYPE_JETSAM 1

struct burn_coalition_ids {
    uint64_t coalition_id[2];   // [resource, jetsam]
    uint64_t reserved1;
    uint64_t reserved2;
    uint64_t reserved3;
};

// Mirrors XNU's struct coalition_resource_usage. Field order verified on
// macOS 26.5 against live per-process sums. The tail is padding so a newer
// kernel that appends fields can't write past the buffer.
struct burn_coalition_usage {
    uint64_t tasks_started;
    uint64_t tasks_exited;
    uint64_t time_nonempty;
    uint64_t cpu_time;                  // mach absolute time units
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;
    uint64_t byteswritten;
    uint64_t gpu_time;
    uint64_t cpu_time_billed_to_me;
    uint64_t cpu_time_billed_to_others;
    uint64_t energy;                    // nanojoules
    uint64_t logical_immediate_writes;
    uint64_t logical_deferred_writes;
    uint64_t logical_invalidated_writes;
    uint64_t logical_metadata_writes;
    uint64_t logical_immediate_writes_to_external;
    uint64_t logical_deferred_writes_to_external;
    uint64_t logical_invalidated_writes_to_external;
    uint64_t logical_metadata_writes_to_external;
    uint64_t energy_billed_to_me;
    uint64_t energy_billed_to_others;
    uint64_t cpu_ptime;
    uint64_t cpu_time_eqos_len;
    uint64_t cpu_time_eqos[7];
    uint64_t cpu_instructions;
    uint64_t cpu_cycles;
    uint64_t fs_metadata_writes;
    uint64_t pm_writes;
    uint64_t cpu_pinstructions;
    uint64_t cpu_pcycles;
    uint64_t conclave_mem;
    uint64_t ane_mach_time;
    uint64_t ane_energy_nj;
    uint64_t padding[24];
};

// Returns 1 and fills both ids on success, 0 if the process is gone.
int burn_coalition_ids_for_pid(pid_t pid, uint64_t *resource, uint64_t *jetsam);

// Returns 1 on success. Totals include tasks that have already exited.
int burn_coalition_usage(uint64_t coalition_id, struct burn_coalition_usage *out);

// The process that launchd charges this one to (Safari for WebContent, etc.).
// Returns -1 when unknown, which is normal for root-owned processes.
pid_t burn_responsible_pid(pid_t pid);

// Cumulative traffic across physical interfaces (en*, pdp_ip*). Tunnels and
// loopback are skipped so VPN traffic isn't counted twice. Returns 1 on success.
int burn_network_totals(uint64_t *bytes_in, uint64_t *bytes_out,
                        uint64_t *packets_in, uint64_t *packets_out);

#endif
