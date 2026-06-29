#!/usr/bin/env -S uv run python3
"""
generate_diagrams.py - Parse a sandbox_inspect.sh report and emit fenced Mermaid diagrams.

Each diagram is written as a standalone Markdown file containing a single fenced
```mermaid block. The inspector.html loads these files at runtime.

Usage:
    python3 generate_diagrams.py [--report REPORT_TXT] [--out-dir OUTPUT_DIR]

Outputs (in OUT_DIR):
    diagram_network.md
    diagram_mounts.md
    diagram_security.md
    diagram_runtime.md
    diagrams.json   -- manifest listing which files were written
"""

import argparse
import html as h
import json
import pathlib
import re
import sys

_SCRIPTS_DIR = pathlib.Path(__file__).parent

SECTION_RE = re.compile(r"^\s{1,4}(SECTION\s+\d+\s*[-:]\s+.+)$")

_NOISE_FSTYPES = frozenset(
    {
        "tmpfs",
        "devtmpfs",
        "sysfs",
        "proc",
        "cgroup",
        "cgroup2",
        "devpts",
        "hugetlbfs",
        "mqueue",
        "pstore",
        "bpf",
        "tracefs",
        "securityfs",
        "debugfs",
        "configfs",
        "fusectl",
        "autofs",
        "FSTYPE",
    }
)

# Shared high-contrast color-scheme classDefs injected into every diagram
CLASSDEFS = """\
    classDef red fill:#FEE2E2,stroke:#EF4444,color:#000
    classDef redwhite fill:#EF4444,stroke:#991B1B,color:#FFF
    classDef lightred fill:#FEF2F2,stroke:#FCA5A5,color:#000
    classDef lightredwhite fill:#FCA5A5,stroke:#991B1B,color:#FFF
    classDef orange fill:#FFEDD5,stroke:#F97316,color:#000
    classDef orangewhite fill:#F97316,stroke:#7C2D12,color:#FFF
    classDef yellow fill:#FEF08A,stroke:#CA8A04,color:#000
    classDef yellowwhite fill:#EAB308,stroke:#713F12,color:#FFF
    classDef green fill:#DCFCE7,stroke:#22C55E,color:#000
    classDef greenwhite fill:#22C55E,stroke:#14532D,color:#FFF
    classDef teal fill:#CCFBF1,stroke:#0D9488,color:#000
    classDef tealwhite fill:#0D9488,stroke:#115E59,color:#FFF
    classDef blue fill:#DBEAFE,stroke:#3B82F6,color:#000
    classDef bluewhite fill:#1D4ED8,stroke:#1E3A8A,color:#FFF
    classDef indigo fill:#E0E7FF,stroke:#4F46E5,color:#000
    classDef indigowhite fill:#312E81,stroke:#1E1B4B,color:#FFF
    classDef purple fill:#F3E8FF,stroke:#9333EA,color:#000
    classDef purplewhite fill:#9333EA,stroke:#581C87,color:#FFF
    classDef pink fill:#FCE7F3,stroke:#EC4899,color:#000
    classDef pinkwhite fill:#EC4899,stroke:#701A75,color:#FFF
    classDef magenta fill:#FAE8FF,stroke:#D946EF,color:#000
    classDef magentawhite fill:#D946EF,stroke:#701A75,color:#FFF
    classDef brown fill:#F5EBE0,stroke:#8B5A2B,color:#000
    classDef brownwhite fill:#8B5A2B,stroke:#4A2711,color:#FFF
    classDef lime fill:#F0FDF4,stroke:#84CC16,color:#000
    classDef limewhite fill:#84CC16,stroke:#365314,color:#FFF
    classDef cyan fill:#ECFEFF,stroke:#06B6D4,color:#000
    classDef cyanwhite fill:#06B6D4,stroke:#164E63,color:#FFF
    classDef slate fill:#F1F5F9,stroke:#475569,color:#000
    classDef slatewhite fill:#475569,stroke:#0F172A,color:#FFF
    classDef grey fill:#F3F4F6,stroke:#9CA3AF,color:#000
    classDef greywhite fill:#9CA3AF,stroke:#374151,color:#FFF
    classDef black fill:#444444,stroke:#000000,color:#FFF
    classDef blackwhite fill:#111111,stroke:#000000,color:#FFF"""


def parse_sections(raw: str) -> list[tuple[str, list[str]]]:
    sections: list[tuple[str, list[str]]] = [("Header", [])]
    for line in raw.splitlines():
        m = SECTION_RE.match(line)
        if m:
            sections.append((m.group(1).strip(), []))
        else:
            sections[-1][1].append(line)
    return sections


