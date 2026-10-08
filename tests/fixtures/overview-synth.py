#!/usr/bin/env python3
"""Deterministic synthetic system samples in the collector's JSON form.

Writes one snapshot per line for `xodb --overview --replay FILE`. Every name,
address and number is invented (documentation address ranges, "demo" user,
"demo-host"), so screenshots and tests carry no host data. Frame 0 is a first
sample: its rates are unavailable, as the collector reports them.

usage: overview-synth.py OUT.jsonl [--frames N] [--helpers N]
"""
import argparse
import json
import math
import random

U = lambda why: {"state": "unavailable", "why": why}
FIRST = U("first sample")


def wave(t, period, phase=0.0):
    return 0.5 + 0.5 * math.sin(2 * math.pi * (t / period) + phase)


def frame(t, rng, helpers=120, unavailable=False):
    first = t == 0
    rate = (lambda v: FIRST) if first else (lambda v: round(v, 2))
    ncpu = 32
    cpus = []
    total_busy = 0.0
    for i in range(ncpu):
        core = i % 16
        busy = 4 + 10 * wave(t, 23 + i, i) + 6 * rng.random()
        if core == 3 and i < 16:
            busy = 97 + 2 * rng.random()  # the owned CPU burner
        if 8 <= core < 12:
            busy += 25 * wave(t, 40, 1.3) ** 4  # bursty build job on the second domain
        busy = min(100.0, busy)
        total_busy += busy
        system = busy * 0.18
        cpus.append({
            "id": i, "online": 1,
            "times": FIRST if first else {"user": round(busy - system, 2), "system": round(system, 2), "iowait": round(0.4 * rng.random(), 2),
                                         "irq": 0.1, "softirq": 0.2, "steal": 0.0, "busy": round(busy, 2)},
            "freq_mhz": round(2900 + 2300 * (busy / 100) ** 0.5 + 50 * rng.random(), 1),
            "freq_min_mhz": 600.0, "freq_max_mhz": 5450.0,
            "package_id": 0, "die_id": 0, "core_id": core, "l3_id": core // 8, "smt_index": i // 16,
            "temp_c": U("not present"),
        })
    busy = total_busy / ncpu
    gib = 1 << 30
    mem_total = 64 * gib
    used = int((19.5 + 3.5 * wave(t, 50)) * gib)
    cached = int(28 * gib + 2 * gib * wave(t, 70, 2))
    buffers = int(1.2 * gib)
    shmem = int(1.6 * gib)
    available = mem_total - used
    free = max(0, mem_total - used - cached - buffers)
    writer = 180e6 * wave(t, 30) ** 6 + 2e6 * rng.random()
    disks = [
        {"name": "nvme0n1", "model": "NVMe SSD 2TB (synthetic)", "size_bytes": 2000398934016, "rotational": 0,
         "read_bps": rate(3e6 + 4e6 * rng.random()), "write_bps": rate(writer), "read_iops": rate(220 + 80 * rng.random()),
         "write_iops": rate(writer / 131072 + 20), "busy_pct": rate(min(100, 3 + writer / 2.2e6)), "queue_depth": rate(0.2 + writer / 9e7),
         "avg_latency_ms": rate(0.08 + writer / 9e9), "in_flight": 1, "temp_c": round(41 + 8 * wave(t, 30, -0.4), 2)},
        {"name": "nvme1n1", "model": "NVMe SSD 1TB (synthetic)", "size_bytes": 1000204886016, "rotational": 0,
         "read_bps": rate(1.5e6 * wave(t, 17) ** 3), "write_bps": rate(4e5 * rng.random()), "read_iops": rate(40 * rng.random()),
         "write_iops": rate(10 * rng.random()), "busy_pct": rate(1 + 3 * rng.random()), "queue_depth": rate(0.01),
         "avg_latency_ms": rate(0.07), "in_flight": 0, "temp_c": round(36 + 2 * wave(t, 90), 2)},
        {"name": "sda", "model": "HDD 8TB (synthetic)", "size_bytes": 8001563222016, "rotational": 1,
         "read_bps": rate(9e6 * wave(t, 45, 1) ** 8), "write_bps": rate(0), "read_iops": rate(70 * wave(t, 45, 1) ** 8),
         "write_iops": rate(0), "busy_pct": rate(60 * wave(t, 45, 1) ** 8), "queue_depth": rate(0.6 * wave(t, 45, 1) ** 8),
         "avg_latency_ms": rate(6.5), "in_flight": 0, "temp_c": U("not present")},
    ]
    def fs(mount, source, fstype, total, used_):
        avail = total - used_
        return {"mount": mount, "source": source, "fstype": fstype, "total": total, "free": avail, "avail": avail, "used": used_,
                "inodes_total": total // 16384, "inodes_free": int(total // 16384 * 0.8), "read_only": 0,
                "used_pct": round(100 * used_ / total, 2)}
    tb = 1 << 40
    filesystems = [
        fs("/", "/dev/nvme0n1p2", "ext4", int(0.9 * tb), int(0.52 * tb + writer * t / 50)),
        fs("/boot", "/dev/nvme0n1p1", "vfat", 1 << 30, int(0.31 * gib)),
        fs("/home", "/dev/nvme1n1p1", "btrfs", int(0.93 * tb), int(0.61 * tb)),
        fs("/data", "/dev/sda1", "xfs", int(7.2 * tb), int(6.6 * tb)),
        fs("/run/media/demo/CAMERA", "/dev/sdb1", "exfat", 64 * gib, int(58.9 * gib)),
    ]
    flood = 95e6 * wave(t, 26, 0.7) ** 10
    nets = [
        {"name": "enp6s0", "operstate": "up", "carrier": 1, "speed_mbps": 2500, "mtu": 1500, "loopback": 0, "physical": 1,
         "mac": "02:00:5e:10:00:01", "rx_bps": rate(1.2e6 + 2.5e6 * wave(t, 13) ** 3 + 3e5 * rng.random()),
         "tx_bps": rate(2.5e5 + 6e5 * wave(t, 19, 1) ** 4), "rx_pps": rate(1800 + 900 * rng.random()), "tx_pps": rate(900 + 300 * rng.random()),
         "rx_errors_ps": rate(0), "tx_errors_ps": rate(0), "rx_drops_ps": rate(0), "tx_drops_ps": rate(0),
         "addresses": [{"family": 4, "addr": "192.0.2.10/24"}, {"family": 6, "addr": "2001:db8::10/64"}, {"family": 6, "addr": "::1234/64"}]},
        {"name": "lo", "operstate": "unknown", "carrier": 1, "speed_mbps": U("not present"), "mtu": 65536, "loopback": 1, "physical": 0,
         "mac": "00:00:00:00:00:00", "rx_bps": rate(flood + 2e4), "tx_bps": rate(flood + 2e4), "rx_pps": rate(flood / 1400 + 20),
         "tx_pps": rate(flood / 1400 + 20), "rx_errors_ps": rate(0), "tx_errors_ps": rate(0), "rx_drops_ps": rate(0), "tx_drops_ps": rate(0),
         "addresses": [{"family": 4, "addr": "127.0.0.1/8"}, {"family": 6, "addr": "::1/128"}]},
        {"name": "wlan0", "operstate": "down", "carrier": 0, "speed_mbps": U("not present"), "mtu": 1500, "loopback": 0, "physical": 1,
         "mac": "02:00:5e:10:00:02", "rx_bps": rate(0), "tx_bps": rate(0), "rx_pps": rate(0), "tx_pps": rate(0),
         "rx_errors_ps": rate(0), "tx_errors_ps": rate(0), "rx_drops_ps": rate(0), "tx_drops_ps": rate(0), "addresses": []},
    ]
    conns = []
    def conn(proto, family, state, local, remote, pid=None, comm="", why=None):
        c = {"proto": proto, "family": family, "state": state, "local": local, "remote": remote,
             "uid": 1000 if pid else 0, "rx_queue": 0, "tx_queue": 0}
        if pid:
            c["pid"] = pid
            c["comm"] = comm
        else:
            c["pid"] = U(why or "needs privilege")
        conns.append(c)
    conn("tcp", 4, "LISTEN", "0.0.0.0:22", "0.0.0.0:*", why="needs privilege")
    conn("tcp", 6, "LISTEN", "[::]:22", "[::]:*", why="needs privilege")
    conn("tcp", 4, "LISTEN", "127.0.0.1:631", "0.0.0.0:*", why="needs privilege")
    conn("tcp", 4, "LISTEN", "127.0.0.1:47001", "0.0.0.0:*", 4410, "flood")
    for k in range(6):
        conn("tcp", 4, "ESTABLISHED", f"127.0.0.1:{47100 + k}", "127.0.0.1:47001", 4411, "flood")
    for k in range(9):
        conn("tcp", 4, "ESTABLISHED", f"192.0.2.10:{51000 + 17 * k}", f"198.51.100.{20 + k}:443", 3101, "browser")
    conn("tcp", 6, "ESTABLISHED", "[2001:db8::10]:52210", "[2001:db8:5::9]:443", 3101, "browser")
    for k in range(3):
        conn("tcp", 4, "TIME_WAIT", f"192.0.2.10:{53000 + k}", f"203.0.113.{5 + k}:80", why="gone")
    conn("udp", 4, "UNCONN", "0.0.0.0:5353", "0.0.0.0:*", why="needs privilege")
    conn("udp", 4, "ESTABLISHED", "192.0.2.10:41000", "192.0.2.1:53", 3101, "browser")
    conn("unix", 0, "LISTEN", "/home/demo/SECRET-agent.sock", "", 1020, "bash")
    conn("unix", 0, "LISTEN", "/run/dbus/system_bus_socket", "", 202, "dbus")
    for k in range(8):
        conn("unix", 0, "LISTEN" if k < 3 else "ESTABLISHED", f"/run/demo-{k}.sock" if k < 3 else "", "", 3101 if k % 2 else 1, "browser" if k % 2 else "init")
    sensors = [
        ("k10temp", "Tctl", "temp", 58 + 10 * busy / 40 + 2 * wave(t, 20), None, 95.0),
        ("k10temp", "Tccd1", "temp", 54 + 9 * busy / 40 + 2 * wave(t, 22), None, None),
        ("k10temp", "Tccd2", "temp", 50 + 12 * wave(t, 40, 1.3) ** 4 + 2 * wave(t, 18), None, None),
        ("nvme", "Composite", "temp", 41 + 8 * wave(t, 30, -0.4), 82.85, 84.85),
        ("nvme", "Sensor 1", "temp", 45 + 9 * wave(t, 30, -0.5), 65261.85, None),
        ("amdgpu", "edge", "temp", 47 + 6 * wave(t, 35), None, 100.0),
        ("amdgpu", "junction", "temp", 52 + 9 * wave(t, 35), None, 110.0),
        ("amdgpu", "mem", "temp", 60 + 3 * wave(t, 60), None, 105.0),
        ("amdgpu", "PPT", "power", 18 + 70 * wave(t, 35) ** 3, None, None),
        ("amdgpu", "vddgfx", "voltage", 0.75 + 0.3 * wave(t, 35) ** 3, None, None),
        ("amdgpu", "fan1", "fan", 0.0, 3200, None),
        ("spd5118", "temp1", "temp", 39 + 2 * wave(t, 80), 55.0, 85.0),
        ("spd5118", "temp1", "temp", 38 + 2 * wave(t, 85), 55.0, 85.0),
        ("asus", "CPU fan", "fan", 1150 + 400 * busy / 40, None, None),
        ("r8169", "temp1", "temp", 49 + 1.5 * wave(t, 50), None, 120.0),
    ]
    sensor_json = [{"chip": c, "label": l, "kind": k, "value": round(v, 3), "max": mx if mx is not None else U("not present"),
                    "crit": cr if cr is not None else U("not present")} for c, l, k, v, mx, cr in sensors]
    gpu_busy = 4 + 85 * wave(t, 35) ** 3
    procs = []
    def proc(pid, ppid, comm, cmd, user, uid, cpu, rss, threads, fds, state="S", io=(0, 0), kernel=0, start=None, cgroup="/system.slice"):
        procs.append({
            "pid": pid, "start_ticks": start if start is not None else 100 + pid * 7, "ppid": ppid, "comm": comm,
            "cmdline": cmd if cmd else U("not present"), "state": state, "uid": uid, "user": user,
            "threads": threads, "rss": rss, "pss": U("not collected"),
            "cpu_pct": FIRST if first else round(cpu, 2),
            "io_read_bps": FIRST if first else (round(io[0], 1) if uid == 1000 else U("needs privilege")),
            "io_write_bps": FIRST if first else (round(io[1], 1) if uid == 1000 else U("needs privilege")),
            "net_bps": U("not supported"), "fds": fds if uid == 1000 else U("needs privilege"),
            "nice": 20, "kernel_thread": kernel, "cgroup": cgroup})
    mib = 1 << 20
    proc(1, 0, "init", "/sbin/init", "root", 0, 0.0, 3 * mib, 1, 0, cgroup="/")
    proc(2, 0, "kthreadd", "", "root", 0, 0.0, 0, 1, 0, kernel=1, cgroup="/")
    for k in range(18):
        proc(10 + k, 2, f"kworker/{k}:1", "", "root", 0, 0.3 * rng.random(), 0, 1, 0, state="I", kernel=1, cgroup="/")
    services = ["udevd", "syslog-ng", "dbus", "elogind", "sshd", "cupsd", "chronyd", "dhcpcd", "polkitd", "cronie", "pipewire", "wireplumber", "seatd", "earlyoom", "smartd", "acpid"]
    for k, name in enumerate(services):
        proc(200 + k, 1, name, f"/usr/bin/{name} --foreground", "root", 0, 0.4 * rng.random(), (4 + 9 * k % 23) * mib, 1 + k % 4, 0)
    proc(900, 1, "login", "/bin/login -- demo", "root", 0, 0.0, 4 * mib, 1, 0)
    proc(1000, 900, "sway", "sway", "demo", 1000, 1.5 + rng.random(), 210 * mib, 12, 96, cgroup="/user.slice")
    proc(1010, 1000, "foot", "foot --server", "demo", 1000, 0.3, 48 * mib, 3, 40, cgroup="/user.slice")
    proc(1020, 1010, "bash", "bash -l", "demo", 1000, 0.0, 6 * mib, 1, 5, cgroup="/user.slice")
    proc(4000, 1020, "burner", "./burner --threads 1 --api-token=sk-demo-SECRET", "demo", 1000, 98.5 + rng.random(), 2 * mib, 1, 4, state="R", cgroup="/user.slice")
    proc(4100, 1020, "writer", "./writer --out /home/demo/scratch.bin", "demo", 1000, 6 + 10 * wave(t, 30) ** 6, 12 * mib, 2, 6, state="D" if wave(t, 30) > 0.9 else "S", io=(0, writer), cgroup="/user.slice")
    proc(4410, 1020, "flood", "./flood --server 127.0.0.1:47001", "demo", 1000, 8 + 30 * wave(t, 26, 0.7) ** 10, 5 * mib, 2, 12, cgroup="/user.slice")
    proc(4411, 1020, "flood", "./flood --client 127.0.0.1:47001 --streams 6", "demo", 1000, 6 + 25 * wave(t, 26, 0.7) ** 10, 5 * mib, 7, 14, cgroup="/user.slice")
    proc(3100, 1000, "browser", "browser --profile /home/demo/.profile-demo", "demo", 1000, 3 + 3 * rng.random(), 820 * mib, 48, 412, cgroup="/user.slice")
    for k in range(14):
        proc(3101 + k, 3100, "browser" if k == 0 else f"web-content-{k}", f"browser --type=renderer --id={k}", "demo", 1000, 0.5 + 4 * rng.random() * wave(t, 11 + k), (90 + 37 * k % 300) * mib, 18 + k % 7, 60 + k * 3, cgroup="/user.slice")
    proc(5000, 1020, "make", "make -j8", "demo", 1000, 0.4, 9 * mib, 1, 9, cgroup="/user.slice")
    for k in range(8):
        proc(5001 + k, 5000, "cc1", f"cc1 -O2 src/unit{k}.c", "demo", 1000, 70 * wave(t, 40, 1.3) ** 4 * (0.6 + 0.4 * rng.random()), (60 + 11 * k) * mib, 1, 8, state="R" if wave(t, 40, 1.3) > 0.7 else "S", cgroup="/user.slice")
    proc(6000, 1020, "xodb", "xodb --overview --replay demo.jsonl", "demo", 1000, 0.6, 96 * mib, 6, 31, cgroup="/user.slice")
    for k in range(helpers):
        proc(7000 + k, 1000 if k % 3 else 1, f"helper-{k:03d}", f"/usr/lib/helper-{k:03d} --daemon", "demo" if k % 3 else "root", 1000 if k % 3 else 0, 0.05 * rng.random(), (2 + k % 17) * mib, 1 + k % 3, 3 + k % 11)
    nthreads = sum(p["threads"] for p in procs)
    groups_extra = {}
    if unavailable:
        # Explicitly unmeasured topology and socket list: never package 0 / tcp 0.
        for c in cpus:
            for key in ("package_id", "die_id", "core_id", "l3_id", "smt_index"):
                c[key] = U("needs privilege")
        conns = []
        groups_extra = {"connections": {"state": "unavailable", "why": "needs privilege", "detail": "sock_diag: permission denied"}}
    packages = sorted([(f"package-{k:03d}", f"{1 + k % 7}.{k % 13}.{k % 5}-1", int(2.5 * gib / (1 + k) ** 1.3)) for k in range(60)], key=lambda x: -x[2])
    psi_cpu = round(1.2 + 6 * wave(t, 40, 1.3) ** 4, 2)
    out = {
        "abi": 1, "generator": "tests/fixtures/overview-synth.py (synthetic)", "sequence": t + 1, "redacted": False,
        "interval_s": FIRST if first else 1.0,
        "groups": {g: {"state": "ok", "cost_us": c // 1000, "interval_s": 1.0} for g, c in (("summary", 41000), ("cpu", 182000), ("memory", 36000), ("disks", 52000),
                   ("filesystems", 88000), ("network", 61000), ("connections", 910000), ("power", 240000), ("users", 9000),
                   ("apps", 15000), ("processes", 3900000), ("sysinfo", 12000))}
        | {"services": {"state": "ok", "cost_us": 15000, "interval_s": 2.0}} | groups_extra,
        "summary": {"uptime_s": 432000.5 + t, "load1": round(1.8 + 2 * wave(t, 60), 2), "load5": 2.41, "load15": 2.18,
                    "boot_time_s": 1700000000, "processes": len(procs), "threads": nthreads, "running": 3, "blocked": 1 if writer > 1e8 else 0,
                    "context_switches_ps": rate(42000 + 9000 * rng.random()), "interrupts_ps": rate(23000 + 4000 * rng.random()),
                    "forks_ps": rate(3 + 9 * rng.random()), "cpu_busy_pct": FIRST if first else round(busy, 2)},
        "cpu": {"model": "Synthetic 16-core CPU (replay)", "freq_driver": "amd-pstate-epp", "governor": "powersave", "logical": ncpu,
                "total": FIRST if first else {"user": round(busy * 0.82, 2), "system": round(busy * 0.18, 2), "iowait": 0.3, "busy": round(busy, 2)},
                "package_temp_c": round(sensors[0][3], 3), "psi": {"some_avg10": psi_cpu, "full_avg10": 0.0, "some_avg60": 1.1, "full_avg60": 0.0},
                "temps": [{"chip": "k10temp", "label": "Tccd1", "value": round(sensors[1][3], 3)}, {"chip": "k10temp", "label": "Tccd2", "value": round(sensors[2][3], 3)}],
                "cpus": cpus},
        "memory": {"total": mem_total, "free": free, "available": available, "used": used, "cached": cached, "buffers": buffers, "shmem": shmem,
                   "slab_reclaimable": int(1.1 * gib), "dirty": int(writer * 0.8), "writeback": int(writer * 0.2), "committed": int(31 * gib),
                   "commit_limit": int(48 * gib), "swap_total": 16 * gib, "swap_used": int(2.1 * gib), "zswap_pool": int(610 * mib),
                   "zswap_stored": int(1.94 * gib), "major_faults_ps": rate(2 * rng.random()), "swap_in_ps": rate(0), "swap_out_ps": rate(3 * wave(t, 50) ** 8),
                   "psi": {"some_avg10": round(0.6 * wave(t, 50) ** 8, 2), "full_avg10": round(0.2 * wave(t, 50) ** 8, 2), "some_avg60": 0.12, "full_avg60": 0.03}},
        "disks": {"devices": disks, "psi": {"some_avg10": round(14 * wave(t, 30) ** 6, 2), "full_avg10": round(9 * wave(t, 30) ** 6, 2), "some_avg60": 2.1, "full_avg60": 1.2}},
        "filesystems": {"skipped_pseudo": 31, "skipped_duplicate": 2, "mounts": filesystems},
        "network": {"rx_bps": rate(sum(n["rx_bps"] for n in nets if not n["loopback"]) if not first else 0), "tx_bps": rate(sum(n["tx_bps"] for n in nets if not n["loopback"]) if not first else 0), "interfaces": nets},
        "connections": {"count": len(conns), "truncated": 0, "owners_unresolved": sum(1 for c in conns if not isinstance(c["pid"], int)), "rows": conns} if conns or not unavailable else {},
        "power": {"sensors": sensor_json, "cpu_package_w": U("needs privilege"), "battery_pct": U("not present"),
                  "gpus": [{"card": "card1", "driver": "amdgpu", "name": "Synthetic GPU", "busy_pct": FIRST if first else round(gpu_busy, 2),
                            "power_w": round(sensors[8][3], 2), "temp_c": round(sensors[6][3], 2), "vram_used": int((1.4 + 3 * wave(t, 35) ** 3) * gib), "vram_total": 16 * gib}]},
        "users": [{"user": "demo", "host": "", "line": "tty1", "pid": 900, "login_time_s": 1700000420},
                  {"user": "demo", "host": "192.0.2.50", "line": "pts/0", "pid": 1020, "login_time_s": 1700360000}],
        "services": {"manager": "init: init", "count": len(services), "scanned": len(procs), "unreadable": 0, "truncated": 0,
                     "rows": [{"name": name, "state": "S", "pid": 200 + k, "start_ticks": 1500 + k * 7,
                               "uid": 0, "loginuid": 4294967295, "user": "uid:0", "uptime_s": 420000 + t - k * 11,
                               "cpu_pct": FIRST if first else round(0.4 * wave(t, 21, k), 2), "rss": (4 + 9 * k % 23) * mib,
                               "cgroup": "/system.slice/" + name + ".service" if k % 2 else "/"} for k, name in enumerate(services)]},
        "apps": {"manager": "pacman", "count": 1234, "total_size": int(14.2 * gib), "largest": [{"name": n, "version": v, "size": s} for n, v, s in packages]},
        "processes": {"count": len(procs), "truncated": 0, "rows": procs},
        "sysinfo": {"hostname": "demo-host", "kernel": "6.12.0-synthetic", "os": "Example Linux (synthetic)", "arch": "x86_64", "init": "init",
                    "package_manager": "pacman", "cpu_model": "Synthetic 16-core CPU (replay)", "logical_cpus": ncpu, "physical_cores": 16,
                    "memory_total": mem_total, "gpus": ["amdgpu Synthetic GPU"]},
        "self": {"wall_ms": round(19.1 + rng.random(), 2), "cpu_ms": round(18.6 + rng.random(), 2), "cpu_pct_of_core": round(1.86 + 0.1 * rng.random(), 2), "syscalls_estimate": 4100},
    }
    return out


def unmeasure(out):
    """Ratio sources explicitly unmeasured: totals must not become zeros."""
    out["memory"]["total"] = U("parse error")
    out["sysinfo"]["memory_total"] = U("parse error")
    out["network"]["rx_bps"] = U("not supported")
    out["network"]["tx_bps"] = U("not supported")
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--frames", type=int, default=150)
    parser.add_argument("--helpers", type=int, default=120, help="extra idle processes (overhead runs use ~1850 for 2k)")
    parser.add_argument("--unavailable", action="store_true", help="topology and connections explicitly unmeasured")
    args = parser.parse_args()
    rng = random.Random(26)
    with open(args.out, "w") as f:
        for t in range(args.frames):
            f.write(json.dumps((unmeasure if args.unavailable else (lambda o: o))(frame(t, rng, args.helpers, args.unavailable)), separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
