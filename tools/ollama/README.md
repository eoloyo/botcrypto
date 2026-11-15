# Ollama cloud models as helpers

Claude Code (the lead) hands work to cheaper Ollama cloud models and checks what comes back.
Everything here was measured on 2026-11-15; `bench.py` re-runs the comparison when the model list changes.

## The three ways to delegate

| Tool | What the model gets | Use it for | Typical cost* |
|---|---|---|---|
| `agent.py` | Claude Code's harness: reads files, runs commands, iterates | Coding, debugging, reviews that need experiments | 0.01–0.3% per coding task; 1.4% for a 5-minute investigative review |
| `ask.py` (one-shot) | One message: briefing + task + attached files. No tools. | Second opinions, drafts, explanations, first-pass review | 0.01–0.5% |
| `ask.py -r bulk` | The same, with very large input | Reading a whole repo or log and answering from it | 0.4–0.7% per 225k tokens read |

\* Share of one session allowance on this account's plan.

**The harness matters more than the model.** On the same Go task, 17 of 20 models failed one-shot,
5 of 16 still failed with thinking on, and 11 of 11 passed as agents (4–19 s each), including the two
smallest. On the review task no one-shot model found the subtle defects; `deepseek-v4.1-flash` as an
agent found and confirmed all five, plus one more.

```bash
tools/ollama/setup.sh                                   # once per fresh container

# agent: point it at a scratch copy or git worktree, then verify its work yourself
tools/ollama/agent.py -d /path/to/worktree --write "Make \`go test ./...\` pass"
tools/ollama/agent.py -d /path/to/copy --read-only "Where is the OCSP nonce handled?"

# one-shot
tools/ollama/ask.py -r review -f simpl-open-lab/ejbca-shim/main.go "Review this"
git diff | tools/ollama/ask.py -r review --stdin "Review this diff"
tools/ollama/ask.py -r bulk -f big.log "Which requests failed, and why?"

tools/ollama/ask.py --balance        # allowance left
tools/ollama/ask.py --stats          # calls made from this machine
tools/ollama/ask.py --list           # models, cost class, context
```

API key: in Claude cloud sessions on this environment the key is a saved network secret for
`ollama.com` and the proxy adds it to requests. Anywhere else, `export OLLAMA_API_KEY=<key>`.

## Limits (measured)

| Limit | What happens | What the tools do |
|---|---|---|
| **3 requests at once** (plan limit; Max/Team plans get 10) | Extra requests queue. | A cross-process slot limiter (`OLLAMA_MAX_PARALLEL`, default 2). An agent holds one slot. |
| **30 s to the first byte** | A call that has sent nothing after 30 s (a non-streamed long answer, or a queued call) gets `502 upstream request failed`. The response has none of Ollama's headers, so it most likely comes from the Claude cloud session's own proxy. **The request can keep running at Ollama and is billed.** | Always stream. Never retry a 502; fall back to the role's next model. |
| **Allowance** (this account: a session window and a weekly window, in %) | Every request counts, including ones that failed on our side. Charges appear ~15 s after a call ends. | `--balance`; refuses to start below `OLLAMA_MIN_SESSION_PCT` (10%). |
| **Thinking** | Needed for good one-shot answers, but an open-ended task can spend ~20,000 tokens thinking first. Thinking counts against the output cap: with too small a cap the answer is empty. Only some models honour a "low" level; a few cannot turn thinking off. | On per role, with a 32,000-token cap. `--no-think` for cheap, shallow calls. |
| **Price spread** | The same thinking review cost 0.08% on `mimo-v2.6-flash`, 0.27% on `deepseek-v4.1-flash`, and 2.2–5% on `kimi-k3.1-pro`. | Roles use $ and $$ models; the Kimi K3 models are not in any role. |
| **Context** | 131k tokens (gpt-oss), 262k (gemma4, kimi-k2.x, nemotron), ~1M for most others. A 226k-token prompt was read correctly in 9–12 s. | `ask.py` refuses input that will not fit. |
| **Speed** | 35–530 tokens/s, typically 120–230; first token in under 1 s (5–6 s for a 226k-token prompt). | |
| **Aborting** | Closing a stream cancels it; the slot frees ~10 s later. | `--timeout`, then a 10 s pause. |
| **Structured output** | Not supported by cloud models (Ollama docs). | Ask for JSON in the prompt and parse leniently. |

## What to delegate

- **Yes, as an agent:** self-contained coding with a test to pass; reproducing a bug; a review where
  claims can be confirmed by running something.
- **Yes, one-shot:** reading a lot and answering from it (`-r bulk`); a second opinion on a diff;
  drafts and boilerplate; explanations.
- **No:** anything that needs credentials or pushes; decisions about what to build; work where checking
  the answer costs as much as doing it.