def extract_section(sections: list[tuple[str, list[str]]], name: str) -> list[str]:
    for label, lines in sections:
        if name.upper() in label.upper():
            return lines
    return []


def fenced(mermaid_src: str) -> str:
    return f"```mermaid\n{mermaid_src}\n```\n"


def build_network(sections):
    net_lines = extract_section(sections, "NETWORK")

    # --- attempt 1: parse ip addr show output (iface + IPv4) ---
    ifaces = []
    current_iface = None
    for line in net_lines:
        m = re.match(r"\s+\d+:\s+(\S+):", line)
        if m:
            current_iface = m.group(1).rstrip(":")
        if current_iface:
            ip4 = re.search(r"inet\s+([\d.]+/\d+)", line)
            if ip4:
                ifaces.append((current_iface, ip4.group(1)))
                current_iface = None

    if ifaces:
        nodes = "\n    ".join(
            '{}["{}<br><b>{}</b>"]:::teal'.format(iface, iface, addr)
            for iface, addr in ifaces
        )
        edges = "\n    ".join("HOST --> {}".format(iface) for iface, _ in ifaces)
        mmd = (
            "graph TD\n"
            '    HOST["Sandbox Host"]:::indigowhite\n'
            "    {}\n    {}\n{}".format(nodes, edges, CLASSDEFS)
        )
        return fenced(mmd)

    # --- attempt 2: fallback -- build from DNS / hosts / proxy / CA data ---
    dns_servers = []
    hosts_entries = []
    proxy_vars = []
    ca_certs = []

    in_hosts = False
    in_proxy = False
    in_ca = False

    for line in net_lines:
        stripped = line.strip()
        if "DNS configuration" in line or "resolv.conf" in line:
            in_hosts = in_proxy = in_ca = False
        if "Hosts file" in line:
            in_hosts = True
            in_proxy = in_ca = False
            continue
        if "Proxy environment" in line:
            in_proxy = True
            in_hosts = in_ca = False
            continue
        if "Custom CA certificates" in line or "egress proxy CA" in line:
            in_ca = True
            in_hosts = in_proxy = False
            continue
        if stripped.startswith("--") and stripped.endswith("--"):
            in_hosts = in_proxy = in_ca = False
            continue

        m_ns = re.match(r"\s*nameserver\s+([\d.a-fA-F:]+)", line)
        if m_ns:
            dns_servers.append(m_ns.group(1))

        if in_hosts:
            parts = stripped.split()
            if (len(parts) >= 2
                    and not stripped.startswith("\u26a0")
                    and not stripped.startswith("#")
                    and re.match(r"[\d.a-fA-F:]", parts[0])
                    and parts[1] != "--"):
                hosts_entries.append((parts[0], parts[1]))

        if in_proxy:
            m_pv = re.match(r"\s+(\w[\w_]+):\s+(\S+)", line)
            if m_pv:
                proxy_vars.append((m_pv.group(1), m_pv.group(2)))

        if in_ca:
            m_ca = re.search(r"(/etc/ssl/certs/\S+\.pem)", stripped)
            if m_ca:
                ca_certs.append(m_ca.group(1).split("/")[-1].replace(".pem", ""))

    if not dns_servers and not hosts_entries and not proxy_vars and not ca_certs:
        return None

    diagram_lines = [
        "graph TD",
        '    HOST["Sandbox Host<br><i>(network tools absent)</i>"]:::indigowhite',
    ]

    for i, ns in enumerate(dns_servers):
        nid = "DNS{}".format(i)
        diagram_lines.append('    {}["DNS<br><b>{}</b>"]:::teal'.format(nid, ns))
        diagram_lines.append("    HOST --> {}".format(nid))

    for ip, host in hosts_entries:
        if host == "localhost" or (ip.startswith("127.") and host in ("vm", "localhost")):
            continue
        nid = "H_" + re.sub(r"[^a-zA-Z0-9]", "_", host)
        diagram_lines.append('    {}["{}<br><i>{}</i>"]:::orange'.format(nid, host, ip))
        diagram_lines.append("    HOST --> {}".format(nid))

    if ca_certs:
        diagram_lines.append('    PROXY["Egress TLS Proxy<br><i>TLS intercept active</i>"]:::slate')
        diagram_lines.append("    HOST --> PROXY")
        for i, cert in enumerate(ca_certs[:4]):
            cid = "CA{}".format(i)
            diagram_lines.append('    {}["{}"]:::blue'.format(cid, cert))
            diagram_lines.append("    PROXY --> {}".format(cid))

    if proxy_vars:
        var_names = " / ".join(k for k, _ in proxy_vars[:3])
        diagram_lines.append('    PROXYENV["Proxy env vars<br><i>{}</i>"]:::teal'.format(var_names))
        diagram_lines.append("    HOST --> PROXYENV")

    diagram_lines.append(CLASSDEFS)
    return fenced("\n".join(diagram_lines))

