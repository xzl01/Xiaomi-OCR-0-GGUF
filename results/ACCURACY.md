# 量化精度对比（2026-10-01）

测试集：发票整页 / 密集公式文档 / 手写体 / KIE 关键信息抽取
对比方式：字符级相似度（difflib.SequenceMatcher）

| 用例 | f16→Q8_0 | f16→Q4_K_M |
|---|---|---|
| 发票整页 | 100.0% | 100.0% |
| 密集公式 | 99.1% | 96.6% |
| 手写体 | 100.0% | 99.5% |
| KIE | 100.0% | 100.0% |

## 差异逐条核对：Q4 没有变差

1. **表格权重列**（占大部分 96.6% 差异）
   - f16: `| Formula | CDM | Visual match | w formula |`    下标丢失
   - Q4:  `| Formula | CDM | Visual match | \(w_{formula}\) |`  正确
   - **Q4 更准**

2. **手写体箭头**
   - f16: `Q-Mask text-anchoring first □ spatial grounding`（输出乱码字形）
   - Q4:  `Q-Mask text-anchoring first spatial grounding`（省略）
   - 两者都不完美（原图应为 →），但 **Q4 的省略比乱码干净**

3. 发票 / KIE：**逐字节一致**

## 性能

| 用例 | f16 | Q8_0 | Q4_K_M |
|---|---|---|---|
| 发票整页 | 9.5s | 8.0s | **7.6s** |
| 密集公式 | 19.9s | 17.7s | **16.5s** |
| 手写体 | 10.7s | 9.3s | **8.9s** |
| KIE | 6.0s | 5.1s | **4.6s** |

实际内存占用（含 KV cache + mmproj）：
f16 1831 MB / Q8_0 1714 MB / **Q4_K_M 1507 MB**

## 结论

**默认用 Q4_K_M。** 本测试集上无精度损失，且更快更省内存。
需要更高保真度时切 Q8_0（`--model model-q8_0.gguf`）。
