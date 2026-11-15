# Notes for Claude Code

## Ollama cloud helpers

Ollama cloud models are available as helpers: see `tools/ollama/README.md`.
Run `tools/ollama/setup.sh` once per fresh container, then
`tools/ollama/ask.py [-r general|code|review|research|fast] [-m m1,m2] [-f file] "prompt"`.
Good uses: a second-opinion review of a non-trivial diff (fan out to 2–3 models),
background research on Simpl-Open / EDC / Gaia-X, first drafts of boilerplate.
Treat answers as unverified: check claims against the code and run the tests
before acting on them. Never send secrets or credentials in prompts.
