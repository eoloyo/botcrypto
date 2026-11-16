#!/usr/bin/env python3
"""Run an Ollama cloud model as a coding agent: Claude Code's harness (read files, edit, run
commands, iterate), driven by the cloud model instead of Claude.

  tools/ollama/agent.py -d /path/to/workdir "Make `go test ./...` pass"            # read-only + go/test commands
  tools/ollama/agent.py -d work --write --allow "Bash(npm test:*)" "Fix the failing test"
  tools/ollama/agent.py -d work -m deepseek-v4.1-flash --read-only "Where is the OCSP nonce handled?"

One-shot `ask.py` gives a model a single message and no tools; most models fail real coding
tasks that way. Here the model can see compiler errors and test output and fix its own work.

Isolation: the child gets a clean environment and its own config directory (no hooks, plugins,
memory or MCP servers from the calling session), and only the tools listed below. Point -d at
a scratch copy or a git worktree, never at a checkout with uncommitted work you care about, and
verify the result yourself (run the tests, read the diff) before using it.

Guards: a run is stopped when it passes --timeout, --max-input-tokens or --max-turns, repeats the
same tool call six times in a row, or when the session allowance has fallen by --max-cost-pct since
it started. Every run keeps a transcript.

Commands are checked before they run: with an allow-list, `$VAR`, `$(...)` and `&` are rejected.
Tell the agent to use literal absolute paths and the Bash tool's run_in_background option.

Auth is the same as ask.py: $OLLAMA_API_KEY, or the proxy-injected key in a Claude cloud session.
"""
import argparse, json, os, signal, subprocess, sys, threading, time
from pathlib import Path
import ask as A

READ_TOOLS = ["Read", "Glob", "Grep"]
WRITE_TOOLS = ["Write", "Edit"]
SAFE_BASH = ["Bash(ls:*)", "Bash(cat:*)", "Bash(go test:*)", "Bash(go build:*)", "Bash(go vet:*)", "Bash(gofmt:*)",
             "Bash(python3 -m pytest:*)", "Bash(python3 -m unittest:*)", "Bash(python3 -m py_compile:*)", "Bash(mvn -q -o test:*)",
             "Bash(git diff:*)", "Bash(git status:*)", "Bash(git log:*)"]


