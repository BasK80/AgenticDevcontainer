# Extending auditing beyond network egress

This container ships with **one** audit log out of the box: every proxied
network request (allowed and denied) is recorded to a SQLite database in the
`firewall` container, on a dedicated `auditlog` volume the dev container cannot
reach. That covers *egress* — see the [Audit log](../README.md#audit-log)
section and [security.md](security.md) — and if network history is all you
need, **you are already done; do not re-implement it.**

This page is for the next question: **how do you audit what an agent *does*
inside the container — the commands and processes it executes — and keep that
record outside the container's control?** It describes two valid approaches
(`auditd`/`laurel` and eBPF/tetragon), the pipeline they share with the
existing egress log, the shared-kernel constraint that decides between them, and
a short note on filesystem auditing.

> **Status: design guidance, not a shipped feature.** None of this is wired
> into the default `docker-compose.yml`. The configuration blocks below are
> **illustrative skeletons** — correct in shape, but **not validated** on your
> kernel. A "tamper-proof audit log" that silently fails open is worse than no
> audit log, because it manufactures false confidence. **Verify any of this
> end-to-end before relying on it as a security control.**

---

## Why kernel-level, not a shell hook

The obvious approach — a `zsh` `preexec` hook or `$HISTFILE` that records each
command — **does not meet the bar** for this container. The threat model is *a
misbehaving or compromised agent running as `devuser`*. Anything that runs
inside `development` as `devuser` (a shell hook, a `PROMPT_COMMAND`, the
`/commandhistory` volume) can be unset, edited, or simply bypassed by invoking
a binary directly instead of typing it at the interactive shell. It is
*tamper-evident at best*, and the requirement here is **"cannot be disabled
from inside the container."**

Only a **kernel-level** mechanism satisfies that. Containers share the host
kernel; a process-execution record produced by the kernel and owned by a
*separate, privileged* collector cannot be turned off by a non-root user inside
`development`. Both approaches below are kernel-level for that reason.

A note on cost, because it reframes the whole decision: for this container's
usage pattern (an agent working at human pace — tens to low-hundreds of
commands per minute), the **runtime/latency cost of kernel exec-auditing is
negligible** — low microseconds per `execve` for the audit subsystem,
sub-microsecond for eBPF. You will not feel it. The real cost is **noise and
storage**: an unfiltered exec rule captures *every* binary the system runs
(compilers, `git`'s internal subprocesses, toolchains shelling out), which is
tens of thousands of events for a single large build. Plan for filtering and
retention, not for slowdowns.

---

## Security caveats (read this first)

Auditing *is* a security control, so the failure modes matter as much as the
happy path. This repo is deliberately blunt about residual risk elsewhere ("the
firewall narrows the exfil channel; it does not close it") and this is no
different.

- **The collector and its storage must be unreachable from `development`.**
  This is the entire point. The audit sidecar gets the capabilities and the
  audit volume; `development` gets *neither*. In particular, **do not mount the
  audit volume into `development`** (unlike the workspace, which is shared
  read-write). If the agent can write to the log, it is not an audit log. Model
  it on the existing `auditlog` volume: mounted into `firewall`/`control`,
  never into `development`.

- **Elevated capabilities are a trust shift, not a free lunch.** The collector
  needs privileges `development` is specifically denied: `CAP_AUDIT_CONTROL` /
  `CAP_AUDIT_READ` for `auditd`, or `CAP_BPF` + `CAP_PERFMON` (often effectively
  `privileged`, plus access to `/sys/kernel/btf`) for eBPF. That sidecar
  becomes a high-value target and a new entry in your trusted computing base.
  Run **only trusted, pinned code** in it — it is the one place in this design
  with more power than the dev container.

- **Tamper-*resistant* is not tamper-*proof*.** Two concrete escape hatches to
  monitor:
  - *Backlog flooding.* An agent that spawns processes in a tight loop can
    overrun the audit backlog and force **dropped records** (or system
    slowdown), depending on your `--backlog` / failure-mode settings. Decide
    explicitly whether the failure mode is "drop" or "block," and alert on
    drops.
  - *Kernel skew.* An eBPF probe built against one kernel can **silently stop
    matching** after a kernel update. A probe that loads but no longer fires
    looks healthy while recording nothing. Pin versions and add a liveness check
    that asserts events are actually flowing.

- **Attribution across projects.** On a shared kernel, a naive collector sees
  execs from *every* container, not just this project's `development`. You must
  filter by the target container's cgroup/PID namespace or you will mis-attribute
  (or leak) activity between projects. This is the crux of the WSL2 section
  below.

---

## The pipeline (mirror the egress log)

Whichever capture mechanism you choose, the *shape* of a trustworthy audit log
is already established in this repo by the egress log. Reuse it rather than
inventing a new one:

| Stage | Egress log (shipped) | Process-exec audit (this doc) |
|---|---|---|
| **Capture** | Squid writes `access.log` | Kernel emits `execve` events |
| **Ship out-of-band** | a tailer reads the log in `firewall` | a collector in a **privileged sidecar** reads the event stream |
| **Store tamper-resistant** | [`auditlog.py`](../.devcontainer/firewall/auditlog.py) → SQLite on the `auditlog` volume | same: tail the events → SQLite on a **new** `execaudit` volume `development` can't mount |
| **Query** | `fw audit` CLI + dashboard card | a parallel CLI/endpoint over the new DB |

The key reuse: [`.devcontainer/firewall/auditlog.py`](../.devcontainer/firewall/auditlog.py)
is a complete, dependency-free template for the **store + query** stages — it
tails a text log, parses each line into rows, writes them to SQLite with a
persisted cursor (so restarts never double-import), prunes on a retention
window, and exposes a `query` subcommand. Point an equivalent at your audit
event stream and you have the back half of the pipeline for free. Add a new
volume alongside the existing ones in `docker-compose.yml`:

```yaml
# docker-compose.yml — ILLUSTRATIVE, verify before use
volumes:
  execaudit:
    name: claude-${LOCAL_WORKSPACE_FOLDER_BASENAME}-execaudit
```

…mounted into the audit sidecar (and read-only into `control` if you want it on
the dashboard), and **never** into `development`.

---

## The shared-kernel constraint (decides which approach fits)

This is the pivotal fact, and it is easy to discover only at runtime. All three
supported host environments — **WSL2**, **macOS (Docker Desktop)**, and **native
Linux** — share the same fundamental property: Docker containers share a single
Linux kernel (the WSL2 or Docker Desktop VM kernel on Windows and macOS; the
host kernel on Linux). That kernel must have the audit and BPF subsystems
compiled in (`CONFIG_AUDITSYSCALL=y`, `CONFIG_BPF_SYSCALL=y`, BTF present at
`/sys/kernel/btf/vmlinux`) for either approach to work — verify this on your
kernel before committing to either path.

> **The Linux audit subsystem is one global facility per kernel.** There is
> effectively a single audit netlink, and audit rules are kernel-wide. All
> containers and (on WSL2) all distros on the same host share *one* kernel — and
> therefore one audit facility.

That collides head-on with this repo's core invariant — **everything is
per-project and isolated** (`claude-<project>-firewall`, per-project volumes, no
cross-project bleed). You **cannot** run N independent per-project `auditd`
sidecars each owning `execve` rules: they contend for the one audit netlink
(only one holds it), and each would observe *every* project's execs, not just
its own.

The two approaches resolve this differently, and that — more than features — is
how you choose:

- **The `auditd` approach** is the standard, canonical tool, but its one-daemon-per-kernel
  nature means it does **not** fit the per-project sidecar model on a shared
  kernel. Use it when you run **one project at a time**, or when you accept a
  **single host-level audit daemon** that fans out by cgroup to per-project
  storage (host-side setup, stepping outside the self-contained compose).
- **The eBPF / tetragon approach** does **not** have this restriction: multiple BPF
  programs coexist, and a probe can filter to one container's cgroup *in the
  kernel*. This is the **only** option that preserves the clean per-project
  sidecar pattern *and* lets several projects audit simultaneously.

---

## Approach 1 — `auditd` + `laurel`

The canonical Linux answer. The kernel audit subsystem records `execve`; a
userspace daemon drains and stores it. Raw `auditd` output is famously
awkward to query, so pair it with **`laurel`** (or `go-audit`), drop-in
userspace consumers that emit clean, enriched **JSON** instead.

**Pipeline.** A privileged sidecar loads `execve` audit rules, `laurel`
transforms the event stream to JSON, and an `auditlog.py`-style tailer lands it
in SQLite on the `execaudit` volume.

**Illustrative rules** (`auditctl` syntax; load via `audit.rules`):

```bash
# ILLUSTRATIVE — every execve, tagged for easy filtering
-a always,exit -F arch=b64 -S execve -F key=exec
-a always,exit -F arch=b32 -S execve -F key=exec
# scope to the agent's UID to cut noise (devuser = 1000)
-a always,exit -F arch=b64 -S execve -F uid=1000 -F key=agent_exec
```

**Illustrative sidecar** (per-project form shown; see the shared-kernel caveat above — on a
shared kernel this realistically becomes a *single* host-level daemon, not one
per project):

```yaml
# docker-compose.yml — ILLUSTRATIVE, verify before use
audit:
  build: ./audit            # auditd + laurel + an auditlog.py-style tailer
  container_name: claude-${LOCAL_WORKSPACE_FOLDER_BASENAME}-audit
  cap_add: [AUDIT_CONTROL, AUDIT_READ]
  pid: "host"               # to resolve/attribute PIDs to the right container
  networks: [egress]        # NOT on internal — unreachable from development
  volumes:
    - "execaudit:/auditlog" # the same out-of-band storage pattern
  restart: unless-stopped
```

**Choose `auditd` when:** you want the standard, well-documented, broadly-understood
tool; your auditors expect `auditd`; you run **one project at a time** or are
willing to operate a **single shared host-level** audit daemon; and you value
maturity over per-project tidiness.

**Costs:** does not fit the per-project model on a shared kernel; raw output
needs `laurel` to be usable; backlog tuning matters under heavy build loads.

---

## Approach 2 — eBPF / tetragon

A modern, in-kernel approach: attach a probe to the process-exec tracepoint
(`sched_process_exec`), filter and enrich **in the kernel**, and stream
structured events to userspace. [Tetragon](https://tetragon.io/) is a
batteries-included implementation; a small purpose-built CO-RE probe is the
lighter-weight alternative. BTF is present on this kernel, so CO-RE portability
works without shipping kernel headers.

**Pipeline.** A privileged sidecar attaches the probe, filters to the
`development` container's cgroup, and emits JSON that an `auditlog.py`-style
tailer lands in SQLite on the `execaudit` volume.

**Illustrative policy** (tetragon `TracingPolicy` sketch):

```yaml
# tetragon TracingPolicy — ILLUSTRATIVE, verify before use
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: audit-execve
spec:
  tracepoints:
    - subsystem: sched
      event: sched_process_exec
      # filter to development's cgroup so other projects aren't captured
```

**Illustrative sidecar:**

```yaml
# docker-compose.yml — ILLUSTRATIVE, verify before use
audit:
  image: quay.io/cilium/tetragon:latest   # pin a digest in practice
  container_name: claude-${LOCAL_WORKSPACE_FOLDER_BASENAME}-audit
  privileged: true            # or CAP_BPF + CAP_PERFMON, kernel-dependent
  pid: "host"
  networks: [egress]          # NOT on internal — unreachable from development
  volumes:
    - "/sys/kernel/btf:/sys/kernel/btf:ro"
    - "execaudit:/auditlog"
  restart: unless-stopped
```

**Choose eBPF / tetragon when:** you run **multiple projects simultaneously** and want to keep
the clean per-project sidecar model; you want richer context for free (full
process ancestry, parent PID, container attribution); and lower per-event
overhead matters under heavy workloads.

**Costs:** heavier image and broader capabilities (a bigger trusted sidecar);
**kernel-skew fragility** — any kernel update can silently break a probe, so
pin versions and add a liveness check that confirms events are flowing.

---

## `auditd` vs eBPF at a glance

| | **`auditd` / `laurel`** | **eBPF / tetragon** |
|---|---|---|
| Maturity / familiarity | Highest (the standard) | Newer, growing fast |
| Fits per-project model on shared kernel | **No** (one netlink/kernel) | **Yes** (probes coexist) |
| Multiple projects at once | One-at-a-time, or host-level daemon | Yes |
| Output quality | Raw is awkward; needs `laurel` for JSON | Structured + enriched natively |
| Per-event overhead | Low (µs) | Lower (sub-µs) |
| Privileges on sidecar | `CAP_AUDIT_CONTROL`/`READ` | `CAP_BPF`+`CAP_PERFMON` / privileged |
| Main risk | Doesn't suit per-project on shared kernel | Kernel-skew silently breaks the probe |

**Default recommendation for *this* repo:** **eBPF / tetragon**, because it is the only
option that preserves the per-project-isolation invariant the whole design rests
on — regardless of host platform — while still meeting "cannot be disabled from
inside the container." Reach for **`auditd`** when standardization/auditor
expectations dominate and you can live with one-project-at-a-time or a
host-level daemon.

---

## Filesystem auditing (forward-looking note)

Auditing *file* changes (not just process execution) is a natural next step and
slots into the **same out-of-band pipeline** — capture in a privileged sidecar,
store on a `development`-unreachable volume, query alongside the rest. The
capture options mirror the above:

- **`auditd` watch rules** — `-w /workspace -p wa -k fschange` records writes and
  attribute changes to a path. Same one-netlink-per-kernel constraint as the
  `auditd` approach above.
- **`fanotify` / `inotify`** — a userspace watcher on a mount or directory tree.
  `fanotify` can observe at the mount level; `inotify` is per-directory and
  doesn't recurse automatically.
- **eBPF VFS hooks** — the structured-events analogue, attaching to VFS
  operations; coexists like the eBPF approach above.

**The hard part is not capture — it is signal-to-noise.** A single build or test
run touches *thousands* of files (object files, caches, temp dirs), so an
unfiltered filesystem audit is far noisier than exec auditing and demands
aggressive path scoping and retention to stay useful. This is the same reason
exec auditing's real cost is "noise, not latency" — amplified. Treat it as a
deliberate, separately-scoped effort rather than a flag you flip on.

---

## Intentionally not covered

- **Re-auditing network egress** — already shipped; see the
  [Audit log](../README.md#audit-log) section.
- **Turn-key configs** — by design. The blocks above are skeletons to adapt and
  verify on your kernel, not validated drop-ins (see the status note at the top).
- **Host-extension / VS Code trust boundary** — a different surface, covered in
  [security.md](security.md).
