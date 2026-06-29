#!/usr/bin/env bash
# =============================================================================
# sandbox-inspect.sh
# =============================================================================
# Inspects a Linux container/sandbox environment and produces a structured
# report covering:
#   1. Filesystem topology     - mounts, block devices, permissions
#   2. Process & security      - uid/gid, Linux capabilities, seccomp, namespaces
#   3. Network                 - interfaces, routing, DNS, iptables, proxy evidence
#   4. Processes               - process tree, CPU/memory, open FDs, listening ports
#   5. Runtime environment     - language runtimes, package managers, OS/CPU/kernel info
#   6. Tool availability - runtimes, document/PDF, OCR, media, browser, utilities
#
# Originally written for inspecting the Claude computer-use sandbox (Ubuntu 24),
# but works on any Linux system. Tested on: Ubuntu 20/22/24, Debian 12,
# Alpine 3.x (with busybox caveats noted inline).
#
# Usage:
#   chmod +x sandbox-inspect.sh
#   ./sandbox-inspect.sh                  # full report to stdout
#   ./sandbox-inspect.sh --no-color       # plain text (useful for piping)
#   ./sandbox-inspect.sh --section mounts # run only one section
#   ./sandbox-inspect.sh --out report.txt # write output to a file
#
# Exit codes:
#   0  - completed successfully (even if some sub-commands were unavailable)
#   1  - bad arguments
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURABLE DEFAULTS
# -----------------------------------------------------------------------------
: "${MAX_MOUNT_LINES:=200}"
: "${USE_COLOR:=auto}"   # auto | yes | no
: "${SECTIONS:=all}"
: "${OUTPUT_FILE:=}"
: "${VERBOSE:=false}"

# -----------------------------------------------------------------------------
# ARGUMENT PARSING
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --no-color            Disable ANSI colour codes
  --section SECTION     Run only this section: mounts | security | network | processes | runtime | tools
  --out FILE            Write output to FILE instead of stdout
  --verbose             Include raw /proc dumps
  -h, --help            Show this help

Environment variables (all have CLI equivalents above):
  MAX_MOUNT_LINES   Lines of /proc/mounts to show (default: 200, 0=all)
  USE_COLOR         auto | yes | no (default: auto)
  SECTIONS          Comma-separated list or "all" (default: all)
  OUTPUT_FILE       Path to write output (default: stdout)
  VERBOSE           true | false (default: false)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-color)   USE_COLOR=no;          shift ;;
        --section)    SECTIONS="${2:?--section requires a value}"; shift 2 ;;
        --out)        OUTPUT_FILE="${2:?--out requires a value}";  shift 2 ;;
        --verbose)    VERBOSE=true;          shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    exec > "$OUTPUT_FILE"
    echo "# Capturing output to: $OUTPUT_FILE" >&2
fi

# -----------------------------------------------------------------------------
# COLOUR HELPERS
# -----------------------------------------------------------------------------

setup_colors() {
    if [[ "$USE_COLOR" == "no" ]] || { [[ "$USE_COLOR" == "auto" ]] && ! [ -t 1 ]; }; then
        BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""; MAG=""; RST=""
        return
    fi
    BOLD=$(tput bold   2>/dev/null || echo "")
    DIM=$(tput dim    2>/dev/null || echo "")
    RED=$(tput setaf 1 2>/dev/null || echo "")
    GRN=$(tput setaf 2 2>/dev/null || echo "")
    YEL=$(tput setaf 3 2>/dev/null || echo "")
    BLU=$(tput setaf 4 2>/dev/null || echo "")
    MAG=$(tput setaf 5 2>/dev/null || echo "")
    CYN=$(tput setaf 6 2>/dev/null || echo "")
    RST=$(tput sgr0   2>/dev/null || echo "")
}

setup_colors

# Printing helpers
header()    { echo; echo "${BOLD}${BLU}----------------------------------------------------------${RST}"; \
              echo "${BOLD}${BLU}  $*${RST}"; \
              echo "${BOLD}${BLU}----------------------------------------------------------${RST}"; }
subheader() { echo; echo "${BOLD}${CYN}-- $* ${RST}"; }
info()      { echo "  ${GRN}-${RST} $*"; }
warn()      { echo "  ${YEL}⚠${RST}  $*"; }
label()     { printf "  ${BOLD}%-26s${RST} %s\n" "$1" "$2"; }
raw()       { echo "${DIM}$*${RST}"; }

# run_cmd LABEL COMMAND...
# Runs COMMAND, prints its output indented, gracefully handles missing tools.
run_cmd() {
    local lbl="$1"; shift
    subheader "$lbl"
    local bin="${1%% *}"
    if ! command -v "$bin" &>/dev/null 2>&1; then
        warn "  '$bin' not found - skipping"
        return 0
    fi
    local out
    if out=$("$@" 2>/dev/null); then
        [[ -z "$out" ]] && info "(no output)" || echo "$out" | sed 's/^/    /'
    else
        warn "Command returned non-zero: $*"
    fi
}

# should_run SECTION
# Returns 0 (true) if the given section should be executed.
should_run() {
    [[ "$SECTIONS" == "all" ]] || [[ ",$SECTIONS," == *",$1,"* ]]
}

mask_env_value() {
    local name="$1" value="$2"
    if echo "$name" | grep -qiE '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|API_|_API|PRIVATE|CERT_PASS|PAT\b)'; then
        echo "***REDACTED***"
        return
    fi
    echo "$value" | sed -E 's|([a-zA-Z][a-zA-Z0-9+.-]*://)([^/@]+:[^/@]+@)|\1***REDACTED***@|g'
}

# -----------------------------------------------------------------------------
# METADATA HEADER
# Always printed regardless of --section so the report is self-describing.
# -----------------------------------------------------------------------------

