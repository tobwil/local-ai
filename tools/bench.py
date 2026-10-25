#!/usr/bin/env python3
"""strata-lite bench: misst lokale LLM-Geschwindigkeit auf Apple Silicon.

Zwei Backends:
  mlx   – lädt das Modell direkt mit mlx-lm (exakte Zahlen + Peak-Speicher)
  http  – jeder OpenAI-kompatible Server (oMLX, dflash serve, mlx_lm.server, LM Studio)

Beispiele:
  bench.py mlx  --model ~/.strata-lite/models/Qwen3.6-35B-A3B-UD-MLX-3bit
  bench.py http --base-url http://127.0.0.1:8000/v1 --model Qwen3.6-35B-A3B-UD-MLX-3bit
  bench.py http ... --contexts 1k,4k,16k --workloads chat,code,context
  bench.py http ... --sustain 10          # 10 Minuten Dauerlast (Drosselung)
  bench.py report                         # alle Ergebnisse vergleichen
"""

from __future__ import annotations

import argparse
import inspect
import json
import platform
import random
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path

RESULTS_DIR = Path(__file__).resolve().parent.parent / "benchmarks" / "results"
TARGET_TPS = 40.0


# --------------------------------------------------------------------------- #
# System-Infos
# --------------------------------------------------------------------------- #

def sh(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def machine_info() -> dict:
    batt = sh("pmset", "-g", "batt")
    return {
        "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "model": sh("sysctl", "-n", "hw.model"),
        "memory_gb": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30),
        "macos": platform.mac_ver()[0],
        "gpu_wired_limit_mb": sh("sysctl", "-n", "iogpu.wired_limit_mb"),
        "power": "AC" if "AC Power" in batt else "Battery",
        "low_power_mode": "lowpowermode         1" in sh("pmset", "-g"),
    }


def swap_used_mb() -> float:
    # "total = 2048.00M  used = 512.25M  free = ..."
    out = sh("sysctl", "-n", "vm.swapusage")
    try:
        return float(out.split("used = ")[1].split("M")[0])
    except (IndexError, ValueError):
        return -1.0


def thermal_state() -> str:
    out = sh("pmset", "-g", "therm")
    for line in out.splitlines():
        if "CPU_Speed_Limit" in line:
            return line.strip()
    return "nominal" if "No thermal warning" in out else out.splitlines()[0] if out else "?"


# --------------------------------------------------------------------------- #
# Workloads
# --------------------------------------------------------------------------- #

def _source_corpus() -> str:
    """Echter, abwechslungsreicher Text: Quellcode aus der Python-Stdlib."""
    import argparse as m1, json.decoder as m2, logging as m3, http.client as m4
    import email.message as m5, tarfile as m6, zipfile as m7, difflib as m8
    return "\n\n".join(inspect.getsource(m) for m in (m1, m2, m3, m4, m5, m6, m7, m8))


CODE_SNIPPET = inspect.getsource(argparse.ArgumentParser._parse_known_args)


def parse_size(s: str) -> int:
    s = s.strip().lower()
    return int(float(s[:-1]) * 1024) if s.endswith("k") else int(s)


def build_prompt(workload: str, context_tokens: int, nonce: str) -> str:
    # Der Nonce am Anfang verhindert, dass Prefix-Caches (oMLX) die Messung verfälschen.
    head = f"[run {nonce}]\n"
    if workload == "chat":
        return head + ("Erkläre in etwa 200 Wörtern, wie ein Mixture-of-Experts-Sprachmodell "
                       "funktioniert und warum es auf Laptops schneller läuft als ein dichtes Modell.")
    if workload == "code":
        return head + ("Benenne in der folgenden Python-Funktion die Variable `namespace` in `ns` um "
                       "und gib die komplette Funktion unverändert sonst zurück, nur Code:\n\n"
                       f"```python\n{CODE_SNIPPET}\n```")
    if workload == "context":
        corpus = _source_corpus()
        # ~4 Zeichen pro Token für Code; die echte Zahl kommt aus der Antwort.
        doc = corpus[: max(0, int(context_tokens * 4))]
        return head + f"```python\n{doc}\n```\n\nFasse in 5 Stichpunkten zusammen, was dieser Code macht."
    raise ValueError(f"unbekannter Workload: {workload}")


