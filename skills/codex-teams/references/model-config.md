# Model Config Notes

`resolve_model.py` reads model from these files in order:
1. `~/.codex/config.toml`
2. `<repo>/.codex/config.toml` (overrides user config)

Within each file, selection order is:
1. `[codex_teams].<role>_model` (`lead/worker/utility`)
2. `[profiles.<profile>].model`
3. `[codex_teams].model`
4. top-level `model`

Example:

```toml
model = "gpt-5.3-codex"

[codex_teams]
lead_model = "gpt-5.3-codex"
worker_model = "gpt-5.3-codex"
utility_model = "gpt-5.3-codex"

[profiles.director]
model = "gpt-5.3-codex"

[profiles.pair]
model = "gpt-5.3-codex"
```