echo
echo "${BOLD}${MAG}╔----------------------------------------------------------=╗${RST}"
echo "${BOLD}${MAG}║          SANDBOX ENVIRONMENT INSPECTION REPORT            ║${RST}"
echo "${BOLD}${MAG}╚----------------------------------------------------------=╝${RST}"
echo
label "Generated at:"    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
label "Hostname:"        "$(hostname 2>/dev/null || echo '(unavailable)')"
label "Kernel:"          "$(uname -r 2>/dev/null || echo '(unavailable)')"
label "Script version:"  "1.1.0"
label "Running as:"      "$(id 2>/dev/null || echo '(unavailable)')"

# Read container metadata if the platform injects it.
# The Claude sandbox writes /container_info.json; other platforms may differ.
if [[ -f /container_info.json ]]; then
    label "Container info:" "$(cat /container_info.json)"
elif [[ -f /.dockerenv ]]; then
    label "Container info:" "(Docker container detected via /.dockerenv)"
elif [[ -f /run/.containerenv ]]; then
    label "Container info:" "(Podman container detected via /run/.containerenv)"
else
    label "Container info:" "(no container metadata file found)"
fi

# =============================================================================
# SECTION 1: FILESYSTEM & MOUNTS
# =============================================================================
if should_run mounts; then

header "SECTION 1 - FILESYSTEM & MOUNTS"

# -- 1a. Mount table ----------------------------------------------------------
# /proc/mounts is the authoritative source on Linux. It's the kernel's own
# view of what's mounted, updated in real time. It's more reliable than
# /etc/fstab (which describes what SHOULD be mounted at boot, not what IS).
#
# Column format: device  mountpoint  fstype  options  dump  pass
#
# We filter out pseudo-filesystems (proc, sysfs, cgroup, tmpfs, devtmpfs)
# that exist on virtually every Linux system and aren't interesting for
# understanding container-specific storage topology.
subheader "Full mount table (/proc/mounts)"
if [[ -r /proc/mounts ]]; then
    # Column headers for readability
    printf "    %-40s %-30s %-15s %s\n" "DEVICE" "MOUNTPOINT" "FSTYPE" "OPTIONS"
    printf "    %-40s %-30s %-15s %s\n" "$(printf '-%.0s' {1..40})" "$(printf '-%.0s' {1..30})" "$(printf '-%.0s' {1..15})" "$(printf '-%.0s' {1..30})"
    # Filter: skip pseudo-fs types we don't care about
    grep -vE '^(proc|sysfs|devpts|cgroup|tmpfs on /dev|devtmpfs|hugetlbfs|mqueue|pstore|bpf|tracefs|securityfs|debugfs|configfs|fusectl|autofs)' \
        /proc/mounts \
        | head -n "${MAX_MOUNT_LINES}" \
        | awk '{ printf "    %-40s %-30s %-15s %s\n", $1, $2, $3, $4 }'

    # Warn if we truncated the output
    total=$(wc -l < /proc/mounts)
    if [[ "${MAX_MOUNT_LINES}" -gt 0 && "$total" -gt "${MAX_MOUNT_LINES}" ]]; then
        warn "Output truncated at ${MAX_MOUNT_LINES} lines (total: ${total}). Set MAX_MOUNT_LINES=0 for all."
    fi
else
    warn "/proc/mounts not readable"
fi

# -- 1b. Interesting mounts only ---------------------------------------------
# Pull out just the mount types that tell you something about the container's
# storage design: rclone fuse mounts, squashfs (immutable images), overlay
# (Docker/OCI layers), nfs, cifs, etc.
subheader "Non-trivial mounts (rclone, squashfs, overlay, nfs, cifs, btrfs, zfs)"
if [[ -r /proc/mounts ]]; then
    found=$(grep -E 'fuse\.rclone|squashfs|overlay|nfs|cifs|btrfs|zfs' /proc/mounts || true)
    if [[ -n "$found" ]]; then
        echo "$found" | sed 's/^/    /'
    else
        info "(none found)"
    fi
fi

# -- 1b2. findmnt tree ---------------------------------------------------------
# findmnt shows the mount tree in a much more readable form than /proc/mounts.
# --real skips pseudo-filesystems; shows source, target, fstype, and options.
subheader "Mount tree (findmnt --real)"
if command -v findmnt &>/dev/null; then
    findmnt --real -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | head -40 | sed 's/^/    /' \
        || warn "findmnt failed"
else
    warn "findmnt not found (util-linux package)"
fi

# -- 1c. Block devices --------------------------------------------------------
# lsblk gives a tree view of all block devices and their mount points.
# Useful for understanding how many virtual disks are attached and what
# filesystem each carries. In a cloud VM or container you'll typically see
# vda (root), vdb, vdc ... (attached volumes).
run_cmd "Block devices (lsblk)" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,RO

# blkid shows UUID and filesystem type per device -- useful to confirm what's
# actually formatted on each block device vs what's just a raw partition.
subheader "Block device UUIDs (blkid)"
if command -v blkid &>/dev/null; then
    blkid 2>/dev/null | sed 's/^/    /' || warn "blkid failed (may need root)"
else
    warn "blkid not found"
fi

# -- 1d. Disk usage -----------------------------------------------------------
# df -h shows how much space is used on each mounted filesystem.
# The -x flags exclude pseudo-filesystems that inflate the output.
subheader "Disk usage (df -h, real filesystems only)"
df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/    /' || warn "df failed"

# -- 1e. Writable-path check --------------------------------------------------
# Explicitly test write access on paths that matter for tool use.
# This catches cases where a path is owned by root but the filesystem is
# mounted read-only at the VFS layer (the kernel returns EROFS regardless
# of POSIX permissions in that case).
subheader "Write-access test on key paths"
PATHS_TO_CHECK=(
    /home/claude
    /mnt/user-data/outputs
    /mnt/user-data/uploads
    /mnt/user-data/tool_results
    /mnt/transcripts
    /mnt/skills
    /mnt/skills/user
    /mnt/skills/public
    /mnt/skills/examples
    /tmp
    /var/tmp
    /root
)
for path in "${PATHS_TO_CHECK[@]}"; do
    if [[ ! -e "$path" ]]; then
        printf "  ${DIM}%-40s %s${RST}\n" "$path" "(does not exist)"
        continue
    fi
    testfile="${path}/.write_test_$$"
    if touch "$testfile" 2>/dev/null; then
        rm -f "$testfile"
        printf "  ${GRN}✔  %-40s WRITABLE${RST}\n" "$path"
    else
        printf "  ${YEL}✘  %-40s READ-ONLY${RST}\n" "$path"
    fi