def build_mounts(sections: list[tuple[str, list[str]]]) -> str | None:
    mount_lines = extract_section(sections, "FILESYSTEM")
    mounts: list[tuple[str, str]] = []
    for line in mount_lines:
        parts = line.split()
        if len(parts) >= 3 and parts[1].startswith("/") and not parts[1].startswith("/proc"):
            fstype = parts[2]
            if fstype not in _NOISE_FSTYPES:
                mounts.append((parts[1], fstype))

    if not mounts:
        return None

    seen: set[str] = set()
    node_lines: list[str] = ['    ROOT["/<br><b>(Root Axis)</b>"]:::slate']
    edge_lines: list[str] = []
    for mp, fstype in mounts[:20]:
        node_id = re.sub(r"[^a-zA-Z0-9]", "_", mp).strip("_") or "root"
        if node_id in seen:
            node_id = node_id + str(len(seen))
        seen.add(node_id)
        
        # Color coding mapped strictly to the specification definition
        color_class = "orange" if "squashfs" in fstype or "overlay" in fstype else "blue"
        node_lines.append(f'    {node_id}["{mp}<br><i>({fstype})</i>"]:::{color_class}')
        
        parent = str(pathlib.PurePosixPath(mp).parent)
        parent_id = re.sub(r"[^a-zA-Z0-9]", "_", parent).strip("_") or "ROOT"
        edge_lines.append(f"    {parent_id} --> {node_id}")

    mmd = "graph LR\n" + "\n".join(node_lines) + "\n" + "\n".join(edge_lines) + "\n" + CLASSDEFS
    return fenced(mmd)


def build_security(sections: list[tuple[str, list[str]]]) -> str:
    sec_lines = extract_section(sections, "SECURITY")
    seccomp_mode = "unknown"
    cap_eff_hex = ""
    identity = ""

    for line in sec_lines:
        m = re.search(r"Seccomp mode:.*?(\d+)\s+.*?([A-Z]+)", line)
        if m:
            seccomp_mode = f"Mode {m.group(1)} ({m.group(2)})"
        m2 = re.search(r"CapEff\s*[:\s]+([0-9a-fA-F]+)", line)
        if m2:
            cap_eff_hex = m2.group(1)
        if "uid=" in line and not identity:
            id_match = re.search(r"(uid=\d+\(\w+\)\s+gid=\d+\(\w+\))", line)
            identity = id_match.group(1) if id_match else line.strip()[:40]

    cap_count = 0
    if cap_eff_hex:
        try:
            cap_count = bin(int(cap_eff_hex, 16)).count("1")
        except ValueError:
            pass

    cap_label = (
        "None (0)"
        if cap_count == 0
        else f"High ({cap_count} caps)" if cap_count > 20 else f"Limited ({cap_count} caps)"
    )
    cap_class = "red" if cap_count > 20 else "orange" if cap_count > 0 else "green"
    seccomp_label = seccomp_mode if seccomp_mode != "unknown" else "Unknown Filter"
    secc_class = "green" if "FILTER" in seccomp_label.upper() else "orange"

    mmd = (
        f"graph TD\n"
        f'    ID["Identity<br><b>{h.escape(identity or "see report")}</b>"]:::indigowhite\n'
        f'    CAPS["Effective Caps<br><b>{h.escape(cap_label)}</b>"]:::{cap_class}\n'
        f'    SECC["Seccomp<br><b>{h.escape(seccomp_label)}</b>"]:::{secc_class}\n'
        f'    NS["Namespaces<br><i>See attached report</i>"]:::slate\n'
        f'    CG["cgroups<br><i>See attached report</i>"]:::slate\n'
        f"    ID --> CAPS\n"
        f"    ID --> SECC\n"
        f"    ID --> NS\n"
        f"    ID --> CG\n"
        f"{CLASSDEFS}"
    )
    return fenced(mmd)


