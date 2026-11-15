#!/usr/bin/env python3
"""Ask one or more Ollama cloud models a question with the project briefing.

Examples:
  tools/ollama/ask.py "Explain the Tier-2 mTLS trust model"
  tools/ollama/ask.py -r review -f simpl-open-lab/ejbca-shim/main.go "Review this"
  git diff | tools/ollama/ask.py -r review -m glm-5.3,deepseek-v4-pro:0813 -
  tools/ollama/ask.py --list

Auth: Bearer key from $OLLAMA_API_KEY. In the Claude cloud session the network
proxy injects the saved key for ollama.com, so no variable is needed there.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOST = os.environ.get("OLLAMA_CLOUD_HOST", "https://ollama.com").rstrip("/")
HERE = Path(__file__).resolve().parent
ROLES = {  # role -> (default model, extra instruction)
    "general":  ("gpt-oss:120b",   ""),
    "code":     ("kimi-k2.7-code", "Role: implementer. Produce working code as a unified diff."),
    "review":   ("glm-5.3",        "Role: code reviewer. Find real defects; no style nitpicks."),
    "research": ("kimi-k3",        "Role: researcher. Explain clearly and flag anything unverified."),
    "fast":     ("gpt-oss:20b",    "Be brief."),
}

def _req(path, payload=None, timeout=600):
    headers = {"Content-Type": "application/json"}
    headers["Authorization"] = "Bearer " + os.environ.get("OLLAMA_API_KEY", "proxy-injected")
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(HOST + path, data=data, headers=headers)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.load(resp)

def ask(model, system, prompt, think):
    body = {"model": model, "stream": False,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": prompt}]}
    if think is not None:
        body["think"] = think
    err = ""
    for attempt in range(5):  # transient 5xx, and 429 when the account's concurrency is full
        wait = 5 * (attempt + 1)
        try:
            return model, _req("/api/chat", body)["message"]["content"].strip()
        except urllib.error.HTTPError as e:
            err = f"[error {e.code}] {e.read().decode(errors='replace')[:300]}"
            if e.code < 500 and e.code != 429:
                break
            wait = max(wait, int(e.headers.get("Retry-After") or 0))
        except Exception as e:  # network/timeouts
            err = f"[error] {e}"
        time.sleep(wait)
    return model, err

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("prompt", nargs="?", help="question; '-' reads it from stdin")
    p.add_argument("-m", "--model", help="model, or comma-separated models to fan out to")
    p.add_argument("-r", "--role", choices=ROLES, default="general")
    p.add_argument("-f", "--file", action="append", default=[], help="attach a file (repeatable)")
    p.add_argument("--think", choices=["on", "off", "low", "medium", "high"], help="reasoning control")
    p.add_argument("--no-briefing", action="store_true")
    p.add_argument("--list", action="store_true", help="list available cloud models")
    a = p.parse_args()

    if a.list:
        for m in _req("/api/tags")["models"]:
            print(m["name"])
        return
    if not a.prompt:
        p.error("prompt required")
    prompt = sys.stdin.read() if a.prompt == "-" else a.prompt
    if a.prompt != "-" and not sys.stdin.isatty():
        piped = sys.stdin.read()
        if piped.strip():
            prompt += "\n\n```\n" + piped + "\n```"
    for f in a.file:
        prompt += f"\n\n--- file: {f} ---\n```\n{Path(f).read_text(errors='replace')}\n```"

    default_model, extra = ROLES[a.role]
    system = "" if a.no_briefing else (HERE / "BRIEFING.md").read_text()
    system = (system + "\n\n" + extra).strip()
    think = {"on": True, "off": False}.get(a.think, a.think)
    models = (a.model or default_model).split(",")

    # The account allows only a few concurrent requests; more get 429 or queue into 502s.
    with ThreadPoolExecutor(min(len(models), int(os.environ.get("OLLAMA_MAX_PARALLEL", "2")))) as ex:
        results = list(ex.map(lambda m: ask(m.strip(), system, prompt, think), models))
    for model, text in results:
        if len(results) > 1:
            print(f"\n===== {model} =====")
        print(text)

if __name__ == "__main__":
    main()
