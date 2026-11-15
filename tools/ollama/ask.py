#!/usr/bin/env python3
"""Delegate a task to an Ollama cloud model, within the account's measured limits.

Examples:
  tools/ollama/ask.py "Explain the Tier-2 mTLS trust model"
  tools/ollama/ask.py -r review -f simpl-open-lab/ejbca-shim/main.go "Review this"
  git diff | tools/ollama/ask.py -r review --stdin "Review this diff"
  tools/ollama/ask.py -r bulk -f big.log "Which requests failed, and why?"
  tools/ollama/ask.py -m glm-5.3,deepseek-v4-pro:0813 --think "Hard question"   # fan-out
  tools/ollama/ask.py --balance | --list | --stats

What it enforces (see README.md "Limits" for the measurements behind each):
  * always streams          - non-streaming requests die with 502 after 30 s and are still billed
  * thinking off by default - thinking multiplies cost 15-25x; opt in with --think
  * output cap              - --max-tokens bounds what one call can cost
  * at most N in flight     - the account runs 3 at once; queued ones 502 after 30 s
  * no retry on 502         - the first attempt may still be running and billed; falls back
                              to the role's next model instead
  * balance guard           - refuses to start when the session allowance is nearly spent

Auth: Bearer key from $OLLAMA_API_KEY. In the Claude cloud session the network proxy
injects the saved key for ollama.com, so no variable is needed there.
"""
import argparse, fcntl, json, os, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOST = os.environ.get("OLLAMA_CLOUD_HOST", "https://ollama.com").rstrip("/")
HERE = Path(__file__).resolve().parent
STATE = Path(os.environ.get("OLLAMA_STATE_DIR", Path.home() / ".cache" / "ollama-cloud"))
MAX_PARALLEL = int(os.environ.get("OLLAMA_MAX_PARALLEL", "2"))      # account limit is 3
MIN_SESSION_PCT = float(os.environ.get("OLLAMA_MIN_SESSION_PCT", "10"))
CONFIG = json.loads((HERE / "models.json").read_text())
ROLES, MODELS = CONFIG["roles"], CONFIG["models"]


def _headers():
    return {"Content-Type": "application/json",
            "Authorization": "Bearer " + os.environ.get("OLLAMA_API_KEY", "proxy-injected")}


def _get(path, timeout=30):
    return json.load(urllib.request.urlopen(urllib.request.Request(HOST + path, headers=_headers()), timeout=timeout))


def balance(max_age=60):
    """(session %, weekly %) remaining, or dollars on the newer plans. Cached: the endpoint allows 10 calls/min."""
    STATE.mkdir(parents=True, exist_ok=True)
    cache = STATE / "balance.json"
    try:
        c = json.loads(cache.read_text())
        if time.time() - c["at"] < max_age:
            return c["value"]
    except Exception:
        pass
    try:
        inc = _get("/api/balance").get("included", {})
    except Exception:
        return None
    if "session" in inc:
        value = {"session_pct": inc["session"]["remaining_percent"], "session_resets": inc["session"]["resets_at"],
                 "weekly_pct": inc["weekly"]["remaining_percent"], "weekly_resets": inc["weekly"]["resets_at"]}
    else:
        value = {"balance_usd": inc.get("balance_usd"), "allowance_usd": inc.get("allowance_usd")}
    cache.write_text(json.dumps({"at": time.time(), "value": value}))
    return value


class Slot:
    """One of MAX_PARALLEL cross-process slots, so parallel ask.py runs never exceed the account's concurrency."""

    def __enter__(self):
        STATE.mkdir(parents=True, exist_ok=True)
        while True:
            for i in range(MAX_PARALLEL):
                f = open(STATE / f"slot{i}.lock", "w")
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.f = f
                    return self
                except OSError:
                    f.close()
            time.sleep(0.5)

    def __exit__(self, *exc):
        self.f.close()