def build_runtime(sections: list[tuple[str, list[str]]]) -> str | None:
    runtime_lines = extract_section(sections, "RUNTIME")
    found_raw: set[str] = set()
    missing_raw: set[str] = set()
    _skip = frozenset({"uname", "bash", "Login"})

    for line in runtime_lines:
        clean_line = line.strip()
        if not clean_line or any(s in clean_line for s in _skip):
            continue
        m = re.match(r"\s*(?:skill:)?([\w.+-]+):", line)
        if m:
            tool = m.group(1)
            if "(not found)" in line or "(not available)" in line:
                missing_raw.add(tool)
            else:
                found_raw.add(tool)

    if not found_raw and not missing_raw:
        return None

    # Aliasing Map to group structural tool variants dynamically
    ALIAS_MAP = {
        "python3": "python", "python": "python",
        "nodejs": "node", "node": "node",
        "pip3": "pip", "pip": "pip",
        "apt-get": "apt", "apt": "apt"
    }

    def get_canonical(tool_set: set[str]) -> dict[str, list[tuple[str, str]]]:
        categories = {"languages": [], "package_managers": [], "build_tools": []}
        lang_sigs = {"python", "node", "java", "deno", "ruby", "php", "go"}
        pkg_sigs = {"apt", "dpkg", "pip", "npm", "uv"}
        
        processed_normalized = set()
        for t in tool_set:
            norm = ALIAS_MAP.get(t, t)
            if norm in processed_normalized:
                continue
            processed_normalized.add(norm)
            
            display_name = f"{t} / {norm}" if t != norm else t
            
            if norm in lang_sigs:
                categories["languages"].append((norm, display_name))
            elif norm in pkg_sigs:
                categories["package_managers"].append((norm, display_name))
            else:
                categories["build_tools"].append((norm, display_name))
        return categories

    found_cats = get_canonical(found_raw)
    missing_cats = get_canonical(missing_raw)

    mmd_lines = [
        "graph LR",
        '    RT["Runtime Environment"]:::indigowhite',
        '    lang["Languages & Runtimes"]:::slate',
        '    pkg["Package Management"]:::slate',
        '    build["Build & Compilation"]:::slate',
        "    RT --> lang", "RT --> pkg", "RT --> build"
    ]

    def append_subgraph(name: str, group_id: str, found_list, missing_list):
        if not found_list and not missing_list:
            return
        mmd_lines.append(f"\n    subgraph {name}")
        for norm, disp in found_list:
            mmd_lines.append(f'        {group_id}_{norm}["{disp}"]:::green')
            mmd_lines.append(f"        {group_id} --> {group_id}_{norm}")
        for norm, disp in missing_list:
            mmd_lines.append(f'        {group_id}_{norm}["{disp} (Missing)"]:::grey')
            mmd_lines.append(f"        {group_id} -.-> {group_id}_{norm}")
        mmd_lines.append("    end")

    append_subgraph("Languages & Runtimes", "lang", found_cats["languages"], missing_cats["languages"])
    append_subgraph("Package Management", "pkg", found_cats["package_managers"], missing_cats["package_managers"])
    append_subgraph("Build & Compilation", "build", found_cats["build_tools"], missing_cats["build_tools"])

    mmd_lines.append(CLASSDEFS)
    return fenced("\n".join(mmd_lines))


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate fenced Mermaid diagram files from a sandbox report.")
    parser.add_argument(
        "--report",
        "-r",
        type=pathlib.Path,
        default=pathlib.Path("output/sandbox/report.txt"),
        metavar="REPORT_TXT",
        help="plain-text report from sandbox_inspect.sh (default: output/sandbox/report.txt)",
    )
    parser.add_argument(
        "--out-dir",
        "-o",
        type=pathlib.Path,
        default=pathlib.Path("output/sandbox"),
        metavar="OUTPUT_DIR",
        help="directory for diagram .md files (default: output/sandbox)",
    )
    args = parser.parse_args()

    if not args.report.exists():
        print(f"Error: report not found: {args.report}", file=sys.stderr)
        sys.exit(1)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    raw = args.report.read_text(encoding="utf-8", errors="replace")
    sections = parse_sections(raw)

    builders = [
        ("network", "Network Interface Topology", build_network),
        ("security", "Security Context", build_security),
        ("mounts", "Mount Hierarchy", build_mounts),
        ("runtime", "Runtime Availability", build_runtime),
    ]

    manifest: list[dict] = []
    for key, title, builder in builders:
        content = builder(sections)
        if content is None:
            print(f"[diagrams] skip {key} (no data)", file=sys.stderr)
            continue
        md_file = f"diagram_{key}.md"
        mmdc_name = f"diagram_{key}-1.svg"
        docker_name = f"diagram_{key}.svg-1.svg"
        if (args.out_dir / docker_name).exists():
            svg_file = docker_name
        else:
            svg_file = mmdc_name
        out_path = args.out_dir / md_file
        out_path.write_text(f"# {title}\n\n{content}", encoding="utf-8")
        entry: dict = {"key": key, "title": title, "file": md_file, "image_file": svg_file}
        manifest.append(entry)
        print(f"[diagrams] wrote {out_path}", file=sys.stderr)

    manifest_path = args.out_dir / "diagrams.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[diagrams] manifest -> {manifest_path}", file=sys.stderr)


if __name__ == "__main__":
    main()


