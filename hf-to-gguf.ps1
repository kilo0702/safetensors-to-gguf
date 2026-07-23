<#
.SYNOPSIS
    從 Hugging Face 下載 safetensors 模型並轉成 GGUF（可同時輸出多種量化）。

.EXAMPLE
    .\hf-to-gguf.ps1 huihui-ai/Huihui-Qwen-AgentWorld-35B-A3B-abliterated
    # 預設輸出 Q8_0

.EXAMPLE
    .\hf-to-gguf.ps1 Qwen/Qwen3-8B -Quants bf16,Q8_0,Q4_K_M
    # bf16 母帶 + 兩種量化一次做完

.EXAMPLE
    .\hf-to-gguf.ps1 someorg/some-model -Quants Q4_K_M -KeepBf16 -Root D:\models
#>
[CmdletBinding()]
param(
    # HF repo，格式 org/name
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^[^/\s]+/[^/\s]+$')]
    [string]$Repo,

    # 要產出的格式。bf16 = 無損母帶，其餘為量化
    [ValidateSet('bf16','f16','Q8_0','Q6_K','Q5_K_M','Q5_K_S','Q4_K_M','Q4_K_S','Q3_K_M','IQ4_XS','IQ4_NL')]
    [string[]]$Quants = @('Q8_0'),

    [string]$Root     = 'C:\models',
    [string]$LlamaBin = 'C:\Users\HULab\Desktop\llama-b10092-bin-win-cuda-13.3-x64',

    # 即使 -Quants 沒列 bf16 也保留母帶（之後想壓別的量化不必重下載）
    [switch]$KeepBf16,
    # 轉完刪掉 HF 原始 safetensors
    [switch]$DeleteSafetensors,
    # 已有本地資料夾，跳過下載
    [switch]$NoDownload,
    # 每次都重新拉最新的 llama.cpp 轉檔腳本
    [switch]$UpdateLlamaCpp,
    # 強制排除 MTP 頭（未指定時會自動偵測 config 與權重是否一致）
    [switch]$NoMtp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Name = $Repo.Split('/')[-1]
$Src  = Join-Path $Root "hf\$Name"
$Out  = Join-Path $Root 'gguf'
$Work = Join-Path $Root 'llama.cpp'
$Venv = Join-Path $Root 'venv'
$Py   = Join-Path $Venv 'Scripts\python.exe'
$Bf16 = Join-Path $Out  "$Name-bf16.gguf"
$Mmp  = Join-Path $Out  "$Name-mmproj-f16.gguf"

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function GB($bytes) { [math]::Round($bytes / 1GB, 1) }
function DirGB($path) {
    if (-not (Test-Path $path)) { return 0 }
    GB ((Get-ChildItem $path -Recurse -File | Measure-Object Length -Sum).Sum)
}

# bf16 相對於原始權重的大小比例（原權重本來就是 bf16，所以是 1.0）
$Ratio = @{
    'bf16'=1.00; 'f16'=1.00; 'Q8_0'=0.53; 'Q6_K'=0.41; 'Q5_K_M'=0.35; 'Q5_K_S'=0.34
    'Q4_K_M'=0.30; 'Q4_K_S'=0.28; 'Q3_K_M'=0.24; 'IQ4_XS'=0.27; 'IQ4_NL'=0.28
}

Write-Host "`n模型 : $Repo"        -ForegroundColor White
Write-Host "輸出 : $($Quants -join ', ')" -ForegroundColor White
Write-Host "位置 : $Out"           -ForegroundColor White

# ---------- 0. 目錄與空間預估 ----------
foreach ($d in @($Root, $Out)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
}
$Drive = (Get-Item $Root).PSDrive.Name
$Free  = GB (Get-PSDrive $Drive).Free

# 先問 HF API 拿 repo 大小，失敗就跳過預估（下載後仍會用實際大小再算一次）
$RepoGB = 0
try {
    $tree = Invoke-RestMethod "https://huggingface.co/api/models/$Repo/tree/main?recursive=true" -TimeoutSec 20
    $RepoGB = GB (($tree | Where-Object { $_.type -eq 'file' } | Measure-Object size -Sum).Sum)
} catch {
    Warn "無法查詢 repo 大小（$($_.Exception.Message)），跳過事前空間預估"
}

if ($RepoGB -gt 0) {
    $needBf16 = $RepoGB
    $needQ = 0
    foreach ($q in $Quants) { if ($q -ne 'bf16') { $needQ += $RepoGB * $Ratio[$q] } }
    $need = [math]::Round($RepoGB + $needBf16 + $needQ, 1)
    Step "空間檢查：來源 $RepoGB GB，全程約需 $need GB，${Drive}: 剩 $Free GB"
    if ($Free -lt $need) {
        throw "空間不足（需 $need GB，剩 $Free GB）。換 -Root，或減少 -Quants 數量。"
    }
}

# ---------- 1. Python 環境 ----------
Step '準備 Python 環境'
if (-not (Test-Path $Py)) {
    Info '建立 venv'
    python -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw 'venv 建立失敗，確認 python 在 PATH 上' }
}

