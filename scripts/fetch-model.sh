#!/usr/bin/env bash
# fetch-model.sh — 下载并重组分块的模型文件
#
# 为什么分块：上传时走代理，上行在 1.7MB/s 和 80KB/s 之间剧烈波动，
# 大文件经常被 GitHub 以 408（数据停滞超时）拒绝。切成 40MB 的块后可靠多了。
#
# 用法:
#   fetch-model.sh q4       # → model-q4_k_m.gguf   (517 MB, 推荐)
#   fetch-model.sh q8       # → model-q8_0.gguf     (795 MB, 更高保真)
#   fetch-model.sh mmproj   # → mmproj-f16.gguf     (198 MB, 必需)
#   fetch-model.sh all      # 全部
#
# 完成后校验 SHA256，与 README 里公布的一致才算成功。
set -euo pipefail

REPO="xzl01/Xiaomi-OCR-0-GGUF"
TAG="v1.0.0"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
OUT="${OUT_DIR:-.}"

# 期望的最终 SHA256（见 README）
declare -A SHA=(
    [q4]="1f95214a9578c9366f57fd69d470bf8fda2f773a749aa80adc00156cc88cd1ca"
    [q8]="1b3c4e37129cb29896c61c833589be2acfb9eb0370bb84d3df12759f1f0f457a"
    [mmproj]="037e6a655ff168a5decb51c16dc819c06b7e19684441e98f00cb732c2ac61084"
)
declare -A FINAL=(
    [q4]="model-q4_k_m.gguf" [q8]="model-q8_0.gguf" [mmproj]="mmproj-f16.gguf"
)
declare -A PREFIX=( [q4]="q4k_m.part-" [q8]="q8_0.part-" [mmproj]="" )

mkdir -p "$OUT"; cd "$OUT"

fetch_parts() {
    local key="$1" prefix="$2"
    # 找出这个模型有哪些块（从 00 开始，直到下载 404）
    local tmpd="tmp-${key}"; mkdir -p "$tmpd"
    local i=0 n
    while :; do
        n=$(printf '%s%02d' "$prefix" "$i")
        if [ ! -f "$tmpd/$n" ]; then
            printf '  %s … ' "$n"
            if curl -fL --retry 3 -C - "$BASE/$n" -o "$tmpd/$n" 2>/dev/null; then
                printf '%s bytes\n' "$(stat -c%s "$tmpd/$n")"
            else
                printf '不存在，共 %d 块\n' "$i"; rm -f "$tmpd/$n"; break
            fi
        fi
        i=$((i+1))
    done
    cat "$tmpd"/* > "${FINAL[$key]}"
    rm -rf "$tmpd"
}

check() {
    local key="$1"
    printf '  校验 %s … ' "${FINAL[$key]}"
    local got; got=$(sha256sum "${FINAL[$key]}" | cut -d' ' -f1)
    if [ "$got" = "${SHA[$key]}" ]; then
        echo "✓"
    else
        echo "✗ 不匹配！期望 ${SHA[$key]:0:16}… 得到 ${got:0:16}…"
        return 1
    fi
}

do_one() {
    local key="$1"
    echo "==> $key → ${FINAL[$key]}"
    if [ -n "${PREFIX[$key]}" ]; then
        fetch_parts "$key" "${PREFIX[$key]}"
    else
        # mmproj 是完整文件，没有分块
        curl -fL --retry 3 -C - "$BASE/${FINAL[$key]}" -o "${FINAL[$key]}"
        printf '  下载完成 %s bytes\n' "$(stat -c%s "${FINAL[$key]}")"
    fi
    check "$key"
}

case "${1:-}" in
    q4|q8|mmproj) do_one "$1" ;;
    all) for k in mmproj q4 q8; do do_one "$k"; done ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

echo
echo "完成。启动服务："
echo "  llama-server -m model-q4_k_m.gguf --mmproj mmproj-f16.gguf \\"
echo "    --host 127.0.0.1 --port 8080 -c 8192 -ngl 99 --image-min-tokens 1024"
