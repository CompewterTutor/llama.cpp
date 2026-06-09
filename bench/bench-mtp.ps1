param(
    [string]$ConfigFile = "$PSScriptRoot\bench-profiles.json",
    [string]$ResultsFile = "$PSScriptRoot\bench-results.md",
    [string]$ServerExe = "llama-server.exe",
    [string]$ApiKey = "llama",
    [int]$Port = 8033
)

$CsvFile = "$PSScriptRoot\bench-results.csv"
$ShortPrompt = "Summarize this: The quick brown fox jumps over the lazy dog near the river."
$LongPrompt = @"
Summarize this documentation:

llama.cpp provides efficient LLM inference on consumer hardware.
Key features:
- Quantization (Q4_0, Q5_0, Q8_0, IQ, MXFP4)
- GPU backends: CUDA, Vulkan, Metal, SYCL
- Speculative decoding: draft model, MTP, n-gram
- OpenAI-compatible API with continuous batching
- Flash Attention, KV cache quantization
- MTP gives 1.4-2.2x speedup on supported models
- Supports LLaMA, Mistral, Qwen, DeepSeek, Gemma and more
"@

$Prompts = @(@{Label="s"; Text=$ShortPrompt; Tokens=50}, @{Label="l"; Text=$LongPrompt; Tokens=256})

if (-not (Test-Path $ConfigFile)) { Write-Host "Missing $ConfigFile"; exit 1 }
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$groups = $cfg.groups

$flat = @()
for ($g = 0; $g -lt $groups.Count; $g++) {
    $grp = $groups[$g]
    for ($p = 0; $p -lt $grp.profiles.Count; $p++) {
        $flat += @{group=$grp.name; name=$grp.profiles[$p].name; args=$grp.profiles[$p].args}
    }
}

function Send-Chat {
    param($Text, $MaxTokens)
    $body = @{messages=@(@{role="user"; content=$Text}); max_tokens=$MaxTokens; temperature=0.1; stream=$false} | ConvertTo-Json
    try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -Headers @{"Authorization"="Bearer $ApiKey"} -TimeoutSec 180; return $true }
    catch { return $false }
}

function Wait-Server {
    for ($i = 0; $i -lt 30; $i++) {
        try { $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5; if ($r.status -eq "ok") { return $true } } catch {}
        Start-Sleep -Seconds 3
    }
    return $false
}

function Parse-Startup-Log { param([string]$Text)
    $off = [regex]::Match($Text, 'offloaded (\d+)/(\d+) layers to GPU')
    $vbuf = [regex]::Match($Text, '(CUDA0|CPU).*model buffer size = ([\d.]+) MiB')
    $vkvc = [regex]::Match($Text, '(CUDA0|CPU).*KV buffer size = ([\d.]+) MiB')
    $vcom = [regex]::Match($Text, '(CUDA0|CPU).*compute buffer size = ([\d.]+) MiB')
    $vdev = [regex]::Match($Text, 'CUDA0\s*:\s*.+\((\d+) MiB, (\d+) MiB free\)')
    return @{
        layers = if ($off.Success) { "$($off.Groups[1])/$($off.Groups[2])" } else { "-" }
        vram_model = if ($vbuf.Success -and $vbuf.Groups[1].Value -eq "CUDA0") { [double]$vbuf.Groups[2].Value } else { $null }
        vram_kv = if ($vkvc.Success -and $vkvc.Groups[1].Value -eq "CUDA0") { [double]$vkvc.Groups[2].Value } else { $null }
        vram_compute = if ($vcom.Success -and $vcom.Groups[1].Value -eq "CUDA0") { [double]$vcom.Groups[2].Value } else { $null }
        vram_total = if ($vdev.Success) { [int]$vdev.Groups[1].Value } else { $null }
        vram_free = if ($vdev.Success) { [int]$vdev.Groups[2].Value } else { $null }
        ram_model = if ($vbuf.Success -and $vbuf.Groups[1].Value -eq "CPU") { [double]$vbuf.Groups[2].Value } else { $null }
    }
}

