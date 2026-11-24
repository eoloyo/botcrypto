# Ollama cloud models as helpers

Claude Code (the lead) hands work to cheaper Ollama cloud models and checks what comes back.
Measured on 2026-11-15/16 across all 23 chat models on the account; `bench.py` re-runs it when the model list changes.

## The three ways to delegate

| Tool | What the model gets | Use it for | Typical cost* |
|---|---|---|---|
| `agent.py` | Claude Code's harness: reads files, runs commands, iterates | Coding, debugging, reviews that need experiments | 0.01–0.3% per short task; 0.1–2% per long investigation on the cheap models |
| `ask.py` (one-shot) | One message: briefing + task + attached files. No tools. | Second opinions, drafts, explanations | 0.01–0.5% |
| `ask.py -r bulk` | The same, with very large input | Reading a whole repo or log and answering from it | 0.4–0.7% per 225k tokens read |

\* Share of one session allowance on this account's plan.

**The harness matters more than the model.** One-shot, 17 of 20 models failed a Go task; as agents, 22 of 23
passed it and fixed a buggy parser to 17/17 hidden tests. Give a model tools and a test, and almost any of them works.

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

## Which model for what

| Job | Use | Why |
|---|---|---|
| Long or investigative agent work | `glm-5.3-flash` | Most consistent strong long reviews among cheap models (7 and 9 out of 10); honest; about 1–2% per long run |
| One-shot review, research, code; second agent choice | `deepseek-v4.1-flash` | 8/8 code reasoning, honest, finished every long run (10, 6, 6, 7); about 0.3–0.8% per long run |
| Bulk reading, cheap all-round work | `mimo-v2.6-flash` | 4/4 on the reading test at the lowest price; long reviews vary (7, 7, 4) |
| Short, test-verified coding tasks | `gpt-oss:120b` or `gemma4:31b` | Fastest and cheapest (both tasks in 15–70 s); both invent answers when they lack facts, so never for research |
| Quick first-pass investigation | `inkling-2-small` | Finishes a long review in 45–85 s, honest, medium depth (6, 4) |
| Second opinion when it matters | `glm-5.3` | Fully consistent (7, 7), honest, 8/8; about 5x the price of the flash model for the same result |

Not worth using here: `kimi-k3` and `kimi-k3.1-pro` (same scores as the cheap models at 10–30x the price, and
both invented an answer); `minimax-m3` and `minimax-m3.1-flash` (too slow for long agent work);
`gpt-oss:20b` (weakest reasoning). Exception: `mistral-large-4` is usable at **low** effort only (re-tested 2026-11-24:
debug 17/17 in 36 s, long reviews 5 and 4); at high effort it overthinks and times out. `agent.py` applies a model's
own effort setting from `models.json` automatically. `hy4` (Tencent, 774B, added 2026-11-24) is strong and honest (full
marks on the short suite, long reviews 6 and 7) but slow and about 8x the price of `glm-5.3-flash` for similar results. Every model's verdict is in `models.json` under `best_use`.

## Limits (measured)

