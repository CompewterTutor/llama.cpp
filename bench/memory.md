# MTP Benchmark Memory

## Hardware
- GPU: RTX 5070 Ti (16302 MiB, ~15037 free at idle)
- CPU: AMD Ryzen 9 9950X3D 16-Core
- Platform: Windows

## Key Findings

### MTP on MoE (Qwen3.6-35B-A3B)
- Sweet spot: `--spec-draft-n-max 4` with IQ4_XS quant
- Best result: ~122 t/s peak, ~115 avg (vs 84 baseline = +37%)
- Acceptance rate peaked at 91% with n_max=2, 83% with n_max=4
- Higher draft count compensates for lower acceptance (more tokens verified per batch)
- q8_0 KV cache outperforms q4_0 for MTP (draft does 2x KV accesses, q4_0 decode latency compounds)
- Q4_K_M model quant gave better MTP results than IQ3_S (MTP head precision matters)

### Critical Parameters
- `--spec-draft-type-k q8_0 --spec-draft-type-v q8_0` — draft KV cache defaults to f16; must match main cache to avoid VRAM pressure
- `-fa on` — required for Blackwell (5070 Ti supports native FP4 flash attention)
- `-t 8 --cpu-mask 0xFF` — vcache topology on 9950X3D; first 8 cores share L3 cache
- `-td 8` — draft threads same as main; fewer threads can help if oversubscribed

### MoE MTP Speedup
- MoE models gain 1.15-1.25x at best (vs 1.4-2.2x for dense models like Qwen3.6-27B)
- Each MTP forward pass is cheaper on MoE (3B active params) but acceptance rate drops faster
- n_max=4 sweet spot vs n_max=2-3 for dense models

### VRAM Budget (16GB)
| Component | Size |
|-----------|------|
| Model (Q4_K_M) | ~22.7 GB file (most in RAM) |
| Model (IQ4_XS) | ~18.2 GB file |
| KV cache (q8_0, 128k) | ~3-5 GB on GPU |
| MTP draft KV (q8_0) | same again as main KV |
| OS/other | ~1-2 GB |
- Model must be split across RAM + VRAM at 22.7 GB
- IQ4_XS allows more GPU layers + KV cache
- MTP draft KV doubles KV memory vs baseline

### Config Profiles
- `no-mtp-q4km-baseline` — Q4_K_M, no MTP, CPU-only (no -ngl set)
- `mtp-iq4xs-n2-q8kv` — IQ4_XS, n_max=2, q8_0 KV
- `mtp-iq4xs-n4-q8kv` — IQ4_XS, n_max=4, q8_0 KV (best found)
- `mtp-iq4xs-n4-q4kv` — IQ4_XS, n_max=4, q4_0 KV (slower due to decode overhead)
- `mtp-iq4xs-n4-t8td4` — IQ4_XS, n_max=4, 8 main / 4 draft threads

### Tuning Strategy
1. Match draft KV type to main KV type first
2. Sweep n_max from 1-6
3. Check acceptance rate (>0.7 for net gain)
4. Compare warm vs cold cache results
5. Test short vs long context separately (fill rate matters)
6. VRAM free before/after loading shows true memory pressure
