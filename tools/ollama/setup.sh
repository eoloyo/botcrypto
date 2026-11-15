#!/usr/bin/env bash
# Install the Ollama CLI + Python client and point the CLI at Ollama cloud.
# Idempotent. Needs an Ollama API key: in a Claude cloud session it is a saved
# network secret for ollama.com; elsewhere export OLLAMA_API_KEY=<your key>.
set -euo pipefail
command -v zstd >/dev/null || { apt-get update -qq && apt-get install -y -qq zstd; }
command -v ollama >/dev/null || curl -fsSL https://ollama.com/install.sh | sh
pip install -q ollama 2>/dev/null || true
# The CLI needs a local keypair; a short-lived local server generates it.
if [ ! -f ~/.ollama/id_ed25519 ]; then
  (OLLAMA_HOST=127.0.0.1:11434 ollama serve >/dev/null 2>&1 &)
  for _ in $(seq 1 40); do [ -f ~/.ollama/id_ed25519 ] && break; sleep 0.5; done
fi
echo "Done. Use the CLI against the cloud with:"
echo "  export OLLAMA_HOST=https://ollama.com OLLAMA_API_KEY=\${OLLAMA_API_KEY:-proxy-injected}"
echo "  ollama ls; ollama run gpt-oss:120b"
