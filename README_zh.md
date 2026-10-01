# Xiaomi-OCR-0 GGUF

[**Xiaomi-OCR-0**](https://github.com/SeerRay-Lab/Xiaomi-OCR-0) 的 GGUF 量化版本，
供 [llama.cpp](https://github.com/ggml-org/llama.cpp) 使用。附带可复现的转换脚本
和实测的精度 / 速度 / 内存数据。

Xiaomi-OCR-0 是一个 0.8B 的视觉语言模型，做统一文档解析与 OCR 理解：把文档页
转成结构化 Markdown（表格用 OTSL、公式用 LaTeX），也支持关键信息抽取（KIE）
和 OCR 视觉问答。

| 文件 | 大小 | SHA256（前 16 位） |
|---|---|---|
| `model-q4_k_m.gguf` | 517 MB | `1f95214a9578c936` |
| `model-q8_0.gguf` | 795 MB | `1b3c4e37129cb298` |
| `mmproj-f16.gguf`（视觉部分，必需） | 198 MB | `037e6a655ff168a5` |

---

## 为什么做 GGUF

上游给的是 SGLang / vLLM 部署路径，实际上等于要求 NVIDIA GPU。这个仓库是为了
让它能在 **CPU 或非 NVIDIA 显卡**上跑（本仓库的数据是在 Intel Arc 核显上用
Vulkan 测的）。

**顺带说清楚一个坑：这个模型不能上 Intel NPU**，两个独立原因：

1. **它是自回归 VLM。** 图像 token 数和输出序列长度都是动态的，而 NPU 插件
   （如 OpenVINO 的）要求在编译时锁定张量形状。
2. **上游推理栈只面向 CUDA。** SGLang / vLLM 没有 NPU 后端。

llama.cpp 是现实可行的路：它支持这个架构（包括模型的混合线性注意力），
并且能通过纯 CPU 或 Vulkan 跑起来。

---

## 快速开始

```bash
# 1. 从本仓库 Releases 页下载
#    model-q4_k_m.gguf + mmproj-f16.gguf

# 2. 启动服务
llama-server \
  -m model-q4_k_m.gguf \
  --mmproj mmproj-f16.gguf \
  --host 127.0.0.1 --port 8080 \
  -c 8192 -ngl 99 --image-min-tokens 1024
```

> `--image-min-tokens 1024` 是 llama.cpp 针对 Qwen-VL 系列的建议值，
> 不加会警告定位精度下降。

然后用 OpenAI 兼容接口：

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role":"user","content":[
      {"type":"text","text":"Extract all information from the main body of the document image and represent it in markdown format, ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should be represented using LATEX format, and the parsing should be organized according to the reading order."},
      {"type":"image_url","image_url":{"url":"data:image/png;base64,'"$(base64 -w0 page.png)"'"}}
    ]}],
    "max_tokens": 2048, "temperature": 0.0
  }'
```

上面的 prompt 是上游的文档解析提示词，取自原仓库
`skills/xiaomi-ocr/mcp_ocr_server.py`。

`scripts/ocr-md.sh` 把它封装成了命令行工具：

```bash
./scripts/ocr-md.sh 图片.png              # 整页 → Markdown
./scripts/ocr-md.sh 文档.pdf 10           # 前 10 页
./scripts/ocr-md.sh 图片.png --kie "姓名,金额"
./scripts/ocr-md.sh 图片.png --vqa "发票号码是多少"
```

---

## 量化方法（可复现）

需要：与运行时**build 号一致**的 llama.cpp 源码，以及 Python 的
`torch` / `transformers` / `gguf`。

```bash
# 0. 拿到版本对齐的转换工具
#    （新版 llama.cpp 把逻辑放进了 `conversion` 包，只下载单个脚本文件不够，
#      必须按 tag 浅克隆）
git clone --depth 1 --branch b10568 https://github.com/ggml-org/llama.cpp

# 1. 下载原始权重（1.75 GB）
#    仓库里只有这几个文件：
#      config.json processor_config.json tokenizer.json tokenizer_config.json
#      chat_template.jinja model.safetensors
#    注意：`generation_config.json` / `preprocessor_config.json` 并不存在，
#    去拉它们会得到 404 响应体，导致转换器报 JSON 解析错误。

# 2. 转 GGUF
python /path/to/llama.cpp/convert_hf_to_gguf.py \
  ./model_dir --outfile model-f16.gguf --outtype f16

python /path/to/llama.cpp/convert_hf_to_gguf.py \
  ./model_dir --outfile mmproj-f16.gguf --mmproj

