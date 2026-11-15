# Ollama cloud models as helpers

Claude Code can hand sub-tasks (reviews, second opinions, drafts, research) to
Ollama cloud models. Every request includes [`BRIEFING.md`](BRIEFING.md) as its
system prompt: the project context and the rules for answering (no invented APIs,
diffs for code, defects first in reviews, a confidence line at the end).

## Setup

```bash
tools/ollama/setup.sh          # Ollama CLI + Python client + local keypair
```

API key: in Claude cloud sessions on this environment, the key is a saved network
secret for `ollama.com`. The proxy adds it to requests, so no variable is needed.
Anywhere else, `export OLLAMA_API_KEY=<key>` (create one at ollama.com → Settings → Keys).

## Use

```bash
tools/ollama/ask.py --list                                   # available cloud models
tools/ollama/ask.py "How does EDC contract negotiation work?"
tools/ollama/ask.py -r review -f simpl-open-lab/ejbca-shim/main.go "Review this"
git diff | tools/ollama/ask.py -r review -m glm-5.3,kimi-k2.7-code "Review this diff"
tools/ollama/ask.py -r code -f path/to/file.py "Add retries to fetch()"
```

| Role (`-r`) | Default model    | For                         |
|-------------|------------------|-----------------------------|
| general     | gpt-oss:120b     | anything                    |
| code        | kimi-k2.7-code   | implementation as a diff    |
| review      | glm-5.3          | finding defects             |
| research    | kimi-k3          | explanations, background    |
| fast        | gpt-oss:20b      | quick, cheap answers        |

`-m a,b,c` sends the same prompt to several models in parallel (handy for
review cross-checks). `--think off|low|high` controls reasoning where the model
supports it. Transient 5xx errors are retried.

Plain CLI against the cloud:

```bash
export OLLAMA_HOST=https://ollama.com OLLAMA_API_KEY=${OLLAMA_API_KEY:-proxy-injected}
ollama run gpt-oss:120b
```

**Model output is advisory.** Claude Code checks claims against the code and
runs the tests before acting on them.
