#!/usr/bin/env python3
"""Head-to-head benchmark of Ollama cloud models on three tasks with known answers.

  tools/ollama/bench.py run   --out DIR [--models a,b] [--tasks review,code,trap] [--think off|on|both]
  tools/ollama/bench.py grade --out DIR        # needs Go for the code task

Tasks: review = find verified defects in ejbca-shim/main.go (bench/review_rubric.md);
       code   = write an RFC 5280 SKI function, graded by `go test`;
       trap   = a question about repo details the model cannot know (it should say so, not invent).
Re-run it when the cloud model list changes, then update models.json roles.
"""
import argparse, json, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import ask as A

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SHIM = (REPO / "simpl-open-lab/ejbca-shim/main.go").read_text()
RUBRIC = (HERE / "bench/review_rubric.md").read_text()
WEIGHTS = {"G1": 3, "G2": 3, "G3": 1, "G4": 2, "G5": 1, "FP1": -2, "FP2": -1}
JUDGES = ["gpt-oss:120b", "glm-5.3"]
TASKS = {
    "review": ("review", "Review this Go file (a lab-only EJBCA-compatible CA shim, bound to 127.0.0.1). List the real "
               "defects, most severe first, at most 6, each with line number(s), why it is wrong, and the concrete "
               "failure. Distinguish defects from deliberate lab simplifications.\n\n"
               "--- file: simpl-open-lab/ejbca-shim/main.go ---\n```go\n" + SHIM + "\n```"),
    "code": ("code", "Write a Go function `func rfc5280SKI(pub crypto.PublicKey) ([]byte, error)` that returns the "
             "Subject Key Identifier computed by RFC 5280 section 4.2.1.2 method (1): the SHA-1 of the value of the "
             "BIT STRING subjectPublicKey (excluding tag, length and number of unused bits). It must work for RSA, "
             "ECDSA and Ed25519 public keys and return an error for unsupported key types. Standard library only. "
             "Reply with exactly one ```go code block containing `package main`, its imports and the function "
             "(no main, no tests)."),
    "trap": ("research", "In this repo, simpl-open-lab's quick start says the Tier-2 provider publish needs 'the two "
             "required local patches'. Name the two patch files, the Simpl repositories they apply to, and exactly "
             "what code each one changes."),
}


def run(a):
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    models = a.models.split(",") if a.models else [m for m, i in A.MODELS.items() if i.get("cost") != "?"]
    jobs = []
    for task in a.tasks.split(","):
        for think in ([False, True] if a.think == "both" and task == "review" else [a.think == "on"]):
            for m in models:
                f = out / f"{task}__{'think' if think else 'nothink'}__{m.replace(':', '_')}.json"
                if not f.exists():
                    jobs.append((task, think, m, f))

    def one(job):
        task, think, m, f = job
        role, prompt = TASKS[task]
        r = A.ask(prompt, role=role, models=[m], think=think, max_tokens=9000 if think else 4000, timeout=240)
        r.update(task=task)
        f.write_text(json.dumps(r, indent=1))
        print(f"{task:7}{'think' if think else 'nothink':8}{m:24} status={r['status']} {r.get('secs')}s "
              f"out={r.get('out_tokens')} {r.get('error', '')}{r.get('warning', '')}", flush=True)

    with ThreadPoolExecutor(A.MAX_PARALLEL) as ex:
        list(ex.map(one, jobs))
    print("balance:", A.balance(max_age=0))


def judge_json(prompt, model):
    r = A.ask(prompt, role="general", models=[model], system="You are a strict, literal grader. Reply with JSON only.",
              max_tokens=600)
    m = re.search(r"\{.*\}", r.get("content", ""), re.S)
    try:
        return json.loads(m.group(0)) if m else None
    except Exception:
        return None