# ---------- 2. llama.cpp 轉檔腳本 ----------
Step '取得 llama.cpp 轉檔腳本'
if (Test-Path (Join-Path $Work '.git')) {
    if ($UpdateLlamaCpp) {
        git -C $Work fetch --depth 1 origin master
        git -C $Work reset --hard origin/master
    } else {
        Info '已存在，略過更新（要更新請加 -UpdateLlamaCpp）'
    }
} else {
    git clone --depth 1 https://github.com/ggml-org/llama.cpp $Work
    if ($LASTEXITCODE -ne 0) { throw 'clone 失敗' }
}

# 相依套件一次解析完成。刻意不用 requirements 檔：它把 numpy 釘在 ~=1.26.4，
# Python 3.13 沒有對應 wheel 會退化成原始碼編譯而需要 MSVC。gguf-py 只要求 numpy>=1.17。
# huggingface_hub 也放進同一次解析，否則 pip 會在下載途中才為 transformers 降版，
# 並卡在 hf.exe 的檔案鎖上導致整批回滾。
$marker = Join-Path $Venv '.deps-ok'
if (-not (Test-Path $marker)) {
    Info '安裝相依套件（torch CPU 版，約 200 MB）'
    & $Py -m pip install --quiet --upgrade pip
    & $Py -m pip install --quiet torch --index-url https://download.pytorch.org/whl/cpu
    if ($LASTEXITCODE -ne 0) { throw 'torch 安裝失敗' }
    & $Py -m pip install --quiet "numpy>=2.1" "sentencepiece>=0.1.98,<0.3.0" `
        "transformers==4.57.6" "gguf>=0.1.0" "protobuf>=4.21.0,<5.0.0" `
        "huggingface_hub[cli,hf_transfer]<1.0"
    if ($LASTEXITCODE -ne 0) { throw '相依套件安裝失敗' }
    New-Item -ItemType File -Force $marker | Out-Null
} else {
    Info '相依套件已就緒'
}

