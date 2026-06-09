# MTP Benchmark Results

**Generated:** 2026-06-09 17:23
**Config:** C:\Users\hippo\git_repos\forks\llama.cpp\bench\bench-profiles.json
**Server:** llama-server.exe

| Model | Profile | FA | Cache | Nmax | T | TD | Run | Prompt | TPS | Tokens | Accept | Ctx Fill | Layers | VRAM Tot | VRAM Free | VRAM Model | VRAM KV | VRAM Cmp | RAM Model |
|-------|---------|----|-------|------|---|---|-----|-------|-----|--------|--------|----------|--------|-----------|------------|---------|----------|-----------|
| Qwen3.6-35B-A3B|no-mtp-q4km-baseline|on|q8_0|0|8|?|cold|s|22.5|50|-|0%|-|16302|15037|||| |
| Qwen3.6-35B-A3B|no-mtp-q4km-baseline|on|q8_0|0|8|?|warm|s|22.6|50|-|100%|-|16302|15037|||| |
| Qwen3.6-35B-A3B|no-mtp-q4km-baseline|on|q8_0|0|8|?|cold|l|22.2|256|-|100%|-|16302|15037|||| |
| Qwen3.6-35B-A3B|no-mtp-q4km-baseline|on|q8_0|0|8|?|warm|l|22.1|256|-|100%|-|16302|15037|||| |