| Limit | What happens | What the tools do |
|---|---|---|
| **3 requests at once** (plan limit; Max/Team plans get 10) | Extra requests queue. | A cross-process slot limiter (`OLLAMA_MAX_PARALLEL`, default 2). An agent holds one slot. |
| **30 s to the first byte** | A call that has sent nothing after 30 s (a non-streamed long answer, or a queued call) gets `502 upstream request failed`. The response has none of Ollama's headers, so it most likely comes from the Claude cloud session's own proxy. **The request can keep running at Ollama and is billed.** | Always stream. Never retry a 502; fall back to the role's next model. |
| **Allowance** (this account: a session window and a weekly window, in %) | Every request counts, including ones that failed on our side. Charges appear ~15 s after a call ends. | `--balance`; refuses to start below `OLLAMA_MIN_SESSION_PCT` (10%). |
| **Runaway agents** | An agent that loops re-sends its whole context every turn. One cheap model spent 13% of a session in 10 minutes and produced nothing. | `agent.py` stops a run that repeats one tool call 6 times, passes its token, turn or time budget, or costs more than `--max-cost-pct`. It keeps a transcript of every run. |
| **Thinking** (one-shot) | Needed for good one-shot answers, but an open-ended task can spend ~20,000 tokens thinking first, and thinking counts against the output cap. Only some models honour a "low" level; a few cannot turn thinking off. | On per role, with a 32,000-token cap. `--no-think` for cheap, shallow calls. |
| **Price spread** | The same test suite cost 0.17% on `gemma4:31b` and 11.9% on `kimi-k3`. | Roles use the cheap models. |
| **Context** | 131k tokens (gpt-oss), 262k (gemma4, kimi-k2.x, nemotron), ~1M for most others. A 226k-token prompt was read correctly in 9–12 s. | `ask.py` refuses input that will not fit. |
| **Speed** | 35–530 tokens/s. The same model can be 10x slower from one run to the next. | Timeouts; give long tasks a budget. |
| **Structured output** | Not supported by cloud models (Ollama docs). | Ask for JSON in the prompt and parse leniently. |

## Writing a task for an agent

- **Give it a test or a command that proves the result**, and check it yourself afterwards.
- **Set the effort.** `agent.py` always passes one (`--effort`, default high; some models have their own level in
  `models.json`, e.g. `mistral-large-4` runs at low because it overthinks). The benchmark above ran at the
  harness default, which for the main models behaves like "low": on a test question `deepseek-v4.1-flash` was wrong
  at default and low, right at medium and above. `gemma4:31b` does not reason in this harness at any level.
- **State a budget** ("at most 60 tool calls; write the report after about 45"). Without one, five models ran
  out of time or tokens with nothing written; with one, four of those five finished.
- **Use literal absolute paths.** With a command allow-list, the permission checker rejects `$VAR`, `$(...)`
  and a trailing `&`. Tell the agent to start servers with the Bash tool's run_in_background option.
- **Read the report, not the last message.** Agents often add a closing remark after the report; `agent.py` keeps both.
- **Always verify.** Nine of 23 models invented an answer about files they had not been shown.

## Results

Short suite: implement and debug are agent tasks (debug is graded by 17 hidden tests); code reasoning is predicting
the output of 8 executed programs; reading is 4 questions over ~80k tokens of this repo, one with no answer in it;
honest means it admitted not having been shown some files. The long review is an agent investigating
`ejbca-shim/main.go` by experiment, scored out of 10 against five defects verified by running the shim
(`bench/review_rubric.md`), by two judge models with spot checks; each model ran it twice. "no report" means it
ran out of time (10 minutes) or was stopped by a guard. Suite cost is the share of one session allowance for the
whole short suite.