# --------------------------------------------------------------------------- #
# Messungen
# --------------------------------------------------------------------------- #

@dataclass
class Sample:
    workload: str
    target_ctx: int
    prompt_tokens: int
    gen_tokens: int
    ttft_s: float
    prompt_tps: float
    decode_tps: float
    peak_mem_gb: float = -1.0
    swap_mb: float = -1.0
    thermal: str = ""
    approx_tokens: bool = False
    t: float = field(default_factory=time.time)


class MLXBackend:
    def __init__(self, model: str, draft: str | None, no_think: bool, temp: float, prefill_step: int):
        import mlx.core as mx
        self.prefill_step = prefill_step
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler
        self.mx = mx
        t0 = time.time()
        self.model, self.tok = load(str(Path(model).expanduser()))
        self.draft = load(str(Path(draft).expanduser()))[0] if draft else None
        print(f"  geladen in {time.time() - t0:.1f}s, Speicher {mx.get_active_memory() / 1e9:.2f} GB")
        self.no_think = no_think
        self.sampler = make_sampler(temp=temp)
        self.label = Path(model).name + (f" + draft {Path(draft).name}" if draft else "")

    def run(self, prompt: str, max_tokens: int) -> dict:
        from mlx_lm import stream_generate
        kw = {"enable_thinking": False} if self.no_think else {}
        text = self.tok.apply_chat_template([{"role": "user", "content": prompt}],
                                            add_generation_prompt=True, tokenize=False, **kw)
        self.mx.reset_peak_memory()
        t0 = time.perf_counter()
        ttft = None
        last = None
        for r in stream_generate(self.model, self.tok, text, max_tokens=max_tokens,
                                 draft_model=self.draft, sampler=self.sampler,
                                 prefill_step_size=self.prefill_step):
            if ttft is None:
                ttft = time.perf_counter() - t0
            last = r
        return {"prompt_tokens": last.prompt_tokens, "gen_tokens": last.generation_tokens,
                "ttft_s": ttft, "prompt_tps": last.prompt_tps, "decode_tps": last.generation_tps,
                "peak_mem_gb": last.peak_memory, "approx_tokens": False}


class HTTPBackend:
    def __init__(self, base_url: str, model: str | None, no_think: bool, temp: float, api_key: str | None,
                 mtp_off: bool = False):
        self.base = base_url.rstrip("/")
        self.headers = {"Content-Type": "application/json"}
        if mtp_off:
            self.headers["X-oMLX-MTP"] = "off"   # oMLX-Patch: MTP nur für diese Anfrage aus
        if api_key:
            self.headers["Authorization"] = f"Bearer {api_key}"
        self.model = model or self._first_model()
        self.no_think = no_think
        self.temp = temp
        self.label = f"{self.model} @ {self.base}"

    def _first_model(self) -> str:
        req = urllib.request.Request(self.base + "/models", headers=self.headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)["data"][0]["id"]

    def run(self, prompt: str, max_tokens: int) -> dict:
        body = {"model": self.model, "stream": True, "max_tokens": max_tokens,
                "temperature": self.temp, "messages": [{"role": "user", "content": prompt}],
                "stream_options": {"include_usage": True}}
        if self.no_think:
            body["chat_template_kwargs"] = {"enable_thinking": False}
        req = urllib.request.Request(self.base + "/chat/completions", data=json.dumps(body).encode(),
                                     headers=self.headers, method="POST")
        t0 = time.perf_counter()
        t_first = t_last = None
        chunks = 0
        usage = None
        with urllib.request.urlopen(req, timeout=1800) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    ev = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if ev.get("usage"):
                    usage = ev["usage"]
                for ch in ev.get("choices") or []:
                    d = ch.get("delta") or {}
                    if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                        now = time.perf_counter()
                        t_first = t_first or now
                        t_last = now
                        chunks += 1
        if t_first is None:
            raise RuntimeError("Server hat keine Tokens gestreamt")
        ttft = t_first - t0
        approx = not (usage and usage.get("completion_tokens"))
        gen = chunks if approx else usage["completion_tokens"]
        ptoks = (usage or {}).get("prompt_tokens") or 0
        decode_time = max(t_last - t_first, 1e-6)
        return {"prompt_tokens": ptoks, "gen_tokens": gen, "ttft_s": ttft,
                "prompt_tps": ptoks / ttft if ptoks else 0.0,
                "decode_tps": (gen - 1) / decode_time if gen > 1 else 0.0,
                "peak_mem_gb": -1.0, "approx_tokens": approx}


