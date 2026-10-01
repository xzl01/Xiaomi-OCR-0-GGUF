#!/usr/bin/env bash
# ocr-md.sh — 用本地的 Xiaomi-OCR-0 把图片/PDF 解析成 Markdown
#
# 用法:
#   ocr-md.sh 图片.png              整页解析 → Markdown（含表格/公式）
#   ocr-md.sh 文档.pdf [页数]        解析 PDF（默认前 5 页）
#   ocr-md.sh 图片.png --kie 姓名,金额    关键信息抽取 → JSON
#   ocr-md.sh 图片.png --vqa 这张发票的总额是多少
#   ocr-md.sh --start / --stop / --status   管理后端服务
#
# 设计：模型跑在 llama-server（Vulkan/Arc iGPU）上，本脚本只做客户端。
#      后端没起会自动拉起。服务在 http://127.0.0.1:8080

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${OCR_MD_PORT:-8080}"
URL="http://127.0.0.1:${PORT}"
LOG="${XDG_RUNTIME_DIR:-/tmp}/xiaomi-ocr-server.log"
PIDF="${XDG_RUNTIME_DIR:-/tmp}/xiaomi-ocr-server.pid"
PY="$HOME/npulab/.venv/bin/python"

# 官方 prompt（来自 skills/xiaomi-ocr/mcp_ocr_server.py 的 PROMPTS）
P_DOC='Extract all information from the main body of the document image and represent it in markdown format, ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should be represented using LATEX format, and the parsing should be organized according to the reading order.'

alive() { timeout 5 curl -s -m 4 "$URL/health" 2>/dev/null | grep -q '"ok"'; }

do_start() {
    alive && { echo "已在运行"; return 0; }
    [ -f "$HERE/model-q4_k_m.gguf" ] || { echo "缺 model-q4_k_m.gguf，先转换"; return 1; }
    cd "$HERE"
    setsid bash -c "exec llama-server -m model-q4_k_m.gguf --mmproj mmproj-f16.gguf \
        --host 127.0.0.1 --port $PORT -c 8192 -ngl 99 --image-min-tokens 1024 \
        > '$LOG' 2>&1" < /dev/null > /dev/null 2>&1 &
    disown
    echo -n "  启动中"
    for _ in $(seq 1 60); do
        if alive; then echo " ✓"; return 0; fi
        echo -n "."; sleep 2
    done
    echo " ✗ 超时，看 $LOG"; return 1
}

do_stop() {
    pkill -f "llama-server -m model-f16" 2>/dev/null && echo "已停止" || echo "本来就没运行"
}

case "${1:-}" in
    --start)  do_start; exit $? ;;
    --stop)   do_stop; exit 0 ;;
    --status) alive && echo "运行中 ($URL)" || echo "未运行"; exit 0 ;;
    ""|-h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

INPUT="$1"; shift || true
[ -f "$INPUT" ] || { echo "找不到文件: $INPUT" >&2; exit 1; }
alive || do_start || exit 1

# 模式
MODE=doc; KIE=""; VQA=""; PAGES=5
while [ $# -gt 0 ]; do
    case "$1" in
        --kie) MODE=kie; KIE="${2:-}"; shift ;;
        --vqa) MODE=vqa; VQA="${2:-}"; shift ;;
        *) PAGES="$1" ;;
    esac
    shift
done

# PDF → 图片
IMGS=()
if [[ "${INPUT,,}" == *.pdf ]]; then
    TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
    "$PY" - "$INPUT" "$TMPD" "$PAGES" <<'PY'
import sys, pypdfium2 as pdfium
pdf = pdfium.PdfDocument(sys.argv[1]); out, n = sys.argv[2], int(sys.argv[3])
for i in range(min(n, len(pdf))):
    pdf[i].render(scale=150/72).to_pil().save(f"{out}/p{i:03d}.png")
    print(f"{out}/p{i:03d}.png")
PY
    mapfile -t IMGS < <(ls "$TMPD"/*.png 2>/dev/null)
else
    IMGS=("$INPUT")
fi
[ "${#IMGS[@]}" -gt 0 ] || { echo "没有可处理的图片" >&2; exit 1; }

# 组装 prompt
build_prompt() {
    case "$MODE" in
        doc) echo "$P_DOC" ;;
        vqa) echo "$VQA
Answer the question using a single word or phrase." ;;
        kie)
            if [ -z "$KIE" ]; then
                echo "Extract the key information from the document image as a JSON object. Use concise field names. Return JSON only; use an empty string for missing values."
            else
                fields=$("$PY" -c "
import json,sys
fs=[f.strip() for f in sys.argv[1].split(',') if f.strip()]
print(json.dumps({f:'' for f in fs}, ensure_ascii=False, indent=4))" "$KIE")
                printf 'Extract key information in the image\n\nPlease output the key information in JSON format according to the following schema:\n%s\n' "$fields"
            fi ;;
    esac
}

PROMPT="$(build_prompt)"
for IMG in "${IMGS[@]}"; do
    "$PY" - "$URL" "$IMG" "$PROMPT" "$MODE" <<'PY'
import base64, json, sys, time, urllib.request
url, img, prompt, mode = sys.argv[1:5]
b64 = base64.b64encode(open(img,'rb').read()).decode()
mt = {"doc": 2048, "vqa": 256, "kie": 1024}[mode]
body = {"messages":[{"role":"user","content":[
    {"type":"text","text":prompt},
    {"type":"image_url","image_url":{"url":f"data:image/png;base64,{b64}"}}]}],
    "max_tokens":mt, "temperature":0.0}
req = urllib.request.Request(f"{url}/v1/chat/completions",
    data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
t0 = time.time()
r = json.load(urllib.request.urlopen(req, timeout=3600))
u = r.get("usage", {}); dt = time.time()-t0
out = r["choices"][0]["message"]["content"]
print(f"# {img}", file=sys.stderr)
print(f"# {dt:.1f}s | {u.get('prompt_tokens')} → {u.get('completion_tokens')} tok", file=sys.stderr)
print(out)
PY
done
