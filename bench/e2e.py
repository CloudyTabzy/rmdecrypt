"""End-to-end CLI benchmark for rmdecrypt.

usage: python -I bench/e2e.py <runs> <input_dir> <label=exe[|extra args]> ...

  python -I bench/e2e.py 20 "path/to/game" old=old/rmdecrypt.exe new=zig-out/bin/rmdecrypt.exe "j2=zig-out/bin/rmdecrypt.exe|-j 2"

Each timed run starts with a freshly deleted output directory (deletion is
not timed). Binaries are interleaved round-robin so background noise hits
all of them equally. Prints min / median / p90 wall time per binary and
verifies that every binary produced byte-identical output trees.
Output trees are written next to this script under bench/out_<label>/.
"""
import hashlib, os, shutil, statistics, subprocess, sys, time

SCRATCH = os.path.dirname(os.path.abspath(__file__))


def tree_digest(root):
    h = hashlib.sha256()
    n = 0
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            h.update(os.path.relpath(p, root).replace("\\", "/").encode())
            with open(p, "rb") as f:
                h.update(hashlib.sha256(f.read()).digest())
            n += 1
    return n, h.hexdigest()[:16]


def run_once(exe, extra, inp, out):
    shutil.rmtree(out, ignore_errors=True)
    t0 = time.perf_counter()
    r = subprocess.run([exe, *extra, inp, "--output", out], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    dt = time.perf_counter() - t0
    if r.returncode != 0:
        print(f"  ! {exe} exited {r.returncode}: {r.stderr.decode(errors='replace')[-400:]}")
    return dt


def main():
    runs = int(sys.argv[1])
    inp = sys.argv[2]
    configs = []
    for spec in sys.argv[3:]:
        label, rest = spec.split("=", 1)
        exe, *extra = rest.split("|")
        configs.append((label, exe, [a for a in " ".join(extra).split(" ") if a]))

    results = {label: [] for label, _, _ in configs}
    # Interleave binaries round-robin so drift (thermal, Defender cache,
    # background load) hits all of them equally.
    for label, exe, extra in configs:  # warmup
        for _ in range(2):
            run_once(exe, extra, inp, os.path.join(SCRATCH, "out_" + label))
    for _ in range(runs):
        for label, exe, extra in configs:
            results[label].append(run_once(exe, extra, inp, os.path.join(SCRATCH, "out_" + label)))

    digests = {}
    for label, _, _ in configs:
        digests[label] = tree_digest(os.path.join(SCRATCH, "out_" + label))
    base = None
    for label, exe, extra in configs:
        ts = sorted(results[label])
        p90 = ts[min(len(ts) - 1, int(len(ts) * 0.9))]
        med = statistics.median(ts)
        if base is None:
            base = med
        print(f"{label:>14}: min {ts[0]*1000:7.1f} ms  median {med*1000:7.1f} ms  p90 {p90*1000:7.1f} ms"
              f"  ({base/med:4.2f}x)  files={digests[label][0]} digest={digests[label][1]}")
    if len({d for d in digests.values()}) != 1:
        print("!! OUTPUT MISMATCH between binaries")


if __name__ == "__main__":
    main()