def run(task, workdir, model=None, write=False, read_only=False, allow=(), timeout=600,
        max_input_tokens=4_000_000, max_turns=80, max_cost_pct=3.0, log=None):
    """Run the agent. It is stopped when it exceeds the time limit, the total input-token budget, the turn
    limit, repeats one tool call six times in a row, or when the account's session allowance has dropped by more than max_cost_pct since it started
    (an agent that keeps re-sending a huge context can otherwise burn 10%+ of a session in minutes).
    The full transcript is kept in `log` (default: ~/.cache/ollama-cloud/transcripts/)."""
    model = model or A.ROLES["agent"]["models"][0]
    cfg = A.STATE / "claude-config"
    home = A.STATE / "claude-home"
    for d in (cfg, home, A.STATE / "transcripts"):
        d.mkdir(parents=True, exist_ok=True)
    log = Path(log) if log else A.STATE / "transcripts" / f"{time.strftime('%Y%m%d-%H%M%S')}-{model.replace(':', '_')}-{os.getpid()}.jsonl"
    tools = READ_TOOLS + (WRITE_TOOLS if write else []) + ([] if read_only else ["Bash"])
    allowed = READ_TOOLS + (WRITE_TOOLS if write else []) + ([] if read_only else SAFE_BASH + list(allow))
    env = {k: os.environ[k] for k in ("PATH", "HTTPS_PROXY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "LANG") if k in os.environ}
    env.update(HOME=str(home), TERM="dumb", CLAUDE_CONFIG_DIR=str(cfg), IS_SANDBOX="1", DISABLE_TELEMETRY="1",
               DISABLE_AUTOUPDATER="1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", GOFLAGS="-buildvcs=false",
               NO_PROXY="localhost,127.0.0.1,::1", no_proxy="localhost,127.0.0.1,::1",   # local services the agent starts
               GOPATH=os.environ.get("GOPATH", str(Path.home() / "go")),      # reuse the real module cache
               ANTHROPIC_BASE_URL=A.HOST, ANTHROPIC_API_KEY="",
               ANTHROPIC_AUTH_TOKEN=os.environ.get("OLLAMA_API_KEY", "proxy-injected"),
               ANTHROPIC_DEFAULT_HAIKU_MODEL=model, ANTHROPIC_DEFAULT_SONNET_MODEL=model, ANTHROPIC_DEFAULT_OPUS_MODEL=model)
    cmd = ["claude", "-p", task, "--model", model, "--output-format", "stream-json", "--verbose", "--no-session-persistence",
           "--permission-mode", "acceptEdits" if write else "default",
           "--tools", ",".join(tools), "--allowedTools", *allowed]
    st = {"usage": {}, "text": "", "result": None, "tools": 0, "last": None, "repeat": 0, "longest": ""}

    def reader(proc, f):
        for line in proc.stdout:
            f.write(line); f.flush()
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") == "assistant":
                m = d.get("message") or {}
                u = m.get("usage") or {}
                st["usage"][m.get("id") or len(st["usage"])] = ((u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
                                                               + (u.get("cache_creation_input_tokens") or 0), u.get("output_tokens") or 0)
                for c in m.get("content") or []:
                    if c.get("type") == "text" and c.get("text", "").strip():
                        st["text"] = c["text"]
                        if len(c["text"]) > len(st["longest"]):
                            st["longest"] = c["text"]
                    if c.get("type") == "tool_use":
                        st["tools"] += 1
                        sig = c.get("name", "") + json.dumps(c.get("input"), sort_keys=True)
                        st["repeat"] = st["repeat"] + 1 if sig == st["last"] else 1
                        st["last"] = sig
            elif d.get("type") == "result":
                st["result"] = d

    def spent():
        return sum(u[0] for u in list(st["usage"].values()))

    b0 = (A.balance(max_age=30) or {}).get("session_pct")
    t0 = time.time(); stop = None; last_check = t0
    with A.Slot(), open(log, "w") as f:      # the agent makes one request at a time: it holds one of the account's slots
        proc = subprocess.Popen(cmd, cwd=workdir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        th = threading.Thread(target=reader, args=(proc, f), daemon=True); th.start()
        while proc.poll() is None:
            time.sleep(1)
            now = time.time()
            if now - t0 > timeout:
                stop = f"timed out after {timeout}s"
            elif spent() > max_input_tokens:
                stop = f"stopped: over {max_input_tokens:,} input tokens in total"
            elif len(st["usage"]) > max_turns:
                stop = f"stopped: over {max_turns} turns"
            elif st["repeat"] >= 6:
                stop = "stopped: it repeated the same tool call 6 times in a row"
            elif b0 is not None and now - last_check > 45:
                last_check = now
                b = (A.balance(max_age=20) or {}).get("session_pct")
                if b is not None and b0 - b > max_cost_pct:
                    stop = f"stopped: the session allowance fell by {round(b0 - b, 2)}% during this run (limit {max_cost_pct}%)"
            if stop:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)       # the agent and anything it started
                except ProcessLookupError:
                    pass
                break
        proc.wait(); th.join(timeout=5)
    d = st["result"] or {}
    r = {"model": model, "role": "agent", "secs": round(time.time() - t0, 1), "turns": len(st["usage"]), "tool_calls": st["tools"],
         "in_tokens": spent(), "out_tokens": sum(u[1] for u in st["usage"].values()),
         "context_peak": max((u[0] for u in st["usage"].values()), default=0), "log": str(log)}
    def answer(final):
        # An agent often writes its report and then adds a short closing remark (e.g. after a background
        # process exits). The harness returns only that last message, so keep the report with it.
        final = final or ""
        if len(st["longest"]) > 3 * len(final) and st["longest"] not in final:
            return st["longest"] + ("\n\n[closing message] " + final if final else "")
        return final

    if stop:
        r.update(status=408, error=stop, content=answer(st["text"]))  # keep what it had written
    elif d and not d.get("is_error"):
        r.update(status=200, content=answer(d.get("result") or st["text"]), denied=len(d.get("permission_denials") or []))
    else:
        r.update(status=500, error=str(d.get("result") or "agent exited without a result")[:400], content=answer(st["text"]))
    A._log(r)
    return r


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("task")
    p.add_argument("-d", "--dir", required=True, help="working directory for the agent (use a scratch copy or worktree)")
    p.add_argument("-m", "--model", help="cloud model (default: first of the 'agent' role in models.json)")
    p.add_argument("--write", action="store_true", help="let the agent create and edit files in the directory")
    p.add_argument("--read-only", action="store_true", help="no shell at all: Read/Glob/Grep only")
    p.add_argument("--allow", action="append", default=[], help='extra permitted command, e.g. "Bash(npm test:*)"')
    p.add_argument("--timeout", type=int, default=600, help="seconds before the agent is stopped")
    p.add_argument("--max-input-tokens", type=int, default=4_000_000, help="stop after this many input tokens in total")
    p.add_argument("--max-turns", type=int, default=80)
    p.add_argument("--max-cost-pct", type=float, default=3.0, help="stop when the session allowance has fallen this many %% during the run")
    p.add_argument("--force", action="store_true", help="run even when the session allowance is low")
    a = p.parse_args()
    bal = A.balance()
    if bal and bal.get("session_pct") is not None and bal["session_pct"] < A.MIN_SESSION_PCT and not a.force:
        sys.exit(f"[agent] session allowance is at {bal['session_pct']}%; refusing below {A.MIN_SESSION_PCT}%. Use --force.")
    r = run(a.task, a.dir, a.model, a.write, a.read_only, a.allow, a.timeout, a.max_input_tokens, a.max_turns, a.max_cost_pct)
    print(r.get("content") or f"[error] {r.get('error', '')}")
    print(f"[agent] {r['model']} status={r['status']} turns={r.get('turns')} {r['secs']}s in={r.get('in_tokens')} "
          f"out={r.get('out_tokens')} peak_context={r.get('context_peak')} {r.get('error') or ''}\n[agent] transcript: {r['log']}", file=sys.stderr)
    sys.exit(0 if r["status"] == 200 else 1)


if __name__ == "__main__":
    main()