| Model | Suite cost | Code reasoning | Reads repo | Honest | Short agent tasks (time) | Long review, run 1 / run 2 | Long review time | Tokens per long run |
|---|---|---|---|---|---|---|---|---|
| `glm-5.3-flash` | 0.51% | 7/8 | 4.0/4 | yes | pass (6s + 34s) | 7.0 / 9.0 | 182s / 280s | 1.2M / 2.5M |
| `glm-5.3` | 2.73% | 8/8 | 4.0/4 | yes | pass (10s + 36s) | 7.0 / 7.0 | 200s / 242s | 1.0M / 0.9M |
| `deepseek-v4-pro:0813` | 3.29% | 8/8 | 4.0/4 | no | pass (12s + 49s) | 7.0 / 7.0 | 254s / 220s | 1.0M / 0.7M |
| `kimi-k3.1-pro` | 7.87% | 8/8 | 4.0/4 | no | pass (15s + 228s) | 7.0 / 7.0 | 217s / 264s | 0.5M / 0.5M |
| `kimi-k3` | 11.89% | 8/8 | 4.0/4 | no | pass (9s + 29s) | 7.0 / 7.0 | 168s / 217s | 0.4M / 0.6M |
| `mimo-v2.6-pro` | 1.12% | 7/8 | 4.0/4 | yes | pass (8s + 93s) | 4.5 / 9.0 | 145s / 224s | 0.6M / 0.8M |
| `deepseek-v4.1-flash` | 0.69% | 8/8 | 4.0/4 | yes | pass (6s + 69s) | 6.0 / 7.0 | 253s / 266s | 0.6M / 0.8M |
| `mimo-v2.6-flash` | 0.26% | 7/8 | 4.0/4 | yes | pass (15s + 50s) | 7.0 / 4.0 | 134s / 112s | 0.5M / 0.6M |
| `nemotron-3-ultra` | 0.66% | 8/8 | 3.0/4 | no | pass (40s + 300s) | 4.0 / 7.0 | 407s / 497s | 1.1M / 1.3M |
| `glm-5.2` | 1.79% | 7/8 | 4.0/4 | yes | pass (7s + 44s) | 7.0 / 4.0 | 135s / 153s | 0.6M / 0.7M |
| `inkling-2-small` | 0.71% | 8/8 | 4.0/4 | yes | pass (14s + 35s) | 6.0 / 4.0 | 45s / 71s | 0.5M / 0.9M |
| `muse-spark-open` | 1.44% | 8/8 | 4.0/4 | yes | pass (16s + 18s) | 4.0 / 4.5 | 209s / 133s | 2.2M / 1.6M |
| `gpt-oss:120b` | 0.25% | 7/8 | 3.0/4 | no | pass (12s + 56s) | 4.0 / 4.0 | 86s / 186s | 0.9M / 1.3M |
| `kimi-k2.7-code` | 1.58% | 7/8 | 4.0/4 | no | pass (9s + 140s) | 4.0 / 4.0 | 199s / 215s | 0.9M / 0.6M |
| `nemotron-3-super` | 0.34% | 6/8 | 3.0/4 | yes | pass (15s + 144s) | 4.5 / 1.0 | 115s / 150s | 0.9M / 1.2M |
| `beam` | 0.18% | 8/8 | 4.0/4 | yes | pass (15s + 82s) | 4.0 / no report | 319s / 600s | 1.3M / 0.7M |
| `gpt-oss:20b` | 0.29% | 4/8 | 3.8/4 | no | pass (30s + 209s) | 4.0 / no report | 243s / 600s | 1.5M / 0.5M |
| `kimi-k2.6` | 2.57% | 7/8 | 4.0/4 | no | pass (23s + 156s) | 4.0 / no report | 339s / 601s | 1.1M / 0.6M |
| `gemma4:31b` | 0.17% | 8/8 | 4.0/4 | no | pass (6s + 9s) | 3.0 / no report | 34s / 24s | 0.4M / 0.4M |
| `minimax-m3.1-flash` | 0.2% | 7/8 | 4.0/4 | yes | pass (27s + 103s) | no report / no report | 601s / 600s | 0.3M / 1.5M |
| `mistral-large-4` | 1.34% | 0/8 | 4.0/4 | yes | debug 8/17 (25s + 300s) | no report / no report | 600s / 601s | 0.8M / 0.1M |
| `minimax-m3` | 2.06% | 6/8 | 4.0/4 | yes | pass (87s + 269s) | no report / no report | 600s / 600s | 1.0M / 1.4M |
| `deepseek-v4.1-flash:1017` | 0.45% | 7/8 | 4.0/4 | yes | pass (7s + 53s) | – | – | – |

Long-review cost: 0.1–2% per run for the 11 cheapest models (measured one at a time); about 4% per run on average
for the 11 pricier ones (measured only as a group).

## Other harnesses

Ollama cloud serves the Anthropic, OpenAI-responses and OpenAI-chat APIs at `https://ollama.com`, so other coding
agents work too. Same two tasks (implement, debug), one run each:

| Harness | `deepseek-v4.1-flash` | `gpt-oss:120b` | Notes |
|---|---|---|---|
| Claude Code (`agent.py`) | pass, 17/17, 0.31% | pass, 17/17, 0.15% | Per-command allow-list; largest standing prompt (~25k tokens per request) |
| Codex CLI | pass, 17/17, 0.34% | failed both | Model-sensitive: `gpt-oss:120b` misuses its tool format and the API errors out. OS sandbox (needs bubblewrap; home directory must not be under `/tmp`) |
| OpenCode | pass, 17/17, 0.40% | pass, 17/17, 0.17% | Runs without reasoning unless the model is declared `reasoning: true` and run with `--variant high` (11/17 before that) |
| Cline CLI | pass, 17/17, 0.24% | pass, 17/17, 0.09% | Cheapest. Its Ollama provider only reaches a local Ollama; use the OpenAI-compatible provider with `https://ollama.com/v1` |

Only Claude Code is wired into these tools; the other three were configured by hand for this comparison.

### Do models behave differently across harnesses?

The long review (same task, report written to a file, same two judges), three models, two runs each, at
medium and at high effort: 48 runs, all of which produced a report. Scores out of 10, run 1 / run 2.

| Model, effort | Claude Code | Codex | OpenCode | Cline |
|---|---|---|---|---|
| `glm-5.3-flash`, medium | 9 / 4 | 4 / 4 | 7 / 5.5 | 7 / 4 |
| `glm-5.3-flash`, high | 6 / 7 | 7 / 4 | 9 / 4 | 7 / 7 |
| `deepseek-v4.1-flash`, medium | 7 / 4 | 7 / 9 | 7 / 4 | 9 / 7 |
| `deepseek-v4.1-flash`, high | 9 / 9 | 7 / 6 | 4.5 / 9 | 5 / 7.5 |
| `mimo-v2.6-flash`, medium | 7 / 4 | 2.5 / 4 | 4 / 4 | 7 / 7 |
| `mimo-v2.6-flash`, high | 4.5 / 4 | 4 / 4 | 4.5 / 8 | 5 / 7 |

| Harness (12 runs each) | Mean score | Spread (sd) | Found the nonce defect | Mean time | Mean tool calls |
|---|---|---|---|---|---|
| Cline | 6.6 | 1.3 | 9 of 12 | 244 s | 29 |
| Claude Code | 6.2 | 2.0 | 6 of 12 | 255 s | 52 |
| OpenCode | 5.9 | 1.9 | 6 of 12 | 314 s | 23 |
| Codex | 5.2 | 1.8 | 4 of 12 | 165 s | 26 |

- **The run-to-run swing is bigger than the harness effect.** The same model in the same harness scored 9 and 4.
  A gap of about one point between harness means, with 12 runs each, is suggestive and no more.
- **Cline was the steadiest and Codex the weakest.** In Codex the models stopped soonest (fastest runs, fewest
  findings); `gpt-oss:120b` does not work in Codex at all.
- **The harnesses fail differently.** OpenCode ends the whole run when the model touches a directory outside the
  project (set `"external_directory": "allow"`); Claude Code hands the refusal back to the model. Cline lost a run to
  a dropped connection and did not retry. Claude Code uses about twice the tool calls of the others.
- **High effort helped a little: 5.8 to 6.2 on average,** with every model slightly up, which is within the noise.
  No extra cost showed up: about 0.7–1.1% of a session per long run at either level. The agent role now defaults to high.

## Caveats

- One repository, a handful of tasks, two runs of the long review. Differences of 2–3 points between models are noise:
  the same model scored 10 and 6 on the same task.
- The judges are models. They were spot-checked and are slightly lenient.
- Hosted models change speed and availability from hour to hour: two were down on the first day and up on the second.

```bash
tools/ollama/bench.py run         --out /tmp/bench                       # short suite, all chat models
tools/ollama/bench.py investigate --out /tmp/bench --models a,b --parallel 3 [--name investigate2]
tools/ollama/bench.py regrade     --out /tmp/bench
tools/ollama/bench.py report      --out /tmp/bench [--update-models]
```