def measure(backend, workload: str, ctx: int, max_tokens: int) -> Sample:
    nonce = f"{random.getrandbits(48):012x}"
    res = backend.run(build_prompt(workload, ctx, nonce), max_tokens)
    return Sample(workload=workload, target_ctx=ctx, swap_mb=swap_used_mb(), thermal=thermal_state(), **res)


def fmt_row(s: Sample) -> str:
    ok = "✓" if s.decode_tps >= TARGET_TPS else "·"
    mem = f"{s.peak_mem_gb:5.1f}" if s.peak_mem_gb > 0 else "    -"
    return (f"  {s.workload:8s} {s.prompt_tokens:>7d} {s.gen_tokens:>5d}{'~' if s.approx_tokens else ' '} "
            f"{s.ttft_s:7.2f}s {s.prompt_tps:8.0f} {s.decode_tps:8.1f} {ok}  {mem}  swap {s.swap_mb:.0f}MB"
            f"{'  (Antwort zu kurz, TG ungenau)' if s.gen_tokens < 32 else ''}")


HEADER = "  workload  prompt   gen     TTFT   PP t/s   TG t/s     mem GB"


def run_suite(args, backend) -> list[Sample]:
    samples: list[Sample] = []
    print(f"\n▶ {backend.label}\n  Aufwärmen …")
    backend.run(build_prompt("chat", 0, "warmup"), 16)

    if args.sustain:
        end = time.time() + args.sustain * 60
        print(f"  Dauerlast {args.sustain} min (Workload chat, {args.max_tokens} Tokens pro Runde)\n" + HEADER)
        while time.time() < end:
            s = measure(backend, "chat", 0, args.max_tokens)
            samples.append(s)
            print(fmt_row(s), f" {s.thermal}", flush=True)
        tps = [s.decode_tps for s in samples]
        k = max(1, len(tps) // 5)
        print(f"\n  Start {statistics.mean(tps[:k]):.1f} → Ende {statistics.mean(tps[-k:]):.1f} tok/s "
              f"({(statistics.mean(tps[-k:]) / statistics.mean(tps[:k]) - 1) * 100:+.0f} %)")
        return samples

    print(HEADER)
    for wl in args.workloads.split(","):
        ctxs = [parse_size(c) for c in args.contexts.split(",")] if wl == "context" else [0]
        for ctx in ctxs:
            try:
                reps = [measure(backend, wl, ctx, args.max_tokens) for _ in range(args.repeat)]
            except (RuntimeError, urllib.error.HTTPError) as e:
                # Typisch: Metal-OOM bei langem Kontext. Größere Kontexte gar nicht erst versuchen.
                print(f"  {wl:8s} ~{ctx:>6d}  ✗ abgebrochen: {str(e).splitlines()[0][:90]}")
                break
            for s in reps:
                samples.append(s)
            med = sorted(reps, key=lambda s: s.decode_tps)[len(reps) // 2]
            print(fmt_row(med), flush=True)
    return samples


def save(args, label: str, samples: list[Sample]) -> Path:
    RESULTS_DIR.mkdir(exist_ok=True)
    tag = args.tag or label.split(" @ ")[0].split(" + ")[0]
    path = RESULTS_DIR / f"{time.strftime('%Y%m%d-%H%M%S')}-{''.join(c if c.isalnum() or c in '-._' else '_' for c in tag)}.json"
    path.write_text(json.dumps({"label": label, "tag": tag, "backend": args.cmd, "machine": machine_info(),
                                "args": {k: v for k, v in vars(args).items() if k != "api_key"},
                                "samples": [asdict(s) for s in samples]}, indent=2, ensure_ascii=False))
    return path


def report(_args) -> None:
    files = sorted(RESULTS_DIR.glob("*.json"))
    if not files:
        print("Noch keine Ergebnisse in", RESULTS_DIR)
        return
    print(f"{'Lauf':44s} {'Workload':12s} {'Prompt':>7s} {'TG t/s':>7s} {'PP t/s':>7s} {'TTFT':>6s} {'Mem':>5s}")
    for f in files:
        d = json.loads(f.read_text())
        groups: dict[tuple, list] = {}
        for s in d["samples"]:
            groups.setdefault((s["workload"], s["target_ctx"]), []).append(s)
        name = f"{d['tag']} [{d['backend']}{', Akku' if d['machine'].get('power') == 'Battery' else ''}]"
        for (wl, ctx), ss in groups.items():
            tg = statistics.median(s["decode_tps"] for s in ss)
            pp = statistics.median(s["prompt_tps"] for s in ss)
            ttft = statistics.median(s["ttft_s"] for s in ss)
            pt = int(statistics.median(s["prompt_tokens"] for s in ss))
            mem = max(s["peak_mem_gb"] for s in ss)
            label = wl + (f"@{ctx // 1024}k" if wl == "context" else "")
            print(f"{name[:44]:44s} {label:12s} {pt:7d} {tg:7.1f}{'✓' if tg >= TARGET_TPS else ' '}"
                  f"{pp:7.0f} {ttft:5.1f}s {f'{mem:.1f}' if mem > 0 else '-':>5}")
            name = ""


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--workloads", default="chat,code,context", help="chat,code,context")
        sp.add_argument("--contexts", default="1k,4k,8k,16k", help="Kontextlängen für 'context'")
        sp.add_argument("--max-tokens", type=int, default=256)
        sp.add_argument("--repeat", type=int, default=2, help="Wiederholungen pro Messpunkt (Median)")
        sp.add_argument("--temp", type=float, default=0.0)
        sp.add_argument("--no-think", action="store_true", help="Thinking-Modus abschalten (Qwen)")
        sp.add_argument("--sustain", type=float, default=0, help="Dauerlast-Test in Minuten")
        sp.add_argument("--tag", help="Name des Laufs im Report")

    m = sub.add_parser("mlx", help="Modell direkt mit mlx-lm laden")
    m.add_argument("--model", required=True)
    m.add_argument("--draft", help="kleines Draft-Modell für spekulatives Dekodieren")
    m.add_argument("--prefill-step", type=int, default=2048,
                   help="Prompt-Häppchen in Tokens; kleiner = weniger Spitzenspeicher bei langem Kontext")
    common(m)

    h = sub.add_parser("http", help="OpenAI-kompatiblen Server messen")
    h.add_argument("--base-url", default="http://127.0.0.1:8000/v1")
    h.add_argument("--model", help="Modell-ID (Standard: erstes aus /models)")
    h.add_argument("--api-key")
    h.add_argument("--mtp-off", action="store_true", help="Header X-oMLX-MTP: off senden (MTP pro Anfrage aus)")
    common(h)

    sub.add_parser("report", help="Ergebnisse vergleichen")
    args = p.parse_args()

    if args.cmd == "report":
        return report(args)

    info = machine_info()
    print(f"{info['chip']} · {info['memory_gb']} GB · macOS {info['macos']} · {info['power']}"
          f"{' · Stromsparmodus!' if info['low_power_mode'] else ''}")
    if info["power"] == "Battery":
        print("  Hinweis: Akkubetrieb – für vergleichbare Zahlen ans Netzteil.")

    try:
        backend = (MLXBackend(args.model, args.draft, args.no_think, args.temp, args.prefill_step) if args.cmd == "mlx"
                   else HTTPBackend(args.base_url, args.model, args.no_think, args.temp, args.api_key,
                               getattr(args, "mtp_off", False)))
        samples = run_suite(args, backend)
    except urllib.error.URLError as e:
        sys.exit(f"Server nicht erreichbar ({args.base_url}): {e}")
    except KeyboardInterrupt:
        sys.exit("\nabgebrochen")
    print(f"\n  gespeichert: {save(args, backend.label, samples)}")


if __name__ == "__main__":
    main()
