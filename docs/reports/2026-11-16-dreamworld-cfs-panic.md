# Dreamworld v1.5_fixed_1: CFS leaf-list double insert causes kernel panic

Date: 2026-11-16  
Device: OnePlus 8T `KB2000` (`kebab`, SM8250)  
System: Android 16 / LineageOS 23.2  
Root: Magisk 31.1  
Active slot: `_a`  
Kernel: `4.19.325-cip136-st20-dreamworld-g6b0bc47938b0`  
Dreamworld release: `v1.5_fixed_1` (commit `6b0bc47938b0`, built 2026-10-18)  
Upstream issue: https://github.com/JackA1ltman/dreamworld_oneplus_sm8250/issues/5

## Summary

`propagate_entity_cfs_rq()` re-inserted an already linked `cfs_rq` into the
CFS leaf list during task migration/wakeup. The kernel detected
`list_add double add`, hit `BUG` in `lib/list_debug.c`, and panicked.

`dumpsys` is the process in the panic header, but it is not the source of the
corruption. It entered `try_to_wake_up()` through `pipe_write()` and was the
first thread to perform the invalid list insertion after the list had already
been corrupted.

## Call path

```text
dumpsys
  write(pipe)
    pipe_write
      __wake_up_sync_key
        __wake_up_common
          try_to_wake_up
            set_task_cpu
              migrate_task_rq_fair
                detach_entity_cfs_rq
                  propagate_entity_cfs_rq
                    list_add_leaf_cfs_rq
                      __list_add_valid
                        list_add double add
                          kernel BUG at lib/list_debug.c:35
                            Kernel panic - not syncing: Fatal exception
```

This path identifies where the corruption was detected, not which earlier
operation corrupted the leaf list.

## Panic evidence

Source: device `/metadata/panic.txt`, not committed to the repository.

```text
list_add double add: new=ffffffd2b23a6c00, prev=ffffffd2b23a6c00, next=ffffffd2b23a73e8.
kernel BUG at lib/list_debug.c:35!
Internal error: Oops - BUG: 0 [#1] PREEMPT SMP
Process dumpsys (pid: 7871, stack limit = 0x0000000097de74a5)
CPU: 5 PID: 7871 Comm: dumpsys
Tainted: G S      W
4.19.325-cip136-st20-dreamworld-g6b0bc47938b0 #1

Call trace:
 __list_add_valid+0x68/0xb8
 propagate_entity_cfs_rq+0xb4/0x738
 detach_entity_cfs_rq+0x354/0x538
 migrate_task_rq_fair+0x98/0xb4
 set_task_cpu+0xb4/0x20c
 try_to_wake_up+0x2f0/0x564
 autoremove_wake_function+0x24/0x68
 __wake_up_common+0xc0/0x140
 __wake_up_common_lock+0x78/0xcc
 __wake_up_sync_key+0x20/0x2c
 pipe_write+0x168/0x478
 __vfs_write+0x130/0x15c
 vfs_write+0xe4/0x1a4
 ksys_write+0x70/0xd8
 __arm64_sys_write+0x1c/0x28
 el0_svc_common+0x9c/0x168
 el0_svc_handler+0x24/0x8c
 el0_svc+0x8/0x2c0
Kernel panic - not syncing: Fatal exception
```

## Concurrent context

Around the panic, the same log segment contains:

- repeated `[ds-monitor]` accesses to
  `/sys/fs/cgroup/droidspaces/debian`, `/proc/<pid>/stat`, and
  `cgroup.controllers`;
- `systemd-udevd` activity under `u:r:droidspacesd:s0`;
- repeated `busybox` and `magiskd` zombie-process messages;
- `audit_lost` and `audit_rate_limit` messages, indicating that SELinux audit
  logging was already saturated.

This is context, not proof of causation. It shows that the panic happened
while the system was under concurrent container-monitor, process
creation/exit, and audit/log-write load. It does not establish which of those
events first corrupted the CFS leaf list.

## Configuration

Measured from `/proc/config.gz`:

```text
CONFIG_PID_NS is not set
CONFIG_USER_NS is not set
CONFIG_CFS_BANDWIDTH is not set
CONFIG_CGROUP_PIDS is not set
CONFIG_MEMCG_SWAP=y
CONFIG_CGROUP_FREEZER=y
CONFIG_NET_NS=y
CONFIG_OVERLAY_FS=y
CONFIG_FUSE_FS=y
```

These values are not direct evidence of this panic. They show that
`v1.5_fixed_1` does not match the Droidspaces-recommended container
configuration, which is relevant as environmental context for scheduler
analysis, not as the root cause.

## Explicitly excluded

- Power/battery: the device was at roughly 97% and charging; the gauge log
  reports `suspend = 0`.
- `dumpsys` user-space failure: `dumpsys` is the wakeup writer in the call
  path, not the source of the kernel list corruption.
- Hotspot-module loop: `hotspot_plus` only adds periodic `dumpsys wifi`
  wakeups. It is absent from the CFS call path and no evidence shows it
  modifies scheduler state.
- userdata filesystem: this partition uses `dm-default-key`; raw `fsck.f2fs`
  cannot determine its filesystem state. This issue does not involve storage.

## Minimal questions for the maintainer

1. Can `propagate_entity_cfs_rq()` call `list_add_leaf_cfs_rq()` twice for
   the same `cfs_rq` when `migrate_task_rq_fair()` races with
   `set_task_cpu()`?
2. Does Dreamworld carry out-of-tree CFS/scheduler patches? Which modules or
   patches correspond to `W` in `Tainted: G S W`?
3. Is there a post-`v1.5_fixed_1` fix for `list_add_leaf_cfs_rq()` /
   `propagate_entity_cfs_rq()`?
4. If this cannot be reproduced, can a diagnostic patch check whether
   `cfs_rq->leaf_cfs_rq_list` is already linked before insertion, and print
   the `cfs_rq`, task, CPU, and callers instead of raising `BUG`?

## Reproduction and attachments

This is not a deterministic reproduction; it is one panic with a complete
stack. The raw `/metadata/panic.txt`, metadata key, serial, MAC addresses, and
container credentials are not committed. Redacted excerpts can be provided to
the maintainer on request.