# 3. 量化
llama-quantize model-f16.gguf model-q8_0.gguf   Q8_0
llama-quantize model-f16.gguf model-q4_k_m.gguf Q4_K_M
```

转换使用 llama.cpp **b10568（commit `af9df75`）**，GNU 16.2.1，x86_64 Linux。
`mmproj` 刻意保持 f16 —— 它只有 198 MB，量化视觉塔通常得不偿失。

---

## 实测数据

测试集：覆盖上游几种模式的四个用例 —— 发票整页、密集公式学术页、手写体、
KIE。三档精度的原始输出都在 [`results/`](results/)，测试台是
[`scripts/bench.sh`](scripts/bench.sh)。

硬件：Intel Core Ultra 7 258V（Lunar Lake），Intel Arc 核显走 Vulkan，
LPDDR5x，Linux 7.x。上下文 8192，`-ngl 99`。

### 精度（与 f16 的字符级相似度）

| 用例 | f16 → Q8_0 | f16 → Q4_K_M |
|---|---|---|
| 发票整页 | 100.0% | **100.0%** |
| 密集公式 | 99.1% | 96.6% |
| 手写体 | 100.0% | 99.5% |
| KIE（JSON） | 100.0% | **100.0%** |

**Q4_K_M 的差异不是精度损失。** 密集公式那 96.6% 的差异只有两处，逐条看：

1. **表格权重列** —— f16 把下标压平成了纯文本（`w formula`），
   而 Q4_K_M 正确输出了 LaTeX（`\(w_{formula}\)`）。**Q4_K_M 更准。**
2. **手写体的箭头** —— f16 输出了乱码字形（`□`），Q4_K_M 直接省略。
   两者都不完美（原图是 `→`），但 Q4_K_M 的省略比乱码干净。

### 速度（秒，越小越好）

| 用例 | f16 | Q8_0 | Q4_K_M |
|---|---|---|---|
| 发票整页 | 9.5 | 8.0 | **7.6** |
| 密集公式 | 19.9 | 17.7 | **16.5** |
| 手写体 | 10.7 | 9.3 | **8.9** |
| KIE | 6.0 | 5.1 | **4.6** |

### 内存（服务进程 RSS 增量，含 KV cache 与 mmproj）

| 档位 | 模型文件 | 实际占用 |
|---|---|---|
| f16 | 1485 MB | 1831 MB |
| Q8_0 | 794 MB | 1714 MB |
| **Q4_K_M** | **516 MB** | **1507 MB** |

### 怎么选

**Q4_K_M** —— 本测试集里在所有维度都最优（最小、最快、无精度损失）。
需要更大保真余量时用 `Q8_0`，它接近无损。

---

## 已知限制

- **仍会出现字符级错误。** 0.8B 模型会混淆形近字符 —— 实测过一次 KIE 把
  `¥128,450.00` 认成 `￥128.450.00`。金额、编号这类关键字段请独立校验。
- **原始输出是 OTSL，不是 Markdown 表格。** 让模型输出 OTSL 是上游管线的做法，
  OTSL 转 Markdown 表格由上游后处理（`postprocess/otsl.py`）完成，**本仓库
  不含这部分**。想要直接的 Markdown 表格就改 prompt。
- **长文档需要分块。** 这里上下文是 8192；A4 纸按 150 DPI 渲染就已经吃掉
  1100~2300 个 prompt token。
- **手写体 / 低质量扫描件**质量波动较大。
- 数据来自单机、4 个用例，只反映不同精度之间的**相对**表现，不代表你的硬件上的
  绝对吞吐。

---

## 许可证与署名

Apache License 2.0 —— 与原项目一致。

- 原始模型：[SeerRay-Lab/Xiaomi-OCR-0](https://huggingface.co/SeerRay-Lab/Xiaomi-OCR-0) @ `e4d1c4a6`
- 原始代码：[SeerRay-Lab/Xiaomi-OCR-0](https://github.com/SeerRay-Lab/Xiaomi-OCR-0) @ `6499f6c8`
- 模型权重的版权归 SeerRay-Lab 所有。

所做的变更记录在 [`NOTICE`](NOTICE) 中，这是 Apache-2.0 §4(b) 的要求：
格式转换为 GGUF，以及有损量化。**未做**微调、剪枝或任何其他参数修改。

本仓库新增的脚本和评测数据是 [xzl01](https://github.com/xzl01) 的新作品，
同样以 Apache-2.0 提供。
