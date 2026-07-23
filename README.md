# hf-to-gguf

從 Hugging Face 下載 safetensors 模型，轉成 llama.cpp 能跑的 GGUF，可一次輸出多種量化。

llama.cpp 只吃 GGUF，不能直接讀 safetensors。這支腳本把「下載 → 轉 bf16 → 量化」整條流程包起來，每一步都可續跑。

---

## 需求

| 項目 | 說明 |
|---|---|
| Python 3.10+ | 需在 PATH 上，腳本會自建獨立 venv，不動你現有環境 |
| Git | 用來取得 llama.cpp 的轉檔腳本 |
| llama.cpp binary | 需含 `llama-quantize.exe`，預設指向 `C:\Users\HULab\Desktop\llama-b10092-bin-win-cuda-13.3-x64` |
| 磁碟空間 | 約為原模型的 2.5 倍，腳本會事先檢查並擋下 |

Windows PowerShell 5.1 和 PowerShell 7 都能跑。

---

## 快速開始

```powershell
powershell -ExecutionPolicy Bypass -File .\hf-to-gguf.ps1 Qwen/Qwen3-8B
```

預設輸出 Q8_0。要多種格式一次做完：

```powershell
.\hf-to-gguf.ps1 huihui-ai/Huihui-Qwen-AgentWorld-35B-A3B-abliterated -Quants bf16,Q8_0,Q4_K_M
```

輸出落在 `C:\models\gguf`，檔名自動取自 repo 名，例如 `Qwen3-8B-Q4_K_M.gguf`。

---

## 參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `-Repo`（位置參數 0） | 必填 | HF repo，格式 `org/name` |
| `-Quants` | `Q8_0` | 逗號分隔。可選 `bf16` `f16` `Q8_0` `Q6_K` `Q5_K_M` `Q5_K_S` `Q4_K_M` `Q4_K_S` `Q3_K_M` `IQ4_XS` `IQ4_NL` |
| `-KeepBf16` | off | 未指定 `bf16` 時也保留母帶 |
| `-NoDownload` | off | 已有本地資料夾，跳過下載直接轉 |
| `-DeleteSafetensors` | off | 轉完刪掉 HF 原始檔 |
| `-Root` | `C:\models` | 工作目錄（venv、原始檔、輸出都在底下） |
| `-LlamaBin` | 見上表 | llama.cpp binary 資料夾 |
| `-UpdateLlamaCpp` | off | 拉最新轉檔腳本；預設不更新以免每次跑都變動 |

---

## 選哪個量化

各格式相對於原始 bf16 權重的大小與定位：

| 格式 | 相對大小 | 說明 |
|---|---|---|
| `bf16` | 1.00 | 原生精度，位元級無損。當母帶用，日常推理太肥 |
| `Q8_0` | 0.53 | 差異在測量噪音等級。品質優先時的實務首選 |
| `Q6_K` | 0.41 | 幾乎無感損失 |
| `Q5_K_M` | 0.35 | 品質與大小的平衡點 |
| `Q4_K_M` | 0.30 | 最常用的甜蜜點，MoE 模型耐受度尤其好 |
| `Q3_K_M` 以下 | ≤0.24 | 開始明顯掉品質，建議搭配 imatrix（本腳本未實作） |

`f16` 沒有使用理由 —— 原始權重是 bf16，轉 f16 會截斷指數範圍，大小卻和 bf16 一樣。

**建議做法**：`-Quants bf16,Q8_0`，bf16 當母帶存著，日常跑 Q8_0。之後想換 Q4_K_M 或補做 imatrix，加 `-NoDownload` 重跑就好，不必重新下載幾十 GB。

### 速度取捨

推理時 token 生成幾乎完全是**記憶體頻寬瓶頸** —— 每個 token 要把權重從記憶體搬一次，搬多少 byte 就決定多快。所以檔案愈小愈快，量化在同一張卡上永遠比 bf16 快，而不是只有「塞得下」的差別。

以 GB10（128 GB 統一記憶體、頻寬約 273 GB/s）跑 35B-A3B MoE 為例，每 token 只啟動約 3B 參數：

- Q8_0 → 每 token 搬約 3.2 GB → 理論上限 ~85 t/s
- bf16 → 每 token 搬約 6.4 GB → 理論上限 ~43 t/s

實際約打五到六折，但比例是實打實的。bf16 雖然 70 GB 塞得進 128 GB 不必 offload，仍然慢一倍。

prompt 處理（prefill）是算力綁定，bf16 在那段不吃虧，但長對話的體感由生成速度決定。

---

## 產出與目錄結構

```
C:\models\
├─ venv\                   Python 環境（.deps-ok 為安裝完成標記）
├─ llama.cpp\              轉檔腳本（shallow clone）
├─ hf\<模型名>\            HF 原始 safetensors
└─ gguf\
   ├─ <模型名>-bf16.gguf
   ├─ <模型名>-Q8_0.gguf
   └─ <模型名>-mmproj-f16.gguf    僅 VLM 才有
```

bf16 一律會產生，因為量化器的輸入就是它。若 `-Quants` 未列 `bf16` 且未加 `-KeepBf16`，收尾時會自動刪除。

**中斷後直接重跑同一行指令即可。** 下載支援續傳，每個轉檔／量化步驟都會先檢查輸出檔是否存在，存在就跳過。

---

## 執行模型

腳本結束時會印出對應本次產出的啟動指令，大致如下：

```powershell
llama-server.exe -m "C:\models\gguf\<模型名>-Q8_0.gguf" -ngl 99 -c 32768 --jinja --host 127.0.0.1 --port 8080
```

