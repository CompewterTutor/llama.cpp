#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$(dirname "$0")/bench-profiles.json"
RESULTS_FILE="$(dirname "$0")/bench-results.md"
RESULTS_CSV="$(dirname "$0")/bench-results.csv"
SERVER_EXE="llama-server"
API_KEY="llama"
PORT=8033
HOST="127.0.0.1"

SHORT_PROMPT="Summarize this: The quick brown fox jumps over the lazy dog near the river."
LONG_PROMPT="Summarize this documentation:

llama.cpp provides efficient LLM inference on consumer hardware.
Key features:
- Quantization (Q4_0, Q5_0, Q8_0, IQ, MXFP4)
- GPU backends: CUDA, Vulkan, Metal, SYCL
- Speculative decoding: draft model, MTP, n-gram
- OpenAI-compatible API with continuous batching
- Flash Attention, KV cache quantization
- MTP gives 1.4-2.2x speedup on supported models
- Supports LLaMA, Mistral, Qwen, DeepSeek, Gemma and more"

cleanup() { kill "$server_pid" 2>/dev/null || true; rm -f "$log_file" 2>/dev/null || true; }
trap cleanup EXIT

for cmd in curl jq grep sed; do
    if ! command -v "$cmd" &>/dev/null; then echo "Missing: $cmd"; exit 1; fi
done
[ ! -f "$CONFIG_FILE" ] && { echo "Missing: $CONFIG_FILE"; exit 1; }
command -v "$SERVER_EXE" >/dev/null || { echo "Not found in PATH: $SERVER_EXE (build first or install)"; exit 1; }

# Flatten profiles into arrays: group_names[], profile_names[], profile_args[]
# Read from JSON groups
group_count=$(jq '.groups | length' "$CONFIG_FILE")
declare -a flat_group=() flat_name=() flat_args=()

for ((g = 0; g < group_count; g++)); do
    grp_name=$(jq -r ".groups[$g].name" "$CONFIG_FILE")
    prof_count=$(jq ".groups[$g].profiles | length" "$CONFIG_FILE")
    for ((p = 0; p < prof_count; p++)); do
        flat_group+=("$grp_name")
        flat_name+=("$(jq -r ".groups[$g].profiles[$p].name" "$CONFIG_FILE")")
        flat_args+=("$(jq -r ".groups[$g].profiles[$p].args[]" "$CONFIG_FILE" | tr '\n' ' ')")
    done
done

