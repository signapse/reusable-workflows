---
status: proposed
date: 2026-11-23
deciders: Alexandru Balau
---

# We run our own Risk Check instead of CodeRabbit's Merge Risk

CodeRabbit, which we already pay for, can rate merge risk and auto-approve Low-risk pull requests. We build our own Risk Check instead, run as a GitHub Action from this repo under a dedicated GitHub App, because the tiers must come from our Catalogue and Rubric, and CodeRabbit only takes 3,000 characters of guidance plus path exclusions. Its scoring is also a vendor model that can change without notice, which is weak evidence for an auditor, and its comments are long where ours must be one line.

Bias is the deciding concern. Factory agents already argue with CodeRabbit in review threads, so the agent writing a change could talk its judge down. The Risk Check sees the diff and repo but not the Writer's reasoning. It reads its rules from `main`, so a pull request can't loosen them. File paths set a Risk Floor it can't lower, and when it is unsure, fails or times out, the pull request is High.

## Consequences

- No Claude plugin or vendor tool did this when we looked (Nov 2026). PagerDuty's risk scoring is advisory only, and Greptile and cubic overlap CodeRabbit.
- The Risk Check runs in a context separate from the factory's code-review and security-review audits, and never on the Writer's machine.