# ---------- 3. 下載 ----------
if ($NoDownload) {
    Step '跳過下載（-NoDownload）'
    if (-not (Test-Path $Src)) { throw "找不到本地模型目錄：$Src" }
} else {
    Step "下載 $Repo"
    if ($RepoGB -gt 0) { Info "約 $RepoGB GB，可中斷續傳" }
    $env:HF_HUB_ENABLE_HF_TRANSFER = '1'
    & (Join-Path $Venv 'Scripts\hf.exe') download $Repo --local-dir $Src `
        --exclude '*.pth' 'original/*' 'consolidated*'
    if ($LASTEXITCODE -ne 0) { throw '下載失敗' }
}

$SrcGB = DirGB $Src
Info "本地來源大小：$SrcGB GB"

# ---------- 3.5 MTP 完整性檢查 ----------
# 有些 abliterated / finetune 權重把 MTP 頭拿掉了，卻沒改 config 裡的
# mtp_num_hidden_layers。轉檔器據此把 block_count 加一，寫出宣告 41 塊、
# 實際只有 40 塊的 GGUF，載入時就會報 missing tensor 'blk.<N>.attn_norm.weight'。
$MtpArg = @()
if ($NoMtp) {
    Warn '依 -NoMtp 排除 MTP 頭'
    $MtpArg = @('--no-mtp')
} else {
    try {
        $cfgPath = Join-Path $Src 'config.json'
        if (Test-Path $cfgPath) {
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $declared = 0
            foreach ($node in @($cfg, $cfg.text_config)) {
                if ($node -and $node.PSObject.Properties.Name -contains 'mtp_num_hidden_layers') {
                    $declared = [int]$node.mtp_num_hidden_layers
                }
                if ($node -and $node.PSObject.Properties.Name -contains 'num_nextn_predict_layers') {
                    $declared = [int]$node.num_nextn_predict_layers
                }
            }
            if ($declared -gt 0) {
                $idxPath = Join-Path $Src 'model.safetensors.index.json'
                $present = $true
                if (Test-Path $idxPath) {
                    $keys = (Get-Content $idxPath -Raw | ConvertFrom-Json).weight_map.PSObject.Properties.Name
                    $present = [bool]($keys | Where-Object { $_ -match '(^|\.)(mtp|nextn)\.' })
                }
                if (-not $present) {
                    Warn "config 宣告 MTP 層 x$declared，但權重裡找不到對應 tensor —— 自動加上 --no-mtp"
                    $MtpArg = @('--no-mtp')
                } else {
                    Info "MTP 層 x$declared，權重齊全"
                }
            }
        }
    } catch {
        Warn "MTP 檢查略過：$($_.Exception.Message)"
    }
}

# ---------- 4. bf16 母帶 ----------
# 任何量化都要先有 bf16 當輸入，所以無論如何都會產生
Step '轉換 -> bf16 GGUF'
if (Test-Path $Bf16) {
    Info "已存在，略過：$(Split-Path -Leaf $Bf16)（$(GB (Get-Item $Bf16).Length) GB）"
} else {
    & $Py (Join-Path $Work 'convert_hf_to_gguf.py') $Src @MtpArg --outtype bf16 --outfile $Bf16
    if ($LASTEXITCODE -ne 0) { throw 'bf16 轉換失敗' }
}

# ---------- 5. 視覺編碼器（VLM 才有） ----------
Step '轉換 -> mmproj（視覺編碼器）'
if (Test-Path $Mmp) {
    Info '已存在，略過'
} else {
    & $Py (Join-Path $Work 'convert_hf_to_gguf.py') $Src --mmproj --outfile $Mmp
    if ($LASTEXITCODE -ne 0) {
        Warn '沒有 vision tower，或此架構不支援 mmproj —— 純文字模型屬正常，不影響後續。'
        Remove-Item $Mmp -Force -EA SilentlyContinue
    }
}

# ---------- 6. 量化 ----------
$quantize = Join-Path $LlamaBin 'llama-quantize.exe'
if (-not (Test-Path $quantize)) { throw "找不到 llama-quantize.exe：$quantize（用 -LlamaBin 指定）" }

foreach ($q in $Quants) {
    if ($q -eq 'bf16') { continue }
    $dst = Join-Path $Out "$Name-$q.gguf"
    Step "量化 -> $q"
    if (Test-Path $dst) { Info '已存在，略過'; continue }
    & $quantize $Bf16 $dst $q
    if ($LASTEXITCODE -ne 0) { throw "$q 量化失敗" }
}

# ---------- 7. 收尾 ----------
if (($Quants -notcontains 'bf16') -and (-not $KeepBf16)) {
    Step '刪除 bf16 中間檔（要保留請加 -KeepBf16）'
    Remove-Item $Bf16 -Force
}
if ($DeleteSafetensors) {
    Step '刪除 HF 原始 safetensors'
    Remove-Item -Recurse -Force $Src
}

Step '完成'
Get-ChildItem $Out -Filter "$Name*.gguf" |
    Select-Object Name, @{ n = 'GB'; e = { GB $_.Length } } | Format-Table -AutoSize

$run = Join-Path $Out "$Name-$($Quants | Where-Object { $_ -ne 'bf16' } | Select-Object -First 1).gguf"
if (-not (Test-Path $run)) { $run = $Bf16 }
$mmArg = ''
if (Test-Path $Mmp) { $mmArg = "--mmproj `"$Mmp`" " }

Write-Host @"
啟動：

  $LlamaBin\llama-server.exe -m "$run" $mmArg-ngl 99 -c 32768 --jinja --host 127.0.0.1 --port 8080

VRAM 不夠時（MoE 模型效果最好）加 --n-cpu-moe N，N 由小往大調到剛好塞得下。
"@ -ForegroundColor Green
