#!/usr/bin/env bash
# bench.sh — 对指定模型跑一组固定测试，输出可 diff 的结果
#
# 用法: bench.sh <模型.gguf> <输出目录> [端口]
#
# 测三类任务（覆盖官方三种模式）：
#   1. 发票整页 → Markdown/OTSL
#   2. 密集公式文档 → Markdown/LaTeX
#   3. KIE 关键信息抽取 → JSON
#   4. 手写体整页 → Markdown
#
# 输出：<目录>/<case>.md 与 <目录>/timing.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HOME/npulab/.venv/bin/python"

MODEL="$1"; OUT="$2"; PORT="${3:-8099}"
mkdir -p "$OUT"
S="$HERE/samples"

P_DOC='Extract all information from the main body of the document image and represent it in markdown format, ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should be represented using LATEX format, and the parsing should be organized according to the reading order.'
P_KIE='Extract key information in the image

Please output the key information in JSON format according to the following schema:
{
    "发票代码": "",
    "发票号码": "",
    "开票日期": "",
    "购买方": "",
    "金额": "",
    "税率": ""
}'

# 启动服务
pkill -f "llama-server.*bench" 2>/dev/null; sleep 2
setsid bash -c "exec llama-server -m '$MODEL' --mmproj '$HERE/mmproj-f16.gguf' \
  --host 127.0.0.1 --port $PORT -c 8192 -ngl 99 --image-min-tokens 1024 \
  --alias bench > /tmp/bench-server.log 2>&1" < /dev/null > /dev/null 2>&1 &
disown
echo -n "  loading"
for _ in $(seq 1 90); do
    timeout 4 curl -s -m 3 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok"' && { echo " ok"; break; }
    echo -n "."; sleep 2
done

run_case() {
    local name="$1" img="$2" prompt="$3" mt="$4"
    "$PY" - "http://127.0.0.1:$PORT" "$S/$img" "$prompt" "$mt" "$OUT/$name.md" "$OUT/timing.txt" <<'PY'
import base64, json, sys, time, urllib.request, pathlib
url, img, prompt, mt, outmd, timing = sys.argv[1:7]
b64 = base64.b64encode(open(img,'rb').read()).decode()
body = {"messages":[{"role":"user","content":[
    {"type":"text","text":prompt},
    {"type":"image_url","image_url":{"url":f"data:image/png;base64,{b64}"}}]}],
    "max_tokens":int(mt), "temperature":0.0}
req = urllib.request.Request(f"{url}/v1/chat/completions",
    data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
t0=time.time()
r = json.load(urllib.request.urlopen(req, timeout=3600))
dt=time.time()-t0; u=r.get("usage",{})
txt=r["choices"][0]["message"]["content"]
pathlib.Path(outmd).write_text(txt, encoding="utf-8")
with open(timing,"a") as f:
    f.write(f"{pathlib.Path(outmd).stem}\t{dt:.1f}s\tprompt={u.get('prompt_tokens')}\tgen={u.get('completion_tokens')}\n")
print(f"    {pathlib.Path(outmd).stem:16} {dt:6.1f}s  {u.get('completion_tokens')} tok")
PY
}

echo "  测试中："
run_case doc_invoice  showcase_invoice.png     "$P_DOC" 900
run_case doc_dense    showcase_dense.png       "$P_DOC" 1200
run_case doc_hand     showcase_handwriting.png "$P_DOC" 900
run_case kie_invoice  showcase_invoice.png     "$P_KIE" 512

pkill -f "llama-server.*bench" 2>/dev/null
echo "  结果 → $OUT"