function Parse-Timing-Log { param([string]$Text)
    $et = [regex]::Match($Text, '(?<!prompt )eval time =\s+[\d.]+ ms /[ ]+(\d+) tokens \([ ]+[\d.]+ ms per token,[ ]+([\d.]+)')
    $ar = [regex]::Match($Text, 'draft acceptance = ([\d.]+)')
    $fl = [regex]::Match($Text, 'cache state:.+?(\d+) tokens, (\d+) est\)')
    return @{
        tps = if ($et.Success) { [double]$et.Groups[2].Value } else { $null }
        tokens = if ($et.Success) { [int]$et.Groups[1].Value } else { $null }
        acceptance = if ($ar.Success) { [double]$ar.Groups[1].Value } else { $null }
        ctx_lim = if ($fl.Success) { [long]$fl.Groups[1].Value } else { $null }
        ctx_est = if ($fl.Success) { [long]$fl.Groups[2].Value } else { $null }
    }
}

function Kill-Server {
    Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}

function Show-Menu {
    Clear-Host
    Write-Host "===== MTP Benchmark =====" -ForegroundColor Cyan
    Write-Host "Config: $ConfigFile`n"
    $num = 1
    for ($g = 0; $g -lt $groups.Count; $g++) {
        Write-Host "--- $($groups[$g].name) ---" -ForegroundColor Magenta
        for ($p = 0; $p -lt $groups[$g].profiles.Count; $p++) {
            Write-Host "  [$num] $($groups[$g].profiles[$p].name)" -ForegroundColor Yellow
            $num++
        }
        Write-Host ""
    }
    Write-Host "  [A] All   [E] Edit config   [Q] Quit" -ForegroundColor Green
    $input = Read-Host "Select profiles (e.g. '1 3 5' or '1-4')"
    if ($input -eq 'q' -or $input -eq 'Q') { return @() }
    if ($input -eq 'a' -or $input -eq 'A') { return (0..($flat.Count-1)) }
    if ($input -eq 'e' -or $input -eq 'E') { Start-Process notepad $ConfigFile; return @() }
    $sel = @()
    foreach ($p in $input.Split(' ')) {
        if ($p -match '^(\d+)-(\d+)$') { $sel += [int]$matches[1]..[int]$matches[2] | Where-Object { $_ -ge 1 -and $_ -le $flat.Count } }
        elseif ($p -match '^\d+$') { $i = [int]$p; if ($i -ge 1 -and $i -le $flat.Count) { $sel += $i } }
    }
    return ($sel | Sort-Object -Unique | ForEach-Object { $_ - 1 })
}

$csvHeader = "group,profile,prompt,fa,ckv,dckv,nmax,t,td,warm,tps,tokens,accept,ctx_fill,layers,vram_total_mib,vram_free_mib,vram_model_mib,vram_kv_mib,vram_compute_mib,ram_model_mib"
Set-Content -Path $CsvFile -Value $csvHeader -Encoding UTF8
$rows = @()

