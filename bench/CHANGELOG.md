# Changelog

## [1.0.0] — 2026-06-09

### Added
- `bench-profiles.json` — shared config with 4 model groups (Qwen3.6-35B-A3B, Qwen3.6-27B, Gemma4-27B, Gemma4-9B)
- `bench-mtp.ps1` — PowerShell runner with interactive menu, cold/warm cache testing, markdown+CSV output
- `bench-mtp.sh` — Bash equivalent for WSL/Linux
- `bench-results.md` — auto-generated markdown table with all metrics
- `bench-results.csv` — raw data for further analysis
- `memory.md` — tuning notes and hardware findings

### Metrics captured
- Tokens per second (generation only, excludes prompt eval)
- Draft acceptance rate
- Context fill percentage (fitted vs requested context)
- VRAM total, free, model buffer, KV cache, compute buffer
- RAM model buffer
- GPU layers offloaded
- Cold vs warm prompt cache performance
- Short vs long context performance
