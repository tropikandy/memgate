#!/usr/bin/env python3
"""swapbench: measurement harness for the local model gateway.

Stdlib only, no third-party dependencies. All paths, URLs, model IDs, and
process-name patterns are supplied by the caller; nothing machine-specific
is hardcoded (R13). See docs/Local-Model-Gateway-Build-Spec.md IF-4, IF-8.

Requires a live gateway to point at (llama-swap, or anything speaking the
same OpenAI-compatible + /api/models/unload surface). Designed to run on
the target machine, not in this sandbox.
"""
import argparse
import json
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request


def now_ms():
    return int(time.time() * 1000)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_vm_available_mb():
    """Available MB via vm_stat: free + inactive + speculative + purgeable."""
    out = subprocess.check_output(["vm_stat"], text=True)
    lines = out.splitlines()
    m = re.search(r"page size of (\d+) bytes", lines[0])
    page_size = int(m.group(1)) if m else 4096

    def pages(label):
        for line in lines:
            if line.startswith(label):
                digits = re.sub(r"[^\d]", "", line.split(":")[1])
                return int(digits) if digits else 0
        return 0

    free = pages("Pages free")
    inactive = pages("Pages inactive")
    speculative = pages("Pages speculative")
    purgeable = pages("Pages purgeable")
    return (free + inactive + speculative + purgeable) * page_size // (1024 * 1024)


def read_used_mb():
    """A rough PhysMem-used figure: wired + active + compressed."""
    out = subprocess.check_output(["vm_stat"], text=True)
    lines = out.splitlines()
    m = re.search(r"page size of (\d+) bytes", lines[0])
    page_size = int(m.group(1)) if m else 4096

    def pages(label):
        for line in lines:
            if line.startswith(label):
                digits = re.sub(r"[^\d]", "", line.split(":")[1])
                return int(digits) if digits else 0
        return 0

    wired = pages("Pages wired down")
    active = pages("Pages active")
    compressed = pages("Pages occupied by compressor")
    return (wired + active + compressed) * page_size // (1024 * 1024)


def matching_pids(pattern):
    try:
        out = subprocess.check_output(
            ["pgrep", "-f", pattern], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return []
    return [p for p in out.split() if p]


class Sampler:
    """1 Hz background sampler of memory and matching PIDs."""

    def __init__(self, proc_pattern, interval=1.0):
        self.proc_pattern = proc_pattern
        self.interval = interval
        self._stop = threading.Event()
        self._thread = None
        self.peak_used_mb = 0
        self.min_available_mb = None
        self.overlap_observed = False
        self.samples = []

    def _run(self):
        while not self._stop.is_set():
            try:
                used = read_used_mb()
                avail = read_vm_available_mb()
                pids = matching_pids(self.proc_pattern)
                self.peak_used_mb = max(self.peak_used_mb, used)
                self.min_available_mb = (
                    avail
                    if self.min_available_mb is None
                    else min(self.min_available_mb, avail)
                )
                if len(pids) > 1:
                    self.overlap_observed = True
                self.samples.append(
                    {"t": now_ms(), "used_mb": used, "available_mb": avail, "pids": pids}
                )
            except Exception as exc:  # pragma: no cover - best-effort sampling
                self.samples.append({"t": now_ms(), "error": str(exc)})
            self._stop.wait(self.interval)

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)