def call(model, messages, think=False, max_tokens=4000, timeout=300):
    """One streamed chat call. Returns a dict with status, content and metrics; never raises."""
    body = {"model": model, "stream": True, "messages": messages, "think": think,
            "options": {"num_predict": max_tokens}}
    r = {"model": model, "think": think, "status": 0, "content": ""}
    for attempt in range(4):
        with Slot():
            t0 = time.time()
            content, thinking, last, aborted = [], 0, {}, False
            try:
                req = urllib.request.Request(HOST + "/api/chat", json.dumps(body).encode(), _headers())
                with urllib.request.urlopen(req, timeout=90) as resp:   # 90 s = max silence between chunks
                    for line in resp:
                        if not line.strip():
                            continue
                        d = json.loads(line)
                        if d.get("error"):
                            r.update(status=500, error=str(d["error"])[:300])
                            break
                        m = d.get("message", {})
                        if "ttft" not in r and (m.get("content") or m.get("thinking")):
                            r["ttft"] = round(time.time() - t0, 2)
                        content.append(m.get("content") or "")
                        thinking += len(m.get("thinking") or "")
                        last = d
                        if time.time() - t0 > timeout:
                            aborted = True
                            break
                r["secs"] = round(time.time() - t0, 1)
                r["content"] = "".join(content).strip()
                if aborted:
                    r.update(status=408, error=f"aborted after {timeout}s (partial output kept)")
                    time.sleep(10)   # the server frees the slot ~10 s after a disconnect
                elif not r.get("error"):
                    r.update(status=200, in_tokens=last.get("prompt_eval_count"), out_tokens=last.get("eval_count"),
                             think_chars=thinking, done_reason=last.get("done_reason"))
                return r
            except urllib.error.HTTPError as e:
                r.update(status=e.code, secs=round(time.time() - t0, 1), error=e.read().decode(errors="replace")[:300])
                if e.code != 429:        # 502: do NOT retry - the first attempt may still run and be billed
                    return r
                wait = int(e.headers.get("Retry-After") or 10)
            except Exception as e:       # network error / no chunk for 90 s
                r.update(status=-1, secs=round(time.time() - t0, 1), error=str(e)[:300])
                return r
        time.sleep(wait)                 # 429 only: rejected before running, so safe to retry
    return r


def ask(prompt, role="general", models=None, system=None, think=None, max_tokens=None, timeout=300):
    """Run `prompt` on the role's first model that answers; fall back down the role's list on failure."""
    cfg = ROLES[role]
    think = cfg.get("think", False) if think is None else think
    max_tokens = max_tokens or cfg.get("max_tokens", 4000)
    if system is None:
        system = ((HERE / "BRIEFING.md").read_text() + "\n\n" + cfg.get("instruction", "")).strip()
    messages = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}]
    est = sum(len(m["content"]) for m in messages) // 3      # rough token estimate
    r = {"status": 0, "error": "no model tried"}
    for model in (models or cfg["models"]):
        ctx = MODELS.get(model, {}).get("ctx", 131072)
        if est + max_tokens > ctx * 0.9:
            r = {"model": model, "status": 413, "error": f"~{est} input tokens will not fit the {ctx}-token context"}
        else:
            r = call(model, messages, think=think, max_tokens=max_tokens, timeout=timeout)
        r["role"] = role
        _log(r)
        if r["status"] == 200:
            if r.get("done_reason") == "length":
                r["warning"] = f"output hit the {max_tokens}-token cap and is truncated; raise --max-tokens"
            if not r["content"]:
                r["warning"] = "empty answer: the token cap was spent on thinking; raise --max-tokens or drop --think"
            return r
        print(f"[ask] {model}: {r['status']} {r.get('error', '')}", file=sys.stderr)
    return r


