#!/usr/bin/env python3
"""Run the SingleStepTests (TomHarte) 65816 vectors against cpu_65c816.v.

Downloads vector JSON on demand from github.com/SingleStepTests/65816,
converts each file to the flat byte format consumed by tb_harte.v, runs
vvp, and aggregates results.

Usage:
  python3 harte_run.py                    # all 256 opcodes, both modes
  python3 harte_run.py a9 6c --mode n     # selected opcodes, native only
  python3 harte_run.py --jobs 8 --maxprint 3
"""
import argparse
import concurrent.futures
import json
import os
import struct
import subprocess
import sys
import urllib.request

RAW = "https://raw.githubusercontent.com/SingleStepTests/65816/main/v1"
HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "harte", "bin")
SIM = os.path.join(HERE, "sim_harte")


def convert(json_bytes, hex_path):
    tests = json.loads(json_bytes)
    out = bytearray(struct.pack("<I", len(tests)))
    for t in tests:
        for st in ("initial", "final"):
            s = t[st]
            out += struct.pack("<HHBHHHBHBB", s["pc"], s["s"], s["p"],
                               s["a"], s["x"], s["y"], s["dbr"], s["d"],
                               s["pbr"], s["e"])
        ri = t["initial"]["ram"]
        rf = t["final"]["ram"]
        out += struct.pack("<HH", len(ri), len(rf))
        for a, v in ri + rf:
            out += struct.pack("<I", a)[:3] + bytes([v])
    with open(hex_path, "w") as f:
        f.write("\n".join(f"{b:02X}" for b in out))
        f.write("\n")
    return len(tests)


def fetch_convert(op, mode):
    hex_path = os.path.join(BIN, f"{op}.{mode}.hex")
    if os.path.exists(hex_path):
        return hex_path
    url = f"{RAW}/{op}.{mode}.json"
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    convert(data, hex_path)
    return hex_path


def run_one(op, mode, maxprint):
    name = f"{op}.{mode}"
    try:
        hex_path = fetch_convert(op, mode)
    except Exception as e:
        return name, -1, -1, f"fetch/convert failed: {e}"
    p = subprocess.run([
        "vvp", SIM, f"+vectors={hex_path}", f"+maxprint={maxprint}"
    ], capture_output=True, text=True, timeout=3600)
    passed = failed = -1
    detail = []
    for line in p.stdout.splitlines():
        if line.startswith("RESULT"):
            _, a, b = line.split()
            passed, failed = int(a), int(b)
        elif line.startswith(("MISMATCH", "  ")):
            detail.append(line)
    return name, passed, failed, "\n".join(detail)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("opcodes", nargs="*", help="hex opcodes (default: all)")
    ap.add_argument("--mode", choices=["n", "e", "both"], default="both")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--maxprint", type=int, default=3)
    args = ap.parse_args()

    os.makedirs(BIN, exist_ok=True)
    subprocess.run(["iverilog", "-g2005", "-o", SIM,
                    os.path.join(HERE, "cpu_65c816.v"),
                    os.path.join(HERE, "tb_harte.v")], check=True)

    ops = args.opcodes or [f"{i:02x}" for i in range(256)]
    modes = ["n", "e"] if args.mode == "both" else [args.mode]
    jobs = [(op, m) for op in ops for m in modes]

    total_p = total_f = 0
    bad = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        futs = {ex.submit(run_one, op, m, args.maxprint): (op, m)
                for op, m in jobs}
        for fut in concurrent.futures.as_completed(futs):
            name, p, f, detail = fut.result()
            if p < 0:
                print(f"{name}: ERROR {detail}")
                bad.append((name, 0, 0, detail))
                continue
            total_p += p
            total_f += f
            if f:
                bad.append((name, p, f, detail))
                print(f"{name}: {p} pass, {f} FAIL")
            else:
                print(f"{name}: {p} pass")

    print(f"\nTOTAL: {total_p} pass, {total_f} fail "
          f"({100.0*total_p/max(1,total_p+total_f):.3f}%)")
    if bad:
        rep = os.path.join(HERE, "harte", "failures.txt")
        with open(rep, "w") as f:
            for name, p, fl, detail in sorted(bad):
                f.write(f"=== {name}: {p} pass, {fl} fail ===\n{detail}\n\n")
        print(f"failure details -> {rep}")


if __name__ == "__main__":
    main()