done

# -- 1f. Filesystem of /proc/self ---------------------------------------------
# Gives insight into namespace isolation: the presence of distinct inode
# numbers on /proc/self/ns/* tells you which namespaces this process is in.
if [[ "$VERBOSE" == "true" ]]; then
    subheader "Key /proc/self entries (verbose)"
    echo "  /proc/self/cgroup:"
    cat /proc/self/cgroup 2>/dev/null | head -20 | sed 's/^/    /' || info "(unavailable)"
fi

fi  # end should_run mounts

# =============================================================================
# SECTION 2: PROCESS & SECURITY CONTEXT
# =============================================================================
if should_run security; then

header "SECTION 2 - PROCESS & SECURITY CONTEXT"

# -- 2a. Identity -------------------------------------------------------------
subheader "Identity (id, whoami)"
label "id output:" "$(id 2>/dev/null || echo unavailable)"
label "whoami:"    "$(whoami 2>/dev/null || echo unavailable)"
label "HOME:"      "${HOME:-unset}"
label "IS_SANDBOX:" "${IS_SANDBOX:-unset}"

# -- 2b. Linux capabilities ----------------------------------------------------
# Linux capabilities break the monolithic root privilege into ~40 granular
# rights. A container can run as uid=0 but have capabilities dropped so it
# can't, e.g., load kernel modules (cap_sys_module) or manipulate raw
# sockets (cap_net_raw).
#
# /proc/self/status reports five capability sets:
#   CapInh  - inherited caps (passed across exec)
#   CapPrm  - permitted caps (the ceiling for effective)
#   CapEff  - effective caps (what's actually active RIGHT NOW)
#   CapBnd  - bounding set (hard ceiling, can only be reduced)
#   CapAmb  - ambient caps (preserved across exec for non-root)
#
# The hex values are bitmasks. capsh --decode converts them to names.
# 000001fffeffffff is essentially "all caps" (which is what we saw).
subheader "Linux capabilities (/proc/self/status)"
grep '^Cap' /proc/self/status 2>/dev/null | sed 's/^/    /' || warn "/proc/self/status unavailable"

# Decode CapEff if capsh is available
if command -v capsh &>/dev/null; then
    subheader "Decoded effective capabilities (capsh --decode)"
    capeff=$(grep '^CapEff' /proc/self/status | awk '{print $2}' || true)
    capsh --decode="${capeff}" 2>/dev/null | fold -w 80 -s | sed 's/^/    /' \
        || warn "capsh decode failed"
else
    warn "capsh not found - install libcap2-bin for capability decoding"
    info "  You can decode manually: https://github.com/torvalds/linux/blob/master/include/uapi/linux/capability.h"
fi

# -- 2c. Seccomp ---------------------------------------------------------------
# Seccomp (Secure Computing Mode) can restrict which syscalls a process
# may make. Mode 0 = disabled, Mode 1 = strict (only read/write/exit/sigreturn),
# Mode 2 = filter (BPF program defines allowed/denied syscalls).
# Docker by default applies a ~300-syscall allowlist; Kubernetes can too.
# A value of 0 here means no syscall filtering - the process can call anything.
subheader "Seccomp status"
seccomp=$(grep '^Seccomp' /proc/self/status 2>/dev/null | awk '{print $2}' || echo "unavailable")
case "$seccomp" in
    0) label "Seccomp mode:" "0 - DISABLED (no syscall filtering)" ;;
    1) label "Seccomp mode:" "1 - STRICT (only read/write/exit/sigreturn allowed)" ;;
    2) label "Seccomp mode:" "2 - FILTER (BPF program active)" ;;
    *) label "Seccomp mode:" "$seccomp" ;;
esac
filters=$(grep '^Seccomp_filters' /proc/self/status 2>/dev/null | awk '{print $2}' || echo "unavailable")
label "Active filters:" "$filters"

# -- 2d. Namespaces ------------------------------------------------------------
# Each symlink in /proc/self/ns/ points to a namespace identified by its
# type and inode number. If two processes share an inode on (say) net:,
# they're in the same network namespace and can see each other's interfaces.
# Distinct inodes = isolated namespaces.
#
# Standard namespace types:
#   mnt   - filesystem mount points
#   pid   - process IDs (init = PID 1 inside the ns)
#   net   - network interfaces, routes, iptables rules
#   ipc   - System V IPC, POSIX message queues
#   uts   - hostname and domain name
#   user  - UID/GID mappings
#   cgroup-- cgroup hierarchy root
#   time  - monotonic/boot clocks (Linux 5.6+)
subheader "Namespace inodes (/proc/self/ns/)"
ls -la /proc/self/ns/ 2>/dev/null | grep -v '^total\|^\.' | sed 's/^/    /' \
    || warn "/proc/self/ns/ not accessible"

# -- 2e. cgroups ---------------------------------------------------------------
# cgroups (control groups) are how the kernel enforces resource limits:
# CPU time, memory, I/O bandwidth, etc. The path tells you which cgroup
# hierarchy this process is placed in; the controller (cpu, memory, ...) tells
# you what resources are being tracked/limited.
subheader "cgroup membership (/proc/self/cgroup)"
cat /proc/self/cgroup 2>/dev/null | sed 's/^/    /' || warn "unavailable"