- **Always verify.** Run the tests and read the diff. One-shot answers contain confident errors
  (wrong line numbers, bugs that are not bugs), and 5 of 20 models invented an answer to a question
  about files they had not been shown.

## Results

Scores: code = `go test` on the model's function; review = points out of 10 against five defects
verified by running the shim (`bench/review_rubric.md`), judged by two models and spot-checked;
trap = a question about repo files the model was not shown. Times and costs in brackets.

| Model | Cost | Code: one-shot | Code: one-shot + thinking | Code: as agent | Review: one-shot | Review: + thinking (10k cap) | Trap |
|---|---|---|---|---|---|---|---|
| `beam` | $ | pass (6s) | – | – | 0.5 (14s) | – | – (1s) |
| `gemma4:31b` | $ | fail (4s) | fail (9s, 0.01%) | pass (4s, 0.02%) | 3.0 (3s) | – | honest (1s) |
| `gpt-oss:120b` | $ | fail (2s) | pass (4s, 0.01%) | pass (16s, 0.02%) | 4.0 (5s) | 2.5 (8s, 0.02%) | invented (3s) |
| `gpt-oss:20b` | $ | fail (8s) | fail (10s, 0.0%) | pass (12s, 0.01%) | 3.0 (10s) | – | invented (4s) |
| `mimo-v2.6-flash` | $ | fail (4s) | pass (13s, 0.01%) | pass (12s, 0.01%) | 0.0 (1s) | no answer (cap) (48s, 0.05%) | honest (1s) |
| `minimax-m3.1-flash` | $ | fail (15s) | no answer (134s, 0.04%) | – | 4.0 (22s) | – | honest (8s) |
| `nemotron-3-ultra` | $ | fail (11s) | pass (63s, 0.07%) | – | 4.0 (13s) | 3.0 (68s, 0.03%) | invented (27s) |
| `deepseek-v4.1-flash` | $$ | fail (2s) | pass (6s, 0.03%) | pass (9s, 0.05%) | 4.0 (9s) | no answer (cap) (52s, 0.13%) | honest (7s) |
| `glm-5.2` | $$ | fail (5s) | fail (4s, 0.04%) | pass (12s, 0.2%) | 4.0 (5s) | – | invented (2s) |
| `glm-5.3-flash` | $$ | fail (2s) | pass (32s, 0.07%) | pass (4s, 0.03%) | 4.0 (20s) | no answer (cap) (49s, 0.11%) | honest (2s) |
| `inkling-2-small` | $$ | fail (4s) | – | – | 4.0 (24s) | – | honest (4s) |
| `kimi-k2.7-code` | $$ | fail (8s) | pass (32s, 0.11%) | pass (19s, 0.08%) | 3.5 (8s) | no answer (cap) (108s, 0.27%) | honest (2s) |
| `mimo-v2.6-pro` | $$ | fail (4s) | pass (12s, 0.03%) | pass (13s, 0.11%) | 4.0 (8s) | no answer (cap) (73s, 0.15%) | honest (2s) |
| `minimax-m3` | $$ | fail (3s) | pass (28s, 0.08%) | – | 4.0 (7s) | no answer (cap) (68s, 0.19%) | honest (1s) |
| `muse-spark-open` | $$ | pass (3s) | – | – | 3.0 (9s) | – | honest (4s) |
| `deepseek-v4-pro:0813` | $$$ | fail (2s) | pass (12s, 0.1%) | pass (16s, 0.29%) | 4.0 (15s) | 3.5 (58s, 0.5%) | honest (2s) |
| `glm-5.3` | $$$ | fail (3s) | no answer (41s, 0.46%) | pass (9s, 0.22%) | 4.0 (20s) | no answer (cap) (54s, 0.52%) | invented (2s) |
| `mistral-large-4` | $$$ | pass (20s) | – | – | 4.0 (115s) | – | honest (16s) |
| `kimi-k3` | $$$$ | fail (8s) | pass (26s, 0.65%) | – | 4.0 (22s) | – | honest (33s) |
| `kimi-k3.1-pro` | $$$$ | fail (3s) | pass (46s, 0.56%) | – | 1.5 (51s) | no answer (cap) (226s, 2.23%) | honest (2s) |

Review with a harness (`agent.py`, allowed to build and probe the shim):
`deepseek-v4.1-flash` 10/10 plus one new defect, 57 turns, 5 min, 1.37%; `gpt-oss:120b` timed out after 9 min.
With a 30,000-token cap, one-shot thinking reviews scored 4.0 (`deepseek-v4.1-flash`, 0.27%) and 2.5 (`mimo-v2.6-flash`, 0.08%).

Caveats: one run per cell, one repository, three tasks. Treat small differences as noise.

```bash
tools/ollama/bench.py run   --out /tmp/bench --think off     # or on / both; costs allowance
tools/ollama/bench.py grade --out /tmp/bench                 # needs Go
```
