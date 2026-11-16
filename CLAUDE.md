# Notes for Claude Code

## Delegating to Ollama cloud models

Cheaper Ollama cloud models are available as helpers. Measurements, limits and results are in
`tools/ollama/README.md`; read "Which model for what", "Limits" and "Writing a task for an agent" before the first use.
Run `tools/ollama/setup.sh` once per fresh container.

- **Coding, debugging, or a review that can be confirmed by experiment:** `tools/ollama/agent.py -d <scratch copy or worktree> [--write] "<task>"`.
  The model works inside Claude Code's harness (reads, edits, runs tests). Default model `glm-5.3-flash`;
  `gpt-oss:120b` is the cheap, fast choice for short tasks with a test to pass.
- **Reading a lot and answering from it:** `tools/ollama/ask.py -r bulk -f <files> "<question>"` (up to ~1M tokens of context).
- **Second opinion, draft, explanation:** `tools/ollama/ask.py -r review|code|research|general|fast ...`. One message, no tools.

Rules:
- Check `tools/ollama/ask.py --balance` before a batch of work. Allowance is shared across all sessions.
- At most 3 calls run at once on the account. Do not fan out wider; the tools enforce 2 by default.
- Never call the API without streaming, and never retry a 502: the first request may still be running and billed.
- Always run agents with an explicit effort level: `agent.py --effort medium` is the default; use `high` for hard
  investigations. Never rely on the harness default (it reasons too little).
- Give every agent task a proof (a test or command), a budget in tool calls, and literal absolute paths
  (`$VAR`, `$(...)` and `&` are rejected by the permission checker). Keep the guards on (`--max-cost-pct`).
- Do not use the Kimi K3 models: same results as the cheap models here at 10-30x the price.
- Verify everything: run the tests and read the diff. Models invent answers about things they were not shown.
- Never put secrets in a prompt. Never give an agent a checkout with uncommitted work you care about.