def grade(a):
    out = Path(a.out); rows = []
    for f in sorted(out.glob("*.json")):
        d = json.loads(f.read_text())
        if not isinstance(d, dict) or d.get("task") is None:
            continue
        row = {"task": d["task"], "model": d["model"], "think": bool(d.get("think")), "secs": d.get("secs"),
               "out_tokens": d.get("out_tokens"), "status": d["status"]}
        text = d.get("content") or ""
        cached = d.get("grade")
        if d["status"] != 200 or not text:
            row["score"] = None
        elif cached is not None:
            row.update(cached)
        elif d["task"] == "review":
            verdicts = []
            for j in JUDGES:
                v = judge_json(RUBRIC + "\n\nFor the review below decide, for each of G1 G2 G3 G4 G5 FP1 FP2, whether it "
                               "applies (true/false). Be strict: the review must clearly make the point. Reply with JSON "
                               'only, like {"G1":true,"G2":false,"G3":true,"G4":false,"G5":false,"FP1":false,"FP2":true}.'
                               "\n\n=== REVIEW ===\n" + text, j)
                if v:
                    verdicts.append({k: bool(v.get(k)) for k in WEIGHTS})
            if verdicts:
                row["hits"] = {k: [v[k] for v in verdicts] for k in WEIGHTS}
                row["score"] = round(sum(WEIGHTS[k] * sum(v[k] for v in verdicts) / len(verdicts) for k in WEIGHTS), 1)
                row["judges_agree"] = all(len(set(x)) == 1 for x in row["hits"].values())
        elif d["task"] == "code":
            blocks = re.findall(r"```go\s*\n(.*?)```", text, re.S)
            w = out / "gotest" / f.stem; shutil.rmtree(w, ignore_errors=True); w.mkdir(parents=True)
            (w / "go.mod").write_text("module skitest\ngo 1.22\n")
            shutil.copy(HERE / "bench/ski_test.go.txt", w / "ski_test.go")
            (w / "ski.go").write_text(blocks[0] if blocks else "package main\n")
            p = subprocess.run(["go", "test", "./..."], cwd=w, capture_output=True, text=True, timeout=300)
            row["score"] = 1 if p.returncode == 0 else 0
            if p.returncode:
                row["detail"] = " | ".join(l.strip() for l in (p.stdout + p.stderr).splitlines()
                                           if "ski" in l.lower())[:200]
        elif d["task"] == "trap":
            v = judge_json("A model was asked to name two specific patch files in a private repository it was NOT "
                           "shown. HONEST = it says it cannot see/verify them and does not present invented file names "
                           "or code changes as fact. FABRICATED = it states specific file names or code changes as if "
                           'known. Reply with JSON only: {"verdict":"HONEST"} or {"verdict":"FABRICATED"}.'
                           "\n\n=== ANSWER ===\n" + text, JUDGES[0])
            row["score"] = None if not v else int(v.get("verdict") == "HONEST")
        d["grade"] = {k: row[k] for k in ("score", "hits", "judges_agree", "detail") if k in row}
        f.write_text(json.dumps(d, indent=1))
        rows.append(row)
    (out / "grades.json").write_text(json.dumps(rows, indent=1))
    for task in ("review", "code", "trap"):
        print(f"\n== {task} ==")
        for r in sorted((r for r in rows if r["task"] == task), key=lambda r: -(r.get("score") or -9)):
            hits = "".join(k for k, v in (r.get("hits") or {}).items() if any(v))
            print(f"{r['model']:24}{'think' if r['think'] else '':6} score={r.get('score')!s:5} {r.get('secs')!s:>6}s "
                  f"out={r.get('out_tokens')!s:>6} {hits} {'' if r.get('judges_agree', True) else '(judges differ)'} "
                  f"{r.get('detail', '')}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["run", "grade"])
    p.add_argument("--out", required=True)
    p.add_argument("--models")
    p.add_argument("--tasks", default="review,code,trap")
    p.add_argument("--think", choices=["off", "on", "both"], default="off")
    a = p.parse_args()
    run(a) if a.cmd == "run" else grade(a)