- `--jinja` 跑 agent／tool calling 時必加，否則 chat template 的工具呼叫格式會壞掉
- VLM 另外加 `--mmproj "C:\models\gguf\<模型名>-mmproj-f16.gguf"`，純文字用不到時可省下一點 VRAM
- VRAM 不夠時加 `--n-cpu-moe N`：把 N 層的 expert 權重放 CPU、attention 留 GPU。MoE 模型用這招掉速很少，N 從小往大調到剛好塞得下

---

## 疑難排解

**`未預期的 '??' 語彙基元` 或中文顯示成亂碼**
腳本必須存成 **UTF-8 with BOM**，否則 Windows PowerShell 5.1 會用 Big5 解讀而連引號都解析壞掉。重新編碼：

```powershell
$p=".\hf-to-gguf.ps1"; [IO.File]::WriteAllText($p,[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false)),[Text.UTF8Encoding]::new($true))
```

**`ERROR: Compiler cl cannot compile programs`（安裝 numpy 時）**
llama.cpp 的 `requirements-convert_legacy_llama.txt` 把 numpy 釘在 `~=1.26.4`，該版本沒有 Python 3.13 的 wheel，pip 只好從原始碼編譯而需要 MSVC。腳本刻意不使用該 requirements 檔，改為直接指定 `numpy>=2.1`（`gguf-py` 實際只要求 `numpy>=1.17`）。若你手動跑過 `pip install -r` 才遇到，照腳本的裝法重來即可。

**`WinError 32 ... hf.exe` 被占用**
`transformers 4.57.6` 需要 `huggingface_hub<1.0`，分兩次安裝時 pip 會在下載途中才試圖降版並撞上 `hf.exe` 的檔案鎖，導致整批回滾。腳本已把所有套件放進同一次 pip 解析避免此問題。若已發生，關掉下載程序後刪除殘留目錄再重跑：

```powershell
Get-ChildItem "C:\models\venv\Lib\site-packages" -Filter "~*" -Directory | Remove-Item -Recurse -Force
```

**載入時 `missing tensor 'blk.<N>.attn_norm.weight'`**
不是 llama.cpp 版本太舊，是**權重本身缺 MTP 頭**。部分 abliterated／finetune 模型把 MTP（multi-token prediction）模組拿掉了，卻沒把 `config.json` 裡的 `mtp_num_hidden_layers` 改回 0。轉檔器照宣告把 `block_count` 加一，寫出「宣告 41 塊、實際只有 40 塊」的 GGUF，載入時就在最後一塊撲空。

腳本會自動比對 config 宣告與權重索引，不一致時自動加上 `--no-mtp`。手動轉檔的話自己補這個旗標：

```bash
python3 convert_hf_to_gguf.py <模型目錄> --no-mtp --outtype bf16 --outfile out-bf16.gguf
```

MTP 只是推測解碼用的加速頭，llama.cpp 目前沒有實際拿它加速，排除掉不影響輸出品質。

判斷是不是這個問題，看 config 宣告與權重是否對得上：

```bash
python3 -c "import json;c=json.load(open('config.json'));t=c.get('text_config',c);print('declared:',t.get('mtp_num_hidden_layers',0));print('present:',any('mtp.' in k for k in json.load(open('model.safetensors.index.json'))['weight_map']))"
```

`declared` 大於 0 而 `present` 為 `False`，就是這個狀況。

**mmproj 只有幾 KB**
那是空殼，不是正常檔案。部分 abliterated 模型把視覺塔整個移除了，卻留著 `config.json` 裡的 `vision_config`，轉檔於是「成功」但寫不出任何權重。腳本會偵測並自動刪除（門檻 10 MB）。確認方式是看權重索引裡有沒有視覺 tensor：

```bash
python3 -c "import json;k=json.load(open('model.safetensors.index.json'))['weight_map'];print('vision tensors:',sum('visual' in x or 'vision' in x for x in k))"
```

結果是 0，這份權重就是純文字模型，config 裡的 `language_model_only: true` 也是同一件事的另一種說法。

**`沒有 vision tower，或此架構不支援 mmproj`**
純文字模型的正常訊息，不影響後續步驟。若模型確實是 VLM 但轉不出來，或如上被砍掉了視覺塔，可從同模型的官方 GGUF repo 借用 —— 視覺塔通常未被微調改動，投影維度也對得上：

```powershell
C:\models\venv\Scripts\hf.exe download <org>/<model>-GGUF --include "mmproj*" --local-dir C:\models\gguf
```

**轉檔會不會吃很多記憶體**
不會。轉檔和量化都是逐 tensor 串流處理，峰值約數 GB，16 GB 的機器也做得動。真正的瓶頸是磁碟 I/O，整個流程要讀寫約原模型 2.5 倍的資料量，放 NVMe 上差別很大。過程中工作管理員顯示的高記憶體用量是 Windows 檔案快取，屬可回收記憶體，不是壓力。

**裝 CUDA 版 torch 會不會比較快**
不會，一點都不會。`convert_hf_to_gguf.py` 沒有任何運算，只是讀 tensor、改 dtype、寫出去，torch 在這裡純粹當讀檔和型別轉換的函式庫用，從頭到尾不會把 tensor 丟上 GPU。CUDA 版要多下載約 3 GB 卻一個 kernel 都不會被呼叫到。

唯一真正用到 GPU 的是 imatrix，但那是跑 `llama-imatrix.exe`，用的是 build 裡的 `ggml-cuda.dll`，和 Python 的 torch 是兩套獨立的東西。
