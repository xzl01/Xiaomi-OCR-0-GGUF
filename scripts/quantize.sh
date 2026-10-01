#!/usr/bin/env bash
# quantize.sh — 从零复现本仓库的 GGUF 量化产物
#
# 用法: quantize.sh <输出目录> [llama.cpp版本tag]
#   例: quantize.sh ~/xiaomi-ocr-gguf b10568
#
# 需要: git, curl, python3(带 torch/transformers/gguf), llama-quantize
set -euo pipefail

OUT="${1:?用法: quantize.sh <输出目录> [llama.cpp tag]}"
TAG="${2:-b10568}"
MODEL_REPO="SeerRay-Lab/Xiaomi-OCR-0"
HF="https://huggingface.co/${MODEL_REPO}/resolve/main"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ── 1. 与运行时版本对齐的转换工具 ────────────────────────────
# 新版 llama.cpp 把转换逻辑放进了 `conversion` 包，
# 只下载单个 convert_hf_to_gguf.py 是不够的，必须按 tag 克隆。
log "克隆 llama.cpp @ $TAG"
git clone --depth 1 --branch "$TAG" \
  https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp" 2>&1 | tail -2

# ── 2. 原始权重 ──────────────────────────────────────────────
# 注意：仓库里没有 generation_config.json / preprocessor_config.json，
# 别去下这两个，否则会把 404 响应体存成文件，转换时报 JSON 解析错误。
log "下载原始权重"
cd "$WORK"
for f in config.json processor_config.json tokenizer.json \
         tokenizer_config.json chat_template.jinja model.safetensors; do
    printf '  %-26s' "$f"
    curl -sL -C - "$HF/$f" -o "$f"
    printf '%s bytes\n' "$(stat -c%s "$f")"
done

# ── 3. 转 GGUF ───────────────────────────────────────────────
log "转换文本模型 → f16"
python "$WORK/llama.cpp/convert_hf_to_gguf.py" "$WORK" \
    --outfile "$OUT/model-f16.gguf" --outtype f16

log "转换视觉投影 → mmproj (f16)"
python "$WORK/llama.cpp/convert_hf_to_gguf.py" "$WORK" \
    --outfile "$OUT/mmproj-f16.gguf" --mmproj

# ── 4. 量化 ──────────────────────────────────────────────────
# mmproj 不量化：只有 198MB，量化视觉塔通常得不偿失。
for q in Q8_0 Q4_K_M; do
    low="$(echo "$q" | tr 'A-Z' 'a-z')"
    log "量化 → $q"
    llama-quantize "$OUT/model-f16.gguf" "$OUT/model-${low}.gguf" "$q"
done

# ── 5. 校验 ──────────────────────────────────────────────────
log "产物"
cd "$OUT"
for f in model-f16.gguf mmproj-f16.gguf model-q8_0.gguf model-q4_k_m.gguf; do
    [ -f "$f" ] && printf '  %-22s %10s bytes  sha256=%s\n' \
        "$f" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -c1-16)"
done
cat <<'EOF'

预期值（llama.cpp b10568，供比对）:
  model-q4_k_m.gguf   541903136 bytes  sha256=1f95214a9578c936…
  model-q8_0.gguf     833591584 bytes  sha256=1b3c4e37129cb298…
  mmproj-f16.gguf     207345856 bytes  sha256=037e6a655ff168a5…

若哈希一致，即可复现测试结果（scripts/bench.sh）。
EOF