# -- 2f. Environment variables -------------------------------------------------
# The environment often reveals how the sandbox is configured: proxy settings,
# CA bundle paths, language runtimes, feature flags, etc.
# Sensitive values are redacted by mask_env_value before printing.
subheader "Environment variables (sorted, sensitive values redacted)"
while IFS='=' read -r name value; do
    masked=$(mask_env_value "$name" "$value")
    printf '    %s=%s\n' "$name" "$masked"
done < <(env | sort)

# -- 2g. Resource limits -------------------------------------------------------
# ulimit reflects the process's soft limits (what it can use) and hard limits
# (the ceiling it can raise to without privilege). Key ones for container
# debugging:
#   nofiles (open file descriptors) - low values (e.g. 1024) cause "too many
#     open files" errors with npm, gradle, databases, etc.
#   nproc   (max processes/threads) - relevant for fork-heavy workloads
subheader "Resource limits (ulimit -a)"
ulimit -a 2>/dev/null | sed 's/^/    /' || warn "ulimit unavailable"

# -- 2h. Per-process resource limits (prlimit) ---------------------------------
# prlimit is more detailed than ulimit -a -- it shows both soft and hard limits
# for the current process and is immune to shell built-in masking.
subheader "Per-process resource limits (prlimit)"
if command -v prlimit &>/dev/null; then
    prlimit 2>/dev/null | sed 's/^/    /' || warn "prlimit failed"
else
    warn "prlimit not found (util-linux package)"
fi

# -- 2i. Container / virtualisation detection ----------------------------------
# systemd-detect-virt is the cleanest single-command answer: it prints the
# detected virtualisation type (docker, lxc, kvm, qemu, none, etc.) and exits
# non-zero only if nothing is detected. Extremely useful as a sandbox signal.
subheader "Virtualisation / container detection"
if command -v systemd-detect-virt &>/dev/null; then
    virt=$(systemd-detect-virt 2>/dev/null || echo "(none detected)")
    label "systemd-detect-virt:" "$virt"
else
    warn "systemd-detect-virt not found"
fi
# Belt-and-suspenders: check multiple well-known container marker files
for marker in /.dockerenv /run/.containerenv /run/container_type; do
    if [[ -f "$marker" ]]; then
        info "Container marker file present: $marker"
        [[ -s "$marker" ]] && cat "$marker" | sed 's/^/    /'
    fi
done
# Firecracker / microVM: check for hypervisor cpuid string in /proc/cpuinfo
if grep -qiE 'hypervisor|kvm|vmware|xen' /proc/cpuinfo 2>/dev/null; then
    info "Hypervisor hint found in /proc/cpuinfo"
    grep -iE 'hypervisor|kvm|vmware|xen' /proc/cpuinfo | head -3 | sed 's/^/    /'
fi
# K8s service account token mount (strong indicator of running inside a pod)
if [[ -d /var/run/secrets/kubernetes.io/serviceaccount ]]; then
    warn "Kubernetes service account token mounted -- running inside a K8s pod"
    ls -la /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null | sed 's/^/    /'
fi
# Docker Swarm secrets
if [[ -d /run/secrets ]] && [[ -n "$(ls -A /run/secrets 2>/dev/null)" ]]; then
    warn "Docker Swarm secrets volume mounted at /run/secrets"
    ls /run/secrets/ 2>/dev/null | sed 's/^/    /'
fi

# -- 2j. AppArmor / SELinux ----------------------------------------------------
# AppArmor and SELinux are MAC (Mandatory Access Control) layers on top of
# standard POSIX permissions. Their presence (and active profiles) tells you
# whether the kernel has an additional policy enforcement layer beyond capabilities.
subheader "AppArmor / SELinux status"
if command -v aa-status &>/dev/null; then
    aa-status 2>/dev/null | head -20 | sed 's/^/    /' || warn "aa-status failed (may need root)"
elif [[ -f /sys/kernel/security/apparmor/profiles ]]; then
    info "AppArmor appears active (/sys/kernel/security/apparmor/profiles exists)"
    wc -l < /sys/kernel/security/apparmor/profiles | xargs -I{} info "{} profiles loaded"
else
    info "(AppArmor not active or aa-status not available)"
fi

if command -v sestatus &>/dev/null; then
    sestatus 2>/dev/null | sed 's/^/    /' || warn "sestatus failed"
elif [[ -f /etc/selinux/config ]]; then
    info "SELinux config found:"
    grep -vE '^\s*#|^\s*$' /etc/selinux/config | sed 's/^/    /'
else
    info "(SELinux not detected)"
fi

# -- 2k. Key kernel security tunables ------------------------------------------
# These sysctl values directly constrain what a sandboxed process can observe
# or do. Important signal for understanding the actual privilege level.
subheader "Kernel security tunables (sysctl)"
SECURITY_SYSCTLS=(
    kernel.dmesg_restrict        # 0=readable, 1=root only -- low-priv container usually 1
    kernel.perf_event_paranoid   # 3=no perf for anyone, 2=root only, 1/0=more open
    kernel.kptr_restrict         # 0=expose, 2=always hide kernel pointers
    kernel.randomize_va_space    # ASLR: 0=off, 1=partial, 2=full
    kernel.unprivileged_userns_clone  # user namespace creation without root (Debian)
    kernel.ngroups_max           # max supplementary groups
    fs.suid_dumpable             # 0=no core dumps for suid, 2=root-readable core files
    net.ipv4.ip_unprivileged_port_start  # lowest port a non-root process can bind
)
for k in "${SECURITY_SYSCTLS[@]}"; do
    val=$(sysctl -n "$k" 2>/dev/null || echo "(unavailable)")
    label "$k:" "$val"
done

# -- 2l. Tracing / debugging capability probe ----------------------------------
# strace requires CAP_SYS_PTRACE. Its presence AND whether it actually works
# is one of the clearest signals of container privilege level.
# We just check for presence here -- actually running it would be intrusive.
subheader "Tracing / debug tools (privilege signal)"
for tool in strace ltrace gdb lldb valgrind perf bpftrace bpftool; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done
# Quick ptrace capability probe: attempt to strace a no-op and catch EPERM
if command -v strace &>/dev/null; then
    if strace -e trace=none true 2>/dev/null; then
        info "ptrace: ALLOWED (strace -e trace=none true succeeded)"
    else
        warn "ptrace: BLOCKED (strace present but returned non-zero -- likely seccomp/cap_sys_ptrace denied)"
    fi
