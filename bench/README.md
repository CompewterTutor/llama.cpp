# bench/ — MTP Benchmark Runner

Scripts for automated MTP (Multi-Token Prediction) benchmarking on llama-server.

## Files

| File | Purpose |
|------|---------|
| `bench-profiles.json` | Profile configs — model groups with name + arg arrays |
| `bench-mtp.ps1` | PowerShell runner (Windows) |
| `bench-mtp.sh` | Bash runner (WSL/Linux, needs `jq`) |
| `bench-results.md` | Auto-generated markdown results table |
| `bench-results.csv` | Auto-generated CSV with all metrics |
| `memory.md` | Session notes and tuning findings |

## Usage

```powershell
.\bench\bench-mtp.ps1
```

```bash
./bench/bench-mtp.sh
```

Interactive menu with model-group headers and numbered profiles.

### Selection
- `1 3 5` — run specific profiles
- `1-4` — run range
- `A` — run all
- `E` — edit config in Notepad
- `Q` — quit

Each profile tests:
- **cold** — first request (fresh context)
- **warm** — second request (prompt cache hit)
- **short** (s) — 50 token generation target
- **long** (l) — 256 token generation target

## Config Format

```json
{
  "groups": [
    {
      "name": "Model-Group-Name",
      "profiles": [
        {
          "name": "descriptive-profile-name",
          "args": ["-m", "path.gguf", "--flag", "value", ...]
        }
      ]
    }
  ]
}
```

Args are passed directly to `llama-server.exe`. Include full model path, fit params, cache types, speculative flags, etc.

## Output Columns

| Column | Description |
|--------|-------------|
| Model | Group name from config |
| Profile | Profile name |
| FA | Flash attention setting |
| Cache | KV cache type (-ctk/-ctv) |
| Nmax | `--spec-draft-n-max` |
| T | `-t` threads |
| TD | `-td` draft threads |
| Run | cold or warm (prompt cache) |
| Prompt | s (short) or l (long) |
| TPS | Tokens per second (generation only) |
| Tokens | Generated tokens counted |
| Accept | Draft acceptance rate (MTP only) |
| Ctx Fill | Fitted context / requested context |
| Layers | GPU offloaded layers |
| VRAM Tot | Total VRAM (MiB) |
| VRAM Free | Free VRAM at startup (MiB) |
| VRAM Model | Model buffer on GPU (MiB) |
| VRAM KV | KV cache buffer on GPU (MiB) |
| VRAM Cmp | Compute buffer on GPU (MiB) |
| RAM Model | Model buffer in RAM (MiB) |

## Requirements

- **PowerShell**: Windows 10+ / PowerShell 7+
- **Bash**: WSL / Linux with `jq`, `curl`, `grep` (Perl regex)
- **llama-server**: must be in PATH or built locally