while ($true) {
    $selected = Show-Menu
    if ($selected.Count -eq 0) { break }

    foreach ($idx in $selected) {
        $f = $flat[$idx]
        $group = $f.group; $name = $f.name; $a = $f.args -join ' '
        $fa   = if ($a -match '-fa\s+(\S+)') { $matches[1] } else { "?" }
        $ckv  = if ($a -match '-ctk\s+(\S+)') { $matches[1] } else { "?" }
        $dkv  = if ($a -match '--spec-draft-type-k\s+(\S+)') { $matches[1] } else { "?" }
        $nmax = if ($a -match '--spec-draft-n-max\s+(\d+)') { $matches[1] } else { "0" }
        $t    = if ($a -match '(?<!-draft)(?<!-batch)-t\s+(\d+)') { $matches[1] } else { "?" }
        $td   = if ($a -match '-td\s+(\d+)|--threads-draft\s+(\d+)') { if ($matches[1]) { $matches[1] } else { $matches[2] } } else { "?" }

        Write-Host "`n--- [$group] $name ---" -ForegroundColor Cyan
        Kill-Server

        # Start server via .NET Process with async log capture
        $global:benchQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ServerExe
        $psi.Arguments = $f.args
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action {
            $d = $event.SourceEventArgs.Data
            if ($d -ne $null) { $global:benchQ.Enqueue($d) }
        } | Out-Null
        Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action {
            $d = $event.SourceEventArgs.Data
            if ($d -ne $null) { $global:benchQ.Enqueue($d) }
        } | Out-Null

        $p.Start() | Out-Null
        $p.BeginErrorReadLine()
        $p.BeginOutputReadLine()

        if (-not (Wait-Server)) {
            Write-Host "  FAIL: server not ready" -ForegroundColor Red
            $p.Kill(); continue
        }
        Start-Sleep -Milliseconds 500

        $drainQ = { param($Q) $lines = @(); $line = $null; while ($Q.TryDequeue([ref]$line)) { $lines += $line }; return $lines -join "`n" }
        $startupText = & $drainQ $global:benchQ
        $info = Parse-Startup-Log -Text $startupText

        foreach ($pm in $Prompts) {
            foreach ($warm in @("cold","warm")) {
                Start-Sleep -Seconds 1
                $ok = Send-Chat -Text $pm.Text -MaxTokens $pm.Tokens
                Start-Sleep -Seconds 3
                $newText = & $drainQ $global:benchQ
                $parsed = Parse-Timing-Log -Text $newText
                $tps = if ($parsed.tps) { "{0:N1}" -f $parsed.tps } else { "-" }
                $tok = if ($parsed.tokens) { $parsed.tokens } else { "-" }
                $acc = if ($parsed.acceptance) { "{0:N2}" -f $parsed.acceptance } else { "-" }
                $fill = if ($parsed.ctx_lim -and $parsed.ctx_est) { "{0:N0}%" -f (($parsed.ctx_lim / $parsed.ctx_est) * 100) } else { "-" }
                Write-Host "  [$warm/$($pm.Label)] $tps t/s  acc=$acc  fill=$fill"
                $rows += "${group}|${name}|${fa}|${ckv}|${nmax}|${t}|${td}|${warm}|$($pm.Label)|$tps|$tok|$acc|$fill|$($info.layers)|$($info.vram_total)|$($info.vram_free)|$($info.vram_model)|$($info.vram_kv)|$($info.vram_compute)|$($info.ram_model)"
                Add-Content -Path $CsvFile -Value "$group,$name,$($pm.Label),$fa,$ckv,$dkv,$nmax,$t,$td,$warm,$tps,$tok,$acc,$fill,$($info.layers),$($info.vram_total),$($info.vram_free),$($info.vram_model),$($info.vram_kv),$($info.vram_compute),$($info.ram_model)" -Encoding UTF8
            }
        }
        $p.Kill()
        Get-EventSubscriber -ErrorAction SilentlyContinue | Unregister-Event -Force -ErrorAction SilentlyContinue
    }

    $md = @"
# MTP Benchmark Results

**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')
**Config:** $ConfigFile
**Server:** $ServerExe

| Model | Profile | FA | Cache | Nmax | T | TD | Run | Prompt | TPS | Tokens | Accept | Ctx Fill | Layers | VRAM Tot | VRAM Free | VRAM Model | VRAM KV | VRAM Cmp | RAM Model |
|-------|---------|----|-------|------|---|---|-----|-------|-----|--------|--------|----------|--------|-----------|------------|---------|----------|-----------|
"@
    foreach ($r in $rows) { $md += "`n| $r |" }
    Set-Content -Path $ResultsFile -Value $md -Encoding UTF8
    Write-Host "`nResults -> $ResultsFile" -ForegroundColor Cyan
    Write-Host "Press Enter to continue..." -NoNewline; Read-Host
}