def _log(r):
    STATE.mkdir(parents=True, exist_ok=True)
    rec = {k: v for k, v in r.items() if k != "content"}
    rec["at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open(STATE / "calls.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")


def _stats():
    rows = {}
    try:
        for line in open(STATE / "calls.jsonl"):
            d = json.loads(line)
            s = rows.setdefault(d.get("model", "?"), {"calls": 0, "failed": 0, "in": 0, "out": 0, "secs": 0.0})
            s["calls"] += 1
            s["failed"] += d.get("status") != 200
            s["in"] += d.get("in_tokens") or 0
            s["out"] += d.get("out_tokens") or 0
            s["secs"] += d.get("secs") or 0
    except FileNotFoundError:
        pass
    print(f"{'model':26}{'calls':>6}{'failed':>7}{'in tok':>10}{'out tok':>10}{'secs':>8}")
    for m, s in sorted(rows.items(), key=lambda kv: -kv[1]["calls"]):
        print(f"{m:26}{s['calls']:>6}{s['failed']:>7}{s['in']:>10}{s['out']:>10}{s['secs']:>8.0f}")
    print("balance:", balance(max_age=0))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("prompt", nargs="?")
    p.add_argument("-r", "--role", choices=ROLES, default="general")
    p.add_argument("-m", "--model", help="override the role's model; comma-separated = ask each one (fan-out)")
    p.add_argument("-f", "--file", action="append", default=[], help="attach a file (repeatable)")
    p.add_argument("--stdin", action="store_true", help="append stdin to the prompt")
    p.add_argument("--no-line-numbers", action="store_true", help="attach files verbatim (e.g. when asking for a patch)")
    p.add_argument("--think", nargs="?", const=True, default=None, help="enable reasoning (optionally low|medium|high). Costly.")
    p.add_argument("--max-tokens", type=int, help="output cap, thinking included (default: per role)")
    p.add_argument("--timeout", type=int, default=300, help="abort the stream after this many seconds")
    p.add_argument("--no-briefing", action="store_true")
    p.add_argument("--force", action="store_true", help="run even when the session allowance is low")
    p.add_argument("--list", action="store_true", help="models known to models.json vs. available in the cloud")
    p.add_argument("--balance", action="store_true", help="remaining allowance")
    p.add_argument("--stats", action="store_true", help="calls made from this machine, per model")
    a = p.parse_args()

    if a.balance:
        return print(json.dumps(balance(max_age=0), indent=1))
    if a.stats:
        return _stats()
    if a.list:
        live = {m["name"] for m in _get("/api/tags")["models"]}
        for name in sorted(live | set(MODELS)):
            info = MODELS.get(name, {})
            flag = "" if name in live else "  (not available now)"
            print(f"{name:26}{info.get('cost', '?'):6}ctx={info.get('ctx', '?'):<9}{info.get('notes', '')}{flag}")
        return
    if not a.prompt:
        p.error("prompt required")

    bal = balance()
    if bal and bal.get("session_pct") is not None and bal["session_pct"] < MIN_SESSION_PCT and not a.force:
        sys.exit(f"[ask] session allowance is at {bal['session_pct']}% (resets {bal['session_resets']}); "
                 f"refusing below {MIN_SESSION_PCT}%. Use --force to override.")

    prompt = a.prompt
    if a.stdin:
        prompt += "\n\n```\n" + sys.stdin.read() + "\n```"
    for f in a.file:      # numbered lines, so the model can cite real line numbers
        text = Path(f).read_text(errors="replace")
        if not a.no_line_numbers:
            text = "\n".join(f"{i:>5}  {line}" for i, line in enumerate(text.splitlines(), 1))
        prompt += f"\n\n--- file: {f} ---\n```\n{text}\n```"
    system = "" if a.no_briefing else None
    think = {"low": "low", "medium": "medium", "high": "high"}.get(a.think, a.think)
    targets = [[m.strip()] for m in a.model.split(",")] if a.model else [None]

    def one(models):
        return ask(prompt, role=a.role, models=models, system=system, think=think,
                   max_tokens=a.max_tokens, timeout=a.timeout)

    with ThreadPoolExecutor(len(targets)) as ex:      # real concurrency is bounded by Slot
        results = list(ex.map(one, targets))
    ok = True
    for r in results:
        if len(results) > 1:
            print(f"\n===== {r.get('model')} =====")
        print(r.get("content") or f"[error {r['status']}] {r.get('error', '')}")
        ok &= r["status"] == 200
        print(f"[ask] {r.get('model')} status={r['status']} {r.get('secs', '?')}s in={r.get('in_tokens')} "
              f"out={r.get('out_tokens')} think={r.get('think')}"
              + (f" WARNING: {r['warning']}" if r.get("warning") else ""), file=sys.stderr)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
