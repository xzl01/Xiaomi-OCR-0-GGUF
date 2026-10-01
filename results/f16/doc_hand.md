Research Notes — 2026.03.12

Qwen3.5-0.8B post-train recipe (ckpt-139k)

1) Q-Mask text-anchoring first □ spatial grounding

2) mixCPT on doc-region corpus (170M-ish)

3) GRPO with composite reward:

text: 1 - NED

table: TEDS / TEDS-S

formula: CDM

4) MOPD 3x4B teachers □ student

TODO: verify OTSLHTML converter on nested tables

NOTE: region crop beats full-page on dense papers