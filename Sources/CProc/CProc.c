#include "CProc.h"
#include <libproc.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/route.h>

extern int coalition_info_resource_usage(uint64_t cid, struct burn_coalition_usage *cru, size_t sz);
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

int burn_coalition_ids_for_pid(pid_t pid, uint64_t *resource, uint64_t *jetsam) {
    struct burn_coalition_ids ids;
    memset(&ids, 0, sizeof ids);
    if (proc_pidinfo(pid, BURN_PROC_PIDCOALITIONINFO, 0, &ids, sizeof ids) <= 0) return 0;
    *resource = ids.coalition_id[BURN_COALITION_TYPE_RESOURCE];
    *jetsam = ids.coalition_id[BURN_COALITION_TYPE_JETSAM];
    return 1;
}

int burn_coalition_usage(uint64_t coalition_id, struct burn_coalition_usage *out) {
    memset(out, 0, sizeof *out);
    return coalition_info_resource_usage(coalition_id, out, sizeof *out) == 0;
}

pid_t burn_responsible_pid(pid_t pid) {
    return responsibility_get_pid_responsible_for_pid(pid);
}

int burn_network_totals(uint64_t *bytes_in, uint64_t *bytes_out,
                        uint64_t *packets_in, uint64_t *packets_out) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) return 0;
    char *buf = malloc(len);
    if (!buf) return 0;
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) { free(buf); return 0; }

    uint64_t ib = 0, ob = 0, ip = 0, op = 0;
    char name[IF_NAMESIZE];
    for (char *next = buf; next < buf + len;) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        if (ifm->ifm_msglen == 0) break;
        next += ifm->ifm_msglen;
        if (ifm->ifm_type != RTM_IFINFO2) continue;
        struct if_msghdr2 *if2 = (struct if_msghdr2 *)ifm;
        if (if2->ifm_flags & IFF_LOOPBACK) continue;
        if (!if_indextoname(if2->ifm_index, name)) continue;
        if (strncmp(name, "en", 2) != 0 && strncmp(name, "pdp_ip", 6) != 0) continue;
        ib += if2->ifm_data.ifi_ibytes;
        ob += if2->ifm_data.ifi_obytes;
        ip += if2->ifm_data.ifi_ipackets;
        op += if2->ifm_data.ifi_opackets;
    }
    free(buf);
    *bytes_in = ib; *bytes_out = ob; *packets_in = ip; *packets_out = op;
    return 1;
}