fi

fi  # end should_run security

# =============================================================================
# SECTION 3: NETWORK
# =============================================================================
if should_run network; then

header "SECTION 3 - NETWORK CONFIGURATION"

# -- 3a. Network interfaces ----------------------------------------------------
# ip addr (iproute2) is the modern replacement for ifconfig (net-tools).
# In a heavily-isolated container you may see NO interfaces beyond loopback --
# traffic still works because it goes through a veth pair in the host ns or
# through a userspace proxy, but the process itself has no visible NIC.
subheader "Network interfaces (ip addr show)"
if command -v ip &>/dev/null; then
    ip addr show 2>/dev/null | sed 's/^/    /' || warn "ip addr failed"
else
    warn "iproute2 (ip) not found - trying ifconfig"
    ifconfig 2>/dev/null | sed 's/^/    /' || warn "ifconfig also unavailable"
fi

# -- 3b. Routing table ---------------------------------------------------------
# The routing table shows where packets go. In a container with an egress
# proxy, you may see a default route pointing to a private gateway IP that
# is actually the proxy, not the real internet gateway.
subheader "Routing table (ip route show)"
ip route show 2>/dev/null | sed 's/^/    /' || warn "ip route failed"

# Also show IPv6 routes if present
ip -6 route show 2>/dev/null | grep -v '^$' | sed 's/^/    [IPv6] /' || true

# -- 3c. DNS configuration -----------------------------------------------------
# /etc/resolv.conf is where libc looks for DNS servers. In containers this is
# often set to a well-known public resolver (8.8.8.8, 1.1.1.1) or to a
# cluster-internal resolver (e.g. 10.96.0.10 for Kubernetes kube-dns).
# Note: systemd-resolved uses 127.0.0.53 as a stub resolver; the real upstream
# is in /run/systemd/resolve/resolv.conf.
subheader "DNS configuration (/etc/resolv.conf)"
cat /etc/resolv.conf 2>/dev/null | sed 's/^/    /' || warn "/etc/resolv.conf not readable"

# Also check for systemd-resolved's upstream config
if [[ -f /run/systemd/resolve/resolv.conf ]]; then
    subheader "systemd-resolved upstream (/run/systemd/resolve/resolv.conf)"
    cat /run/systemd/resolve/resolv.conf | sed 's/^/    /'
fi

# -- 3d. Hosts file ------------------------------------------------------------
# Custom /etc/hosts entries are used for: service discovery in Docker Compose,
# Kubernetes pod DNS injection, or blocking certain domains in a sandbox.
subheader "Hosts file (/etc/hosts, non-comment non-blank lines)"
grep -vE '^\s*#|^\s*$' /etc/hosts 2>/dev/null | sed 's/^/    /' || warn "unavailable"

# -- 3e. Firewall rules --------------------------------------------------------
# iptables is the classic Linux packet filter. nftables is the modern
# replacement. Either may be present (or neither in a highly minimal container).
# Empty iptables output (just the default chains) effectively means no filtering.
subheader "iptables rules (filter table)"
if command -v iptables &>/dev/null; then
    iptables -L -n --line-numbers 2>/dev/null | sed 's/^/    /' \
        || warn "iptables unavailable (may need cap_net_admin)"
else
    warn "iptables not found"
fi

subheader "nftables ruleset"
if command -v nft &>/dev/null; then
    nft list ruleset 2>/dev/null | sed 's/^/    /' || warn "nft list failed"
else
    warn "nft not found"
fi

# -- 3f. Egress proxy evidence -------------------------------------------------
# An egress TLS proxy intercepts HTTPS by injecting a custom CA into the
# system trust store. The proxy then presents its own cert (signed by that CA)
# for every upstream connection, decrypts the traffic, inspects/logs/filters
# it, and re-encrypts to the real destination.
#
# Signs of an egress proxy:
#   1. Custom CA certificates in /etc/ssl/certs/ with names like "egress-*"
#   2. Environment variables: HTTPS_PROXY, https_proxy, HTTP_PROXY, http_proxy
#   3. NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE pointing at the system bundle
#      (so all runtimes trust the injected CA automatically)
subheader "Proxy environment variables"
proxy_vars=(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy \
            NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE SSL_CERT_FILE)
found_proxy=false
for v in "${proxy_vars[@]}"; do
    val="${!v:-}"
    if [[ -n "$val" ]]; then
        label "$v:" "$(mask_env_value "$v" "$val")"
        found_proxy=true
    fi
done
if ! $found_proxy; then
    info "(no proxy environment variables set)"
fi

subheader "Custom CA certificates in trust store"
# Look for non-standard CA filenames that suggest proxy injection.
# Standard Ubuntu CA bundles have well-known names; anything with "egress",
# "gateway", "proxy", "mitm", "intercept" in the name is interesting.
if [[ -d /etc/ssl/certs ]]; then
    custom_cas=$(find /etc/ssl/certs -name '*.pem' -o -name '*.crt' 2>/dev/null \
        | grep -iE 'egress|gateway|proxy|mitm|intercept|swp|internal' || true)
    if [[ -n "$custom_cas" ]]; then
        warn "Possible egress proxy CA certificates found:"
        echo "$custom_cas" | sed 's/^/    /'
        info "TLS traffic is likely being intercepted and inspected by a proxy."
        info "The proxy presents its own cert (signed by the above CA) for upstream connections."
    else
        info "(no proxy-named CAs found in /etc/ssl/certs)"
    fi

    subheader "All non-symlink PEM files in /etc/ssl/certs (first 30)"
    find /etc/ssl/certs -maxdepth 1 -name '*.pem' ! -type l 2>/dev/null \
        | sort | head -30 | sed 's/^/    /'
