# Notes for Claude Code

## Delegating to Ollama cloud models

Cheaper Ollama cloud models are available as helpers. Measurements, limits and results are in
`tools/ollama/README.md`; read its "Limits" and "What to delegate" sections before the first use.
Run `tools/ollama/setup.sh` once per fresh container.

- **Coding, debugging, or a review that can be confirmed by experiment:** `tools/ollama/agent.py -d <scratch copy or worktree> [--write] "<task>"`.
  The model works inside Claude Code's harness (reads, edits, runs tests). Default model `deepseek-v4.1-flash`.
  Give it a test or a command that proves the result.
- **Reading a lot and answering from it:** `tools/ollama/ask.py -r bulk -f <files> "<question>"` (up to ~1M tokens of context).
- **Second opinion, draft, explanation:** `tools/ollama/ask.py -r review|code|research|general|fast ...`. One message, no tools.

Rules:
- Check `tools/ollama/ask.py --balance` before a batch of work. Allowance is shared across all sessions.
- At most 3 calls run at once on the account. Do not fan out wider; the tools enforce 2 by default.
- Never call the API without streaming, and never retry a 502: the first request may still be running and billed.
- Do not use the Kimi K3 models with thinking for routine work: one review cost 2–5% of a session.
- Verify everything: run the tests and read the diff. One-shot answers contain confident errors.
- Never put secrets in a prompt. Never give an agent a checkout with uncommitted work you care about.
