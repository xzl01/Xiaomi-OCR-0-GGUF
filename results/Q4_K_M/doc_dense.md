## 3. Multi Factor Sample Mining

For each region sample we compute three orthogonal signals: annotation reliability \(a_i\), inference difficulty \(c_i\), and semantic cluster index \(k(i)\). Hard samples target high \(a_i\) and low \(c_i\) under a two stage cluster based sampling scheme.

Sampling probability:

\[ P_i = \text{softmax} \left( \left( f_a \log(a_i + \epsilon) + f_c \log(1 - c_i + \epsilon) \right) / T \right) \]

Table 2. Reward components used in RL.

| Component          | Score | Aspect                  | Weight |
|--------------------|-------|-------------------------|--------|
| Text               | 1 NED | Text fidelity           | \(w_{text}\) |
| Formula            | CDM   | Visual match            | \(w_{formula}\) |
| Table              | TEDS  | Content topo            | \(w_{table}\) |
| Table struct       | TEDS S | Topology only           | \(\omega\) |

We adopt a length penalty that zeros the reward for overlong predictions. CDM ground truth rendering is cached by content hash, skipping 87% of repeated LaTeX to bbox work with 8 rollouts per prompt. Complexity buckets group long outputs into low concurrency batches to avoid rollout timeouts.