fi

# -- 3g. Active connections -----------------------------------------------------
# ss (socket statistics) shows open TCP/UDP connections and listening sockets.
# Useful for spotting unexpected listeners or confirming the process has no
# inbound ports open.
subheader "Active sockets (ss -tunap)"
if command -v ss &>/dev/null; then
    ss -tunap 2>/dev/null | sed 's/^/    /' || warn "ss failed"
elif command -v netstat &>/dev/null; then
    warn "ss not found, falling back to netstat (deprecated)"
    netstat -tunap 2>/dev/null | sed 's/^/    /' || warn "netstat failed"
else
    warn "Neither ss nor netstat found"
fi

# -- 3h. Connection tracking table ---------------------------------------------
# conntrack shows the kernel's NAT/netfilter connection tracking table.
# In a container behind a NAT proxy you'll see translated src/dst pairs here.
subheader "Connection tracking table (conntrack -L)"
if command -v conntrack &>/dev/null; then
    conntrack -L 2>/dev/null | head -30 | sed 's/^/    /' \
        || warn "conntrack failed (may need cap_net_admin)"
else
    warn "conntrack not found (conntrack-tools package)"
fi

# -- 3i. IPv6 firewall rules ---------------------------------------------------
subheader "ip6tables rules (filter table)"
if command -v ip6tables &>/dev/null; then
    ip6tables -L -n --line-numbers 2>/dev/null | sed 's/^/    /' \
        || warn "ip6tables failed (may need cap_net_admin)"
else
    warn "ip6tables not found"
fi

# -- 3j. systemd-resolved detail -----------------------------------------------
subheader "DNS resolver detail (resolvectl)"
if command -v resolvectl &>/dev/null; then
    resolvectl status 2>/dev/null | head -30 | sed 's/^/    /' || warn "resolvectl failed"
else
    warn "resolvectl not found (not using systemd-resolved, or not in PATH)"
fi

# -- 3k. Network utility presence (capability signal) --------------------------
# Whether tools like nc, tcpdump, and nmap are available says a lot about
# what a sandboxed process could do -- even without running them here.
subheader "Network utility presence (capability signal)"
for tool in nc ncat socat nmap tcpdump traceroute tracepath mtr dig nslookup host ethtool; do
    if command -v "$tool" &>/dev/null; then
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$(command -v "$tool")"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

# -- 3l. Connectivity test -----------------------------------------------------
# Quick smoke-test to confirm whether outbound DNS and HTTPS actually work.
# We use curl with a short timeout so it doesn't hang.
subheader "Outbound connectivity smoke test"
if command -v curl &>/dev/null; then
    # DNS resolution + TCP connect to a reliable, stable IP
    if curl -s --max-time 5 -o /dev/null -w "HTTP %{http_code} from %{url_effective}" \
            "https://httpbin.org/status/200" 2>/dev/null; then
        echo
        info "Outbound HTTPS: OK"
    else
        warn "Outbound HTTPS to httpbin.org failed or timed out"
        info "This may be expected in an airgapped or proxy-only sandbox"
    fi
else
    warn "curl not found - skipping connectivity test"
fi

fi  # end should_run network

# =============================================================================
# SECTION 4: PROCESSES
# =============================================================================
if should_run processes; then

header "SECTION 4 - RUNNING PROCESSES"

# -- 4a. Process tree ---------------------------------------------------------
subheader "Process tree (ps auxf or pstree)"
if command -v pstree &>/dev/null; then
    pstree -p 2>/dev/null | head -60 | sed 's/^/    /' || warn "pstree failed"
else
    ps auxf 2>/dev/null | head -60 | sed 's/^/    /' \
        || ps aux 2>/dev/null | head -60 | sed 's/^/    /' \
        || warn "ps unavailable"
fi

# -- 4b. Top CPU/memory consumers ---------------------------------------------
subheader "Top 15 processes by CPU (ps aux --sort=-%cpu)"
ps aux --sort=-%cpu 2>/dev/null | head -16 | sed 's/^/    /' \
    || ps aux 2>/dev/null | head -16 | sed 's/^/    /' \
    || warn "ps unavailable"

subheader "Top 15 processes by memory (ps aux --sort=-%mem)"
ps aux --sort=-%mem 2>/dev/null | head -16 | sed 's/^/    /' || true

# -- 4b2. Memory summary -------------------------------------------------------
# free -h is a cleaner human-readable view of /proc/meminfo.
# vmstat -s adds swap activity and page fault counters.
subheader "Memory summary (free -h)"
if command -v free &>/dev/null; then
    free -h 2>/dev/null | sed 's/^/    /' || warn "free failed"
else
    warn "free not found -- reading /proc/meminfo directly"
    grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree)' \
        /proc/meminfo 2>/dev/null | sed 's/^/    /' || warn "/proc/meminfo unavailable"
fi

subheader "Virtual memory & IO stats (vmstat -s)"
if command -v vmstat &>/dev/null; then
    vmstat -s 2>/dev/null | head -20 | sed 's/^/    /' || warn "vmstat failed"
else
    warn "vmstat not found (procps package)"
fi

# -- 4b3. Per-device IO stats --------------------------------------------------
subheader "Per-device IO stats (iostat -x)"
if command -v iostat &>/dev/null; then
    iostat -x 1 1 2>/dev/null | sed 's/^/    /' || warn "iostat failed"
else
    warn "iostat not found (sysstat package)"
fi

# -- 4b4. Per-CPU utilisation --------------------------------------------------
subheader "Per-CPU utilisation snapshot (mpstat)"
if command -v mpstat &>/dev/null; then
    mpstat 1 1 2>/dev/null | sed 's/^/    /' || warn "mpstat failed"
else
    warn "mpstat not found (sysstat package)"
fi

