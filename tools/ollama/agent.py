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

Auth is the same as ask.py: $OLLAMA_API_KEY, or the proxy-injected key in a Claude cloud session.
"""
import argparse, json, os, subprocess, sys, time
from pathlib import Path
import ask as A

READ_TOOLS = ["Read", "Glob", "Grep"]
WRITE_TOOLS = ["Write", "Edit"]
SAFE_BASH = ["Bash(ls:*)", "Bash(cat:*)", "Bash(go test:*)", "Bash(go build:*)", "Bash(go vet:*)", "Bash(gofmt:*)",
             "Bash(python3 -m pytest:*)", "Bash(python3 -m py_compile:*)", "Bash(mvn -q -o test:*)",
             "Bash(git diff:*)", "Bash(git status:*)", "Bash(git log:*)"]


def run(task, workdir, model=None, write=False, read_only=False, allow=(), timeout=600):
    model = model or A.ROLES["agent"]["models"][0]
    cfg = A.STATE / "claude-config"
    home = A.STATE / "claude-home"
    for d in (cfg, home):
        d.mkdir(parents=True, exist_ok=True)
    tools = READ_TOOLS + (WRITE_TOOLS if write else []) + ([] if read_only else ["Bash"])
    allowed = READ_TOOLS + (WRITE_TOOLS if write else []) + ([] if read_only else SAFE_BASH + list(allow))
    env = {k: os.environ[k] for k in ("PATH", "HTTPS_PROXY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "LANG") if k in os.environ}
    env.update(HOME=str(home), TERM="dumb", CLAUDE_CONFIG_DIR=str(cfg), IS_SANDBOX="1", DISABLE_TELEMETRY="1",
               DISABLE_AUTOUPDATER="1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", GOFLAGS="-buildvcs=false",
               GOPATH=os.environ.get("GOPATH", str(Path.home() / "go")),      # reuse the real module cache
               ANTHROPIC_BASE_URL=A.HOST, ANTHROPIC_API_KEY="",
               ANTHROPIC_AUTH_TOKEN=os.environ.get("OLLAMA_API_KEY", "proxy-injected"),
               ANTHROPIC_DEFAULT_HAIKU_MODEL=model, ANTHROPIC_DEFAULT_SONNET_MODEL=model, ANTHROPIC_DEFAULT_OPUS_MODEL=model)
    cmd = ["claude", "-p", task, "--model", model, "--output-format", "json", "--no-session-persistence",
           "--permission-mode", "acceptEdits" if write else "default",
           "--tools", ",".join(tools), "--allowedTools", *allowed]
    t0 = time.time()
    with A.Slot():                       # the agent makes one request at a time: it holds one of the account's slots
        try:
            p = subprocess.run(cmd, cwd=workdir, env=env, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
            out = p.stdout
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            out += f'\n{{"is_error": true, "result": "timed out after {timeout}s"}}'
    r = {"model": model, "role": "agent", "secs": round(time.time() - t0, 1), "status": 500}
    for line in reversed(out.strip().splitlines()):          # the JSON result is the last line
        if line.startswith("{"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            u = d.get("usage") or {}
            r.update(status=500 if d.get("is_error") else 200, content=d.get("result") or "", turns=d.get("num_turns"),
                     in_tokens=(u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0),
                     out_tokens=u.get("output_tokens"), denied=len(d.get("permission_denials") or []))
            break
    else:
        r["error"] = out[-400:]
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
    p.add_argument("--force", action="store_true", help="run even when the session allowance is low")
    a = p.parse_args()
    bal = A.balance()
    if bal and bal.get("session_pct") is not None and bal["session_pct"] < A.MIN_SESSION_PCT and not a.force:
        sys.exit(f"[agent] session allowance is at {bal['session_pct']}%; refusing below {A.MIN_SESSION_PCT}%. Use --force.")
    r = run(a.task, a.dir, a.model, a.write, a.read_only, a.allow, a.timeout)
    print(r.get("content") or f"[error] {r.get('error', '')}")
    print(f"[agent] {r['model']} status={r['status']} turns={r.get('turns')} {r['secs']}s in={r.get('in_tokens')} "
          f"out={r.get('out_tokens')} denied_tool_calls={r.get('denied')}", file=sys.stderr)
    sys.exit(0 if r["status"] == 200 else 1)


if __name__ == "__main__":
    main()