def http_json(method, url, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def unload_all(gateway_url, unload_path):
    try:
        http_json("POST", gateway_url.rstrip("/") + unload_path)
    except (urllib.error.URLError, urllib.error.HTTPError) as exc:
        print(f"warning: unload_all failed: {exc}", file=sys.stderr)


def wait_healthy(gateway_url, model_id, timeout_s):
    deadline = time.time() + timeout_s
    url = gateway_url.rstrip("/") + "/v1/chat/completions"
    body = {
        "model": model_id,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
    }
    while time.time() < deadline:
        try:
            http_json("POST", url, body, timeout=10)
            return True
        except (urllib.error.URLError, urllib.error.HTTPError):
            time.sleep(1)
    return False


def do_swap(gateway_url, proc_pattern, from_model, to_model, unload_path, healthy_timeout, sample_interval):
    sampler = Sampler(proc_pattern, interval=sample_interval)
    sampler.start()

    t0 = now_ms()
    record = {
        "ts": now_iso(),
        "from_model": from_model,
        "to_model": to_model,
        "t_request_sent_ms": 0,
        "t_source_pid_gone_ms": None,
        "t_memory_floor_reached_ms": None,
        "t_target_pid_seen_ms": None,
        "t_target_healthy_ms": None,
        "peak_physmem_mb": None,
        "min_available_mb": None,
        "overlap_observed": False,
        "notes": "",
    }

    # Warm the source model first so there is something to swap away from.
    if from_model:
        wait_healthy(gateway_url, from_model, healthy_timeout)

    t0 = now_ms()
    healthy = wait_healthy(gateway_url, to_model, healthy_timeout)
    record["t_target_healthy_ms"] = now_ms() - t0

    # Best-effort fill-in of PID transition timestamps from the sample log.
    for s in sampler.samples:
        if "error" in s:
            continue
        if record["t_source_pid_gone_ms"] is None and from_model and not s["pids"]:
            record["t_source_pid_gone_ms"] = s["t"] - t0
        if record["t_target_pid_seen_ms"] is None and s["pids"]:
            record["t_target_pid_seen_ms"] = s["t"] - t0

    sampler.stop()
    record["peak_physmem_mb"] = sampler.peak_used_mb
    record["min_available_mb"] = sampler.min_available_mb
    record["overlap_observed"] = sampler.overlap_observed
    if not healthy:
        record["notes"] = f"target model did not become healthy within {healthy_timeout}s"

    return record


def cmd_single(args):
    unload_all(args.gateway, args.unload_path)
    sampler = Sampler(args.proc_pattern, interval=args.interval)
    sampler.start()
    wait_healthy(args.gateway, args.model, args.healthy_timeout)
    end = time.time() + args.duration
    url = args.gateway.rstrip("/") + "/v1/chat/completions"
    while time.time() < end:
        try:
            http_json(
                "POST",
                url,
                {"model": args.model, "messages": [{"role": "user", "content": "ping"}], "max_tokens": 8},
                timeout=30,
            )
        except (urllib.error.URLError, urllib.error.HTTPError) as exc:
            print(f"warning: request failed: {exc}", file=sys.stderr)
        time.sleep(1)
    sampler.stop()
    print(
        json.dumps(
            {
                "ts": now_iso(),
                "model": args.model,
                "peak_physmem_mb": sampler.peak_used_mb,
                "min_available_mb": sampler.min_available_mb,
                "overlap_observed": sampler.overlap_observed,
            }
        )
    )


def cmd_swap(args):
    unload_all(args.gateway, args.unload_path)
    models = [args.model_a, args.model_b]
    for i in range(args.repeat):
        src = models[i % 2]
        dst = models[(i + 1) % 2]
        record = do_swap(
            args.gateway,
            args.proc_pattern,
            src,
            dst,
            args.unload_path,
            args.healthy_timeout,
            args.interval,
        )
        print(json.dumps(record))
        sys.stdout.flush()


def cmd_soak(args):
    unload_all(args.gateway, args.unload_path)
    end = time.time() + args.minutes * 60
    models = [args.model_a, args.model_b]
    i = 0
    while time.time() < end:
        src = models[i % 2]
        dst = models[(i + 1) % 2]
        record = do_swap(
            args.gateway,
            args.proc_pattern,
            src,
            dst,
            args.unload_path,
            args.healthy_timeout,
            args.interval,
        )
        print(json.dumps(record))
        sys.stdout.flush()
        if record["overlap_observed"]:
            print("ALARM: overlap_observed=true during soak", file=sys.stderr)
        i += 1


def cmd_latency(args):
    url = args.gateway.rstrip("/") + "/v1/chat/completions"
    wait_healthy(args.gateway, args.model, args.healthy_timeout)
    times = []
    for _ in range(args.count):
        t0 = time.time()
        try:
            http_json(
                "POST",
                url,
                {"model": args.model, "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1},
                timeout=30,
            )
        except (urllib.error.URLError, urllib.error.HTTPError) as exc:
            print(f"warning: request failed: {exc}", file=sys.stderr)
            continue
        times.append((time.time() - t0) * 1000)
    times.sort()
    median = times[len(times) // 2] if times else None
    print(json.dumps({"ts": now_iso(), "model": args.model, "n": len(times), "median_ms": median, "samples_ms": times}))


def cmd_validate(args):
    with open(args.config) as f:
        criteria = json.load(f) if args.config.endswith(".json") else _load_yaml_lite(f.read())

    failures = []
    print(f"{'criterion':30} {'measured':>12} {'threshold':>12}  verdict")
    for c in criteria.get("criteria", []):
        name = c["name"]
        measured = c.get("measured")
        threshold = c.get("threshold")
        comparator = c.get("comparator", "<=")
        ok = {
            "<=": lambda m, t: m is not None and m <= t,
            "<": lambda m, t: m is not None and m < t,
            ">=": lambda m, t: m is not None and m >= t,
            ">": lambda m, t: m is not None and m > t,
            "==": lambda m, t: m == t,
        }[comparator](measured, threshold)
        verdict = "PASS" if ok else "FAIL"
        if not ok:
            failures.append(name)
        print(f"{name:30} {str(measured):>12} {str(threshold):>12}  {verdict}")

    if failures:
        print(f"\nFAILED: {', '.join(failures)}", file=sys.stderr)
        sys.exit(1)
    print("\nall criteria passed")
    sys.exit(0)


def _load_yaml_lite(_text):
    raise SystemExit(
        "swapbench --validate expects a .json criteria file in this stdlib-only "
        "build (no YAML parser dependency). Author validate.json instead, or "
        "add PyYAML as an explicitly-approved dependency if the no-3rd-party "
        "constraint is relaxed for this one file."
    )


def build_parser():
    p = argparse.ArgumentParser(prog="swapbench")
    p.add_argument("--gateway", default="http://127.0.0.1:8000", help="Gateway base URL")
    p.add_argument("--proc-pattern", default="mtplx", dest="proc_pattern", help="pgrep -f pattern for model processes")
    p.add_argument("--unload-path", default="/api/models/unload", dest="unload_path", help="Management path to unload all models")
    p.add_argument("--interval", type=float, default=1.0, help="Sampler interval in seconds")
    p.add_argument("--healthy-timeout", type=float, default=300, dest="healthy_timeout", help="Seconds to wait for a model to become healthy")

    sub = p.add_subparsers(dest="mode", required=True)

    s = sub.add_parser("single", help="T-11: sustained single-model footprint")
    s.add_argument("--model", required=True)
    s.add_argument("--duration", type=float, default=600)
    s.set_defaults(func=cmd_single)

    s = sub.add_parser("swap", help="T-5/T-10: alternating swap timing")
    s.add_argument("--model-a", required=True, dest="model_a")
    s.add_argument("--model-b", required=True, dest="model_b")
    s.add_argument("--repeat", type=int, default=20)
    s.set_defaults(func=cmd_swap)

    s = sub.add_parser("soak", help="T-12: extended alternating soak")
    s.add_argument("--model-a", required=True, dest="model_a")
    s.add_argument("--model-b", required=True, dest="model_b")
    s.add_argument("--minutes", type=float, default=60)
    s.set_defaults(func=cmd_soak)

    s = sub.add_parser("latency", help="T-17: warm TTFT comparison")
    s.add_argument("--model", required=True)
    s.add_argument("--count", type=int, default=20)
    s.set_defaults(func=cmd_latency)

    s = sub.add_parser("validate", help="IF-8: run a pass/fail validation suite")
    s.add_argument("--config", required=True, help="Path to a validate.json criteria file")
    s.set_defaults(func=cmd_validate)

    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