# -- 4b5. Kernel slab allocator ------------------------------------------------
# slabtop --once shows per-slab memory consumption. In a container hitting
# memory limits, dcache/dentry/inode_cache entries are common culprits.
subheader "Kernel slab allocator top (slabtop --once)"
if command -v slabtop &>/dev/null; then
    slabtop --once 2>/dev/null | head -25 | sed 's/^/    /' \
        || warn "slabtop failed (may need root)"
elif [[ -r /proc/slabinfo ]]; then
    info "slabtop not found; top 10 slabs from /proc/slabinfo:"
    awk 'NR>2 {printf "%s %s\n", $3, $1}' /proc/slabinfo \
        | sort -rn | head -10 | sed 's/^/    /'
else
    warn "slabtop not found and /proc/slabinfo not readable"
fi

# -- 4c. Open file descriptors ------------------------------------------------
subheader "Open file descriptor count (per process, top 10)"
if command -v lsof &>/dev/null; then
    lsof 2>/dev/null | awk 'NR>1{count[$1" (pid:"$2")"]++} END{for(p in count) print count[p], p}' \
        | sort -rn | head -10 | sed 's/^/    /' || info "(lsof returned no data)"
else
    warn "lsof not found"
    # Fallback: count via /proc
    total=0
    for pid_dir in /proc/[0-9]*/fd; do
        count=$(ls "$pid_dir" 2>/dev/null | wc -l)
        total=$((total + count))
    done
    info "Approximate total open FDs across all processes: $total"
fi

# -- 4d. Systemd units (if available) -----------------------------------------
subheader "Active systemd units (if systemd is PID 1)"
if [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]; then
    systemctl list-units --state=active --no-pager 2>/dev/null | head -40 | sed 's/^/    /' \
        || warn "systemctl failed"
else
    info "(systemd is not PID 1; skipping)"
fi

# -- 4e. Listening services summary -------------------------------------------
subheader "Listening TCP/UDP ports"
if command -v ss &>/dev/null; then
    ss -tlunp 2>/dev/null | sed 's/^/    /' || warn "ss failed"
elif command -v netstat &>/dev/null; then
    netstat -tlunp 2>/dev/null | sed 's/^/    /' || warn "netstat failed"
fi

fi  # end should_run processes

# =============================================================================
# SECTION 5: RUNTIME ENVIRONMENT
# =============================================================================
if should_run runtime; then

header "SECTION 5 - RUNTIME ENVIRONMENT"

# -- 5a. Language runtimes -----------------------------------------------------
subheader "Language runtime versions"
for tool in python3 python python2 node nodejs deno ruby perl php go rustc java javac; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || true)
        label "$tool:" "$ver"
    else
        printf "  ${DIM}%-26s %s${RST}\n" "$tool:" "(not found)"
    fi
done

# -- 5b. System package managers -----------------------------------------------
# These tell you what's *installable* in the sandbox -- as important as what's
# already installed. The first one found wins for distro identification.
subheader "System package managers"
for pm in apt apt-get dpkg yum dnf rpm apk zypper pacman brew snap flatpak; do
    if command -v "$pm" &>/dev/null; then
        ver=$("$pm" --version 2>/dev/null | head -1 || echo "(found)")
        label "$pm:" "$ver"
    fi
done

# -- 5b2. Language-level package managers --------------------------------------
subheader "Language package managers"
for pm in pip pip3 npm yarn pnpm cargo gem bundle conda mamba uv rye; do
    if command -v "$pm" &>/dev/null; then
        ver=$("$pm" --version 2>/dev/null | head -1 || true)
        label "$pm:" "$ver"
    fi
done

# -- 5c. Build & container tools -----------------------------------------------
subheader "Build & container tools"
for tool in make cmake gcc g++ clang docker podman kubectl helm terraform ansible; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || true)
        label "$tool:" "$ver"
    else
        printf "  ${DIM}%-26s %s${RST}\n" "$tool:" "(not found)"
    fi
done

# -- 5d. Shell & system utilities ---------------------------------------------
subheader "Shell & core utilities"
label "Login shell:"  "${SHELL:-unset}"
label "bash version:" "$(bash --version 2>/dev/null | head -1 || true)"
for tool in curl wget git jq yq vim tmux screen rsync rclone; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>/dev/null | head -1 || true)
        label "$tool:" "$ver"
    else
        printf "  ${DIM}%-26s %s${RST}\n" "$tool:" "(not found)"
    fi
done

# -- 5e. OS release info -------------------------------------------------------
subheader "OS release"
cat /etc/os-release 2>/dev/null | sed 's/^/    /' || warn "/etc/os-release not found"
label "uname -a:" "$(uname -a 2>/dev/null)"

# -- 5f. CPU info (lscpu) -----------------------------------------------------
# lscpu gives a clean structured CPU topology view -- sockets, cores, threads,
# architecture, cache sizes -- much better than grepping /proc/cpuinfo.
subheader "CPU info (lscpu)"
if command -v lscpu &>/dev/null; then
    lscpu 2>/dev/null | sed 's/^/    /' || warn "lscpu failed"
else
    warn "lscpu not found -- falling back to /proc/cpuinfo"
    grep -E '^(model name|cpu cores|siblings|processor)' /proc/cpuinfo 2>/dev/null \
        | sort -u | head -10 | sed 's/^/    /' || warn "/proc/cpuinfo unavailable"
fi

# -- 5g. Memory info -----------------------------------------------------------
subheader "Memory info (/proc/meminfo)"
grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Hugepage)' \
    /proc/meminfo 2>/dev/null | sed 's/^/    /' || warn "/proc/meminfo unavailable"

# -- 5h. Kernel ring buffer (dmesg) -------------------------------------------
# dmesg access is controlled by kernel.dmesg_restrict. In a well-locked-down
# container this command will fail with EPERM -- which is itself informative.
# We only grab the last 20 lines to avoid flooding the report.
subheader "Kernel ring buffer tail (dmesg, last 20 lines)"
if command -v dmesg &>/dev/null; then
    dmesg 2>/dev/null | tail -20 | sed 's/^/    /' \
        || warn "dmesg: permission denied (kernel.dmesg_restrict=1)"
