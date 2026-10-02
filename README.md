# Xiaomi-OCR-0 GGUF

GGUF quantizations of [**Xiaomi-OCR-0**](https://github.com/SeerRay-Lab/Xiaomi-OCR-0)
for [llama.cpp](https://github.com/ggml-org/llama.cpp), with reproducible
conversion scripts and measured accuracy/speed/memory results.

Xiaomi-OCR-0 is a 0.8B vision-language model for unified document parsing and
OCR-centric understanding. It converts document pages into structured Markdown —
tables as OTSL, formulas as LaTeX — and also supports key information extraction
(KIE) and OCR-VQA.

| File | Size | SHA256 (first 16) |
|---|---|---|
| `model-q4_k_m.gguf` | 517 MB | `1f95214a9578c936` |
| `model-q8_0.gguf` | 795 MB | `1b3c4e37129cb298` |
| `mmproj-f16.gguf` (vision, required) | 198 MB | `037e6a655ff168a5` |

---

## Why GGUF / llama.cpp

The upstream project ships a SGLang / vLLM deployment path, which in practice
means an NVIDIA GPU. This repository exists so the model can run on **CPU or a
non-NVIDIA GPU** (tested on an Intel Arc iGPU via Vulkan).

A note for anyone hoping to run this on an **Intel NPU** — it will not work, for
two independent reasons:

1. **It is an autoregressive VLM.** Both the image token count and the output
   sequence length are dynamic. NPU plugins (e.g. OpenVINO's) require the tensor
   shape to be fixed at compile time.
2. **The upstream inference stack targets CUDA.** SGLang/vLLM have no NPU
   backend.

llama.cpp is the practical path: it supports this architecture (including the
model's hybrid linear + full attention) and reaches it through plain CPU or
Vulkan.

---

## Quick start

```bash
# 1. Get the files
#    model-q4_k_m.gguf + mmproj-f16.gguf from the Releases page of this repo
#
#    NOTE: the two language models are published as 40 MB parts, because the
#    upload link available here fluctuated between 1.7 MB/s and 80 KB/s and
#    GitHub kept aborting large single uploads with HTTP 408. Use the helper:
./scripts/fetch-model.sh q4          # -> model-q4_k_m.gguf   (517 MB)
./scripts/fetch-model.sh mmproj      # -> mmproj-f16.gguf     (198 MB, required)
./scripts/fetch-model.sh all         # everything, incl. Q8_0
#
#    (Or assemble by hand: cat q4k_m.part-* > model-q4_k_m.gguf)
#    The helper verifies SHA256 against the values published below.

# 2. Serve
llama-server \
  -m model-q4_k_m.gguf \
  --mmproj mmproj-f16.gguf \
  --host 127.0.0.1 --port 8080 \
  -c 8192 -ngl 99 --image-min-tokens 1024
```

> `--image-min-tokens 1024` is recommended by llama.cpp for Qwen-VL family
> models; without it the runtime warns about degraded grounding accuracy.

Then query the OpenAI-compatible API:

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

The prompt above is the upstream document-parsing prompt, taken from
`skills/xiaomi-ocr/mcp_ocr_server.py` in the original repository.

`scripts/ocr-md.sh` wraps this into a CLI with document / PDF / KIE / VQA modes:

```bash
./scripts/ocr-md.sh image.png              # whole page -> Markdown
./scripts/ocr-md.sh doc.pdf 10             # first 10 pages
./scripts/ocr-md.sh image.png --kie "name,total"
./scripts/ocr-md.sh image.png --vqa "what is the invoice number"
```

---

## Quantization method (reproducible)

Requires: llama.cpp at the **same build** as your runtime, plus
`torch` / `transformers` / `gguf` in Python.

```bash
# 0. Get the exact matching conversion tooling
#    (newer llama.cpp keeps the logic in a `conversion` package, so a shallow
#     clone of the matching tag is the reliable route — fetching the single
#     script file is not enough)
git clone --depth 1 --branch b10568 https://github.com/ggml-org/llama.cpp

# 1. Download the original weights (1.75 GB)
#    Only these files exist in the repo:
#      config.json processor_config.json tokenizer.json tokenizer_config.json
#      chat_template.jinja model.safetensors
#    Note: `generation_config.json` / `preprocessor_config.json` do NOT exist —
#    fetching them yields a 404 body that breaks the converter with a JSON error.

# 2. Convert to GGUF
python /path/to/llama.cpp/convert_hf_to_gguf.py \
  ./model_dir --outfile model-f16.gguf --outtype f16

python /path/to/llama.cpp/convert_hf_to_gguf.py \
  ./model_dir --outfile mmproj-f16.gguf --mmproj

# 3. Quantize
llama-quantize model-f16.gguf model-q8_0.gguf   Q8_0
llama-quantize model-f16.gguf model-q4_k_m.gguf Q4_K_M
```

Converted with llama.cpp **b10568 (commit `af9df75`)**, GNU 16.2.1, x86_64 Linux.
The `mmproj` is deliberately kept at f16 — it is only 198 MB and quantizing the
vision tower tends to cost more accuracy than it saves space.

---

## Measured results

Test set: four cases covering the upstream modes — invoice page, dense
formula-heavy academic page, handwriting page, and KIE. Raw outputs for all
three precisions are in [`results/`](results/); the harness is
[`scripts/bench.sh`](scripts/bench.sh).

Hardware: Intel Core Ultra 7 258V (Lunar Lake), Intel Arc iGPU via Vulkan,
LPDDR5x, Linux 7.x. Context 8192, `-ngl 99`.

### Accuracy (character-level similarity vs f16)

| Case | f16 → Q8_0 | f16 → Q4_K_M |
|---|---|---|
| Invoice page | 100.0% | **100.0%** |
| Dense formulas | 99.1% | 96.6% |
| Handwriting | 100.0% | 99.5% |
| KIE (JSON) | 100.0% | **100.0%** |

**The Q4_K_M differences are not degradations.** Inspecting the only two
differing spots in the dense case:

1. Table weight column — f16 flattened subscripts to plain text
   (`w formula`), while Q4_K_M produced correct LaTeX (`\(w_{formula}\)`).
   **Q4_K_M is more accurate here.**
2. Handwriting arrows — f16 emitted an unmapped glyph (`□`), Q4_K_M simply
   omitted it. Neither is perfect (the source has `→`), but Q4_K_M's omission is
   cleaner than a broken glyph.

### Speed (seconds, lower is better)

| Case | f16 | Q8_0 | Q4_K_M |
|---|---|---|---|
| Invoice page | 9.5 | 8.0 | **7.6** |
| Dense formulas | 19.9 | 17.7 | **16.5** |
| Handwriting | 10.7 | 9.3 | **8.9** |
| KIE | 6.0 | 5.1 | **4.6** |

### Memory (RSS delta of the server process, incl. KV cache + mmproj)

| Variant | Model file | Actual usage |
|---|---|---|
| f16 | 1485 MB | 1831 MB |
| Q8_0 | 794 MB | 1714 MB |
| **Q4_K_M** | **516 MB** | **1507 MB** |

### Which to use

**Q4_K_M** — best on every axis in this test set (smallest, fastest, no accuracy
loss). Use `Q8_0` if you want extra fidelity headroom; it is close to lossless.

---

## Known limitations

- **Character-level errors still happen.** A 0.8B model confuses similar
  glyphs — observed: `¥128,450.00` read as `￥128.450.00` in one KIE run.
  Validate critical numeric fields (amounts, IDs) independently.
- **Raw output is OTSL, not Markdown tables.** Prompting for OTSL is what the
  upstream pipeline does; converting OTSL to Markdown tables is done by the
  upstream post-processor (`postprocess/otsl.py`), which is **not** included
  here. If you want Markdown tables directly, change the prompt.
- **Long documents** need chunking. Context is 8192 here; an A4 page rendered at
  150 DPI already consumes ~1100–2300 prompt tokens.
- **Handwriting / low-quality scans** vary a lot in quality.
- Benchmark numbers are from a single machine and a 4-case set. They indicate
  relative behaviour between precisions, not absolute throughput on your
  hardware.

---

## License and attribution

Apache License 2.0 — same as the original project.

- Original model: [SeerRay-Lab/Xiaomi-OCR-0](https://huggingface.co/SeerRay-Lab/Xiaomi-OCR-0) @ `e4d1c4a6`
- Original code: [SeerRay-Lab/Xiaomi-OCR-0](https://github.com/SeerRay-Lab/Xiaomi-OCR-0) @ `6499f6c8`
- Copyright of the model weights remains with SeerRay-Lab.

Changes made are documented in [`NOTICE`](NOTICE), as required by Apache-2.0
§4(b): format conversion to GGUF and lossy quantization. No fine-tuning,
pruning, or other modification of the parameters was performed.

The scripts and evaluation data added in this repository are new work by
[xzl01](https://github.com/xzl01), also under Apache-2.0.