total_profiles=${#flat_name[@]}

send_chat() {
    local text="$1" max_tokens="$2"
    local body
    body=$(jq -n --arg t "$text" --argjson mt "$max_tokens" \
        '{messages:[{role:"user",content:$t}], max_tokens:$mt, temperature:0.1, stream:false}')
    curl -s -X POST "http://$HOST:$PORT/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$body" --max-time 180 >/dev/null 2>&1 || true
}

wait_server() {
    for i in $(seq 1 30); do
        local ok
        ok=$(curl -s "http://$HOST:$PORT/health" --max-time 5 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
        [ "$ok" = "ok" ] && return 0
        sleep 3
    done
    return 1
}

parse_startup() {
    local text="$1"
    local layers vram_free vram_model vram_kv vram_comp ram_model
    layers=$(echo "$text" | grep -oP 'offloaded \K(\d+/\d+)(?= layers to GPU)' | head -1 || echo "-")
    vram_free=$(echo "$text" | grep -oP 'using device cuda0 .+ - \K(\d+)(?= MiB free)' | head -1 || echo "")
    vram_model=$(echo "$text" | grep -oP 'CUDA0.*model buffer size = \K([\d.]+)(?= MiB)' | head -1 || echo "")
    vram_kv=$(echo "$text" | grep -oP 'CUDA0.*KV buffer size = \K([\d.]+)(?= MiB)' | head -1 || echo "")
    vram_comp=$(echo "$text" | grep -oP 'CUDA0.*compute buffer size = \K([\d.]+)(?= MiB)' | head -1 || echo "")
    ram_model=$(echo "$text" | grep -oP 'CPU.*model buffer size = \K([\d.]+)(?= MiB)' | head -1 || echo "")
    echo "${layers}|${vram_free}|${vram_model}|${vram_kv}|${vram_comp}|${ram_model}"
}

parse_slice() {
    local text="$1"
    local tps tok acc ctx_lim ctx_est fill
    tps=$(echo "$text" | grep -oP 'eval time =\s+[\d.]+ ms / +\d+ tokens \( [\d.]+ ms per token, +\K[\d.]+(?= tokens per second)' | tail -1 || echo "")
    tok=$(echo "$text" | grep -oP 'eval time =\s+[\d.]+ ms / +\K(\d+)(?= tokens \()' | tail -1 || echo "")
    acc=$(echo "$text" | grep -oP 'draft acceptance = \K[\d.]+' | tail -1 || echo "")
    ctx_lim=$(echo "$text" | grep -oP 'cache state:.+? \K(\d+) tokens,' | tail -1 || echo "")
    ctx_est=$(echo "$text" | grep -oP 'cache state:.+? \d+ tokens, \K(\d+) est' | tail -1 || echo "")
    fill=""
    if [ -n "$ctx_lim" ] && [ -n "$ctx_est" ] && [ "$ctx_est" -gt 0 ] 2>/dev/null; then
        fill=$((ctx_lim * 100 / ctx_est))"%"
    fi
    tps=${tps:-"-"}; tok=${tok:-"-"}; acc=${acc:-"-"}; fill=${fill:-"-"}
    echo "$tps|$tok|$acc|$fill"
}

get_arg() {
    local args="$1" flag="$2"
    echo "$args" | grep -oP "(?<=$flag )\S+" | head -1 || echo "?"
}

echo "group,profile,prompt,fa,ckv,dckv,nmax,t,td,warm,tps,tokens,accept,ctx_fill,layers,vram_free_mib,vram_model_mib,vram_kv_mib,vram_compute_mib,ram_model_mib" > "$RESULTS_CSV"
rows=()

show_menu() {
    clear
    echo "===== MTP Benchmark ====="
    echo ""
    local num=1
    for ((g = 0; g < group_count; g++)); do
        grp_name=$(jq -r ".groups[$g].name" "$CONFIG_FILE")
        echo "--- $grp_name ---"
        prof_count=$(jq ".groups[$g].profiles | length" "$CONFIG_FILE")
        for ((p = 0; p < prof_count; p++)); do
            pname=$(jq -r ".groups[$g].profiles[$p].name" "$CONFIG_FILE")
            printf "  [%d] %s\n" "$num" "$pname"
            num=$((num + 1))
        done
        echo ""
    done
    echo "  [A] All   [Q] Quit"
    echo ""
    printf "Select profiles (e.g. '1 3 5' or '1-4'): "
    read -r input
    if [ "$input" = "q" ] || [ "$input" = "Q" ]; then return 1; fi
    if [ "$input" = "a" ] || [ "$input" = "A" ]; then
        selected=($(seq 0 $((total_profiles - 1))))
        return 0
    fi
    selected=()
    for part in $input; do
        if echo "$part" | grep -qE '^[0-9]+-[0-9]+$'; then
            lo=${part%-*}; hi=${part#*-}
            for j in $(seq "$lo" "$hi"); do
                [ "$j" -ge 1 ] && [ "$j" -le "$total_profiles" ] && selected+=($((j-1)))
            done
        elif echo "$part" | grep -qE '^[0-9]+$'; then
            [ "$part" -ge 1 ] && [ "$part" -le "$total_profiles" ] && selected+=($((part-1)))
        fi
    done
    selected=($(echo "${selected[@]}" | tr ' ' '\n' | sort -nu | tr '\n' ' '))
    return 0
}

while true; do
    show_menu || break
    [ ${#selected[@]} -eq 0 ] && continue

    for idx in "${selected[@]}"; do
        group="${flat_group[$idx]}"
        name="${flat_name[$idx]}"
        args_str="${flat_args[$idx]}"
        fa=$(get_arg "$args_str" "-fa")
        ckv=$(get_arg "$args_str" "-ctk")
        dkv=$(get_arg "$args_str" "--spec-draft-type-k")
        nmax=$(get_arg "$args_str" "--spec-draft-n-max")
        t=$(get_arg "$args_str" "-t")
        td=$(get_arg "$args_str" "-td")
        [ -z "$td" ] && td=$(get_arg "$args_str" "--threads-draft")
        [ -z "$td" ] && td="?"
        [ -z "$nmax" ] && nmax="0"

        echo ""
        echo "--- [$group] $name ---"

        kill "$server_pid" 2>/dev/null || true; sleep 3
        log_file=$(mktemp)
        # shellcheck disable=SC2086
        "$SERVER_EXE" $args_str > "$log_file" 2>&1 &
        server_pid=$!

        if ! wait_server; then
            echo "  FAIL: server not ready"
            kill "$server_pid" 2>/dev/null || true; continue
        fi

        startup_log=$(cat "$log_file")
        IFS='|' read -r layers vram_free vram_model vram_kv vram_comp ram_model <<< "$(parse_startup "$startup_log")"
        echo "  layers=$layers  VRAM free=${vram_free:-?} MiB  model=${vram_model:-?} MiB  KV=${vram_kv:-?} MiB"

        for prompt_type in "s" "l"; do
            [ "$prompt_type" = "s" ] && prompt_text="$SHORT_PROMPT" && max_tok=50
            [ "$prompt_type" = "l" ] && prompt_text="$LONG_PROMPT" && max_tok=256

            for warm in "cold" "warm"; do
                sleep 1
                log_before=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
                send_chat "$prompt_text" "$max_tok"
                sleep 3

                log_after=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
                if [ "$log_after" -gt "$log_before" ]; then
                    slice=$(dd if="$log_file" bs=1 skip="$log_before" count=$((log_after - log_before)) 2>/dev/null)
                else
                    slice=""
                fi

                IFS='|' read -r tps tok acc fill <<< "$(parse_slice "$slice")"
                echo "  [$warm/$prompt_type] $tps t/s  acc=$acc  fill=$fill"

                rows+=("${group}|${name}|${fa}|${ckv}|${nmax}|${t}|${td}|${warm}|${prompt_type}|${tps}|${tok}|${acc}|${fill}|${layers}|${vram_free}|${vram_model}|${vram_kv}|${vram_comp}|${ram_model}")
                echo "${group},${name},${prompt_type},${fa},${ckv},${dkv},${nmax},${t},${td},${warm},${tps},${tok},${acc},${fill},${layers},${vram_free},${vram_model},${vram_kv},${vram_comp},${ram_model}" >> "$RESULTS_CSV"

                [ "$warm" = "cold" ] && break
            done
        done

        kill "$server_pid" 2>/dev/null || true
        rm -f "$log_file"
    done

    {
        echo "# MTP Benchmark Results"
        echo ""
        echo "**Generated:** $(date '+%Y-%m-%d %H:%M')"
        echo "**Config:** $CONFIG_FILE"
        echo ""
        echo "| Model | Profile | FA | Cache | Nmax | T | TD | Run | Prompt | TPS | Tokens | Accept | Ctx Fill | Layers | VRAM Free | VRAM Model | VRAM KV | VRAM Cmp | RAM Model |"
        echo "|-------|---------|----|-------|------|---|---|-----|-------|-----|--------|--------|----------|--------|-----------|------------|---------|----------|-----------|"
        for r in "${rows[@]}"; do
            echo "| $r |"
        done
    } > "$RESULTS_FILE"

    echo ""
    echo "Results -> $RESULTS_FILE"
    echo "Press Enter to continue..."
    read -r
done