else
    warn "dmesg not found"
fi

# -- 5i. Kernel modules --------------------------------------------------------
# Loaded kernel modules reveal what hardware support and kernel features are
# active. In a container, the module list is shared with the host kernel.
subheader "Loaded kernel modules (lsmod)"
if command -v lsmod &>/dev/null; then
    lsmod 2>/dev/null | head -40 | sed 's/^/    /' \
        || warn "lsmod failed (may need root)"
elif [[ -r /proc/modules ]]; then
    awk '{print $1}' /proc/modules | head -40 | sed 's/^/    /'
else
    warn "lsmod not found and /proc/modules not readable"
fi

# -- 5j. Full sysctl dump (selected interesting keys) -------------------------
# We grab a broad selection of tunables rather than everything (which is huge).
# Grouped: vm, kernel, net, fs.
subheader "Selected sysctl tunables"
INTERESTING_SYSCTLS=(
    vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
    vm.overcommit_memory vm.overcommit_ratio vm.oom_kill_allocating_task
    kernel.pid_max kernel.threads-max kernel.core_pattern
    kernel.hostname kernel.osrelease kernel.version
    net.ipv4.ip_forward net.ipv4.conf.all.forwarding
    net.ipv4.tcp_syncookies net.ipv4.tcp_max_syn_backlog
    net.core.somaxconn net.core.rmem_max net.core.wmem_max
    fs.file-max fs.inotify.max_user_watches fs.inotify.max_user_instances
)
for k in "${INTERESTING_SYSCTLS[@]}"; do
    val=$(sysctl -n "$k" 2>/dev/null || echo "(unavailable)")
    label "$k:" "$val"
done

# -- 5k. Storage / IO tools ----------------------------------------------------
# dd is the classic raw-block copy tool and a basic IO benchmark.
# We only check for presence -- not run it -- since it could be destructive.
subheader "Storage & IO tools"
for tool in dd fio hdparm nvme smartctl e2fsck fsck parted fdisk; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

# -- 5l. Hardware inventory ----------------------------------------------------
subheader "Hardware inventory (lshw/lspci/lscpu)"
if command -v lshw &>/dev/null; then
    lshw -short 2>/dev/null | head -30 | sed 's/^/    /' \
        || warn "lshw failed (may need root)"
elif command -v lspci &>/dev/null; then
    info "lshw not found; using lspci:"
    lspci 2>/dev/null | head -20 | sed 's/^/    /' || warn "lspci failed"
else
    warn "lshw and lspci not found (pciutils package)"
fi

fi  # end should_run runtime

# =============================================================================
# SECTION 6: TOOL AVAILABILITY
# =============================================================================
if should_run tools; then

header "SECTION 6 - TOOL AVAILABILITY"

subheader "Runtimes"
RUNTIMES_ITEMS=(python3 node docker)
for tool in "${RUNTIMES_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

subheader "Document & PDF"
DOCUMENT_AND_PDF_ITEMS=(wkhtmltopdf pandoc qpdf ghostscript pdftotext pdftoppm pdfimages)
for tool in "${DOCUMENT_AND_PDF_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

subheader "PDF Parsing"
PDF_PARSING_ITEMS=(camelot-py tabula-py markitdown reportlab)
for mod in "${PDF_PARSING_ITEMS[@]}"; do
    if python3 -c "import $mod" &>/dev/null 2>&1; then
        ver=$(python3 -c "import $mod; print(getattr($mod, '__version__', '(no __version__)'))" 2>/dev/null || echo "(found, no version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$mod" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$mod"
    fi
done

subheader "OCR & Vision"
OCR_TOOLS_ITEMS=(tesseract convert)
for tool in "${OCR_TOOLS_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done
OCR_PYMODS_ITEMS=(pytesseract cv2 skimage mediapipe wand)
for mod in "${OCR_PYMODS_ITEMS[@]}"; do
    if python3 -c "import $mod" &>/dev/null 2>&1; then
        ver=$(python3 -c "import $mod; print(getattr($mod, '__version__', '(no __version__)'))" 2>/dev/null || echo "(found, no version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$mod" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$mod"
    fi
done

subheader "Media"
MEDIA_ITEMS=(ffmpeg inkscape dot)
for tool in "${MEDIA_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

subheader "Browser / Scraping"
BROWSER_TOOLS_ITEMS=(chromium chromium-browser google-chrome playwright)
for tool in "${BROWSER_TOOLS_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done
BROWSER_PYMODS_ITEMS=(playwright)
for mod in "${BROWSER_PYMODS_ITEMS[@]}"; do
    if python3 -c "import $mod" &>/dev/null 2>&1; then
        ver=$(python3 -c "import $mod; print(getattr($mod, '__version__', '(no __version__)'))" 2>/dev/null || echo "(found, no version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$mod" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$mod"
    fi
done

subheader "Diagramming"
DIAGRAMMING_ITEMS=(mmdc)
for tool in "${DIAGRAMMING_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

subheader "Utilities"
UTILITIES_ITEMS=(jq yq curl wget git unzip zip tar)
for tool in "${UTILITIES_ITEMS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || echo "(found, no --version)")
        printf "  ${GRN}✔  %-20s${RST} %s\n" "$tool" "$ver"
    else
        printf "  ${DIM}✘  %-20s (not found)${RST}\n" "$tool"
    fi
done

fi  # end should_run tools

# =============================================================================
# FOOTER
# =============================================================================
echo
echo "${BOLD}${MAG}╔----------------------------------------------------------=╗${RST}"
echo "${BOLD}${MAG}║                    INSPECTION COMPLETE                    ║${RST}"
echo "${BOLD}${MAG}╚----------------------------------------------------------=╝${RST}"
echo
label "Completed at:" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ -n "$OUTPUT_FILE" ]]; then
    echo >&2
    echo "Report written to: ${OUTPUT_FILE}" >&2
fi

exit 0
