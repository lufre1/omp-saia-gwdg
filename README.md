# omp-saia-gwdg

GWDG SAIA provider for **omp** (oh-my-pi)

This repo provides an installer that configures [omp](https://omp.sh/) to use the [GWDG SAIA](https://chat-ai.academiccloud.de/) OpenAI-compatible API, giving you access to 14 ready models including Qwen, DeepSeek, GLM, and more.

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-omp-saia-gwdg.sh --yes
```

No key in the environment? Run `bash install-omp-saia-gwdg.sh --yes` and it asks for one
(or pass `--key <value>` / `--key-file <path>`). Reinstalls reuse the key already in
`~/.omp/agent/.env`, so you only ever type it once.

This one-shot installer:
- Installs omp (if missing) via the official installer (`curl -fsSL https://omp.sh/install | sh`)
- Writes `~/.omp/agent/models.yml` registering the GWDG SAIA endpoint with 14 ready models
  (`apiKey: SAIA_API_KEY`, a bare env-var name — the raw key never lands in models.yml)
- Writes `~/.omp/agent/config.yml` making SAIA the default model (`modelRoles.default`)
- Persists the key as `SAIA_API_KEY` in `~/.omp/agent/.env` (chmod 600), which omp loads natively
- With extra keys (`SAIA_API_KEYS_EXTRA="key2,key3"`), routes omp through a local
  key-rotating proxy that swaps keys automatically (see *Multiple keys* below)

Existing `models.yml` and `config.yml` are backed up to `.bak-<timestamp>` first.

Then:

```bash
omp                              # SAIA is the default model
omp --model gwdg-saia/<model>    # pick another SAIA model
omp models gwdg-saia             # list the SAIA models
```

## Multiple keys: automatic key swap

SAIA rate limits are per key (30/min, 200/hour, 1000/day, 3000/month). Give the
installer extra keys and omp swaps to the next one by itself when the active key is
revoked (401/403), drained (its hour/day/month budget nearly used up) or rate limited
(429) — the same rotation the opencode setup does.

```bash
# Extra keys via the environment, so they never show up in `ps`
SAIA_API_KEYS_EXTRA="key2,key3" bash install-omp-saia-gwdg.sh --yes

# Or reuse the extra keys of an opencode setup
bash install-omp-saia-gwdg.sh --yes --extra-keys-file ~/.local/share/opencode/saia-gwdg-keys.json
```

With 2+ keys the installer starts **saia-keyring**, a small local proxy
(`~/.local/share/saia-keyring/saia_keyring.py`, stdlib Python 3), and points the
`baseUrl` in `~/.omp/agent/models.yml` at `http://127.0.0.1:8788/v1` instead of SAIA.
omp keeps sending its usual key; the proxy only serves requests carrying one of the
configured keys and forwards them on the active key. Every harness installed with extra
keys shares the same proxy and key list. Keys are only swapped before a response
starts — a stream in progress is never cut over.

| What | Where |
|------|-------|
| Keys | `~/.config/saia-keyring/keyring.json` (chmod 600), primary key first. A reinstall without extra keys keeps the stored ones; a changed list is backed up to `keyring.json.bak-<timestamp>` |
| Status | `saia-keyring status` — per-key budget, the active key, rejected keys |
| Log | `~/.cache/saia-keyring/proxy.log` |
| Service | systemd user unit `saia-keyring` (Linux), launchd agent `de.gwdg.saia-keyring` (macOS), otherwise a line in your shell rc |
| Turn off | re-run with `--no-keyring`: omp talks to SAIA directly again |

With a single key nothing changes: omp talks to SAIA directly, as before. When every
key is out, omp shows why — e.g. `All 3 SAIA key(s) rejected by SAIA (...) — the key(s)
are revoked or expired`.

## What's included

| File | Purpose |
|------|---------|
| `install-omp-saia-gwdg.sh` | Self-contained installer (generated; never edit directly) |
| `build.sh` | Regenerates the installer from source files |
| `src/add-saia-omp.sh` | Live source script (portable key sourcing) |
| `src/models.txt` | List of 14 ready SAIA models |
| `src/saia_keyring.py`, `src/saia-keyring.sh` | Key-rotating proxy and its install logic, vendored from `opencode-extras/keyring/` (never edit here) |
| `test/fake-saia.py` | Fake SAIA endpoint for the smoke test (not packed) |
| `test/test-install.sh` | Smoke test: config written, key persisted, key swap through the proxy (not packed) |

## Architecture

```
SAIA_API_KEY → install-omp-saia-gwdg.sh → [omp install] → src/add-saia-omp.sh ─┬─ ~/.omp/agent/models.yml
                                                                                ├─ ~/.omp/agent/config.yml
                                                                                └─ ~/.omp/agent/.env
                                                                                          │
                                         (2+ keys: saia-keyring on 127.0.0.1:8788) ──────┤
                                                                                          ▼
                                                              https://chat-ai.academiccloud.de/v1
```

## Maintaining

After changing `src/add-saia-omp.sh` or `src/models.txt`, regenerate the installer
(the keyring files are synced in by `opencode-extras/keyring/sync.sh`, which also rebuilds):

```bash
./build.sh
bash test/test-install.sh   # needs omp and python3; never touches ~/.omp
```

## License

MIT
