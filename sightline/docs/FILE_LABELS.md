<!-- labels: important, reference -->
# File labels

Every file carries a label line at the top so its status is clear at a glance:

- Markdown: `<!-- labels: a, b -->`
- Python / shell / gitignore / env: `# labels: a, b`
- Swift: `// labels: a, b`

Search a label across the repo: `grep -rn "labels:.*needs-review" .`

## Label set

| Label | Meaning |
|---|---|
| `important` | Source of truth or must-read before working (rules, scope, tasks) |
| `production` | Ships in the iOS app |
| `spike` | Experiment to de-risk a question; not shipped |
| `testing` | Tests, test fixtures, test instructions |
| `needs-review` | Written by an agent, not yet run or reviewed by Nils |
| `verified` | Run and confirmed working by Nils (note date in the registry) |
| `sensitive` | Contains or handles secrets / personal data; never commit real values or share |
| `config` | Build, tooling or repo configuration |
| `reference` | Notes and docs for lookup, not instructions |
| `generated` | Machine output; do not edit by hand |
| `muse-code` | Written by Muse Code (track for hackathon disclosure) |
| `obsolete` | No longer used; kept until Nils deletes it. Agents never delete files |

A file can carry several labels. When a label changes (e.g. `needs-review` → `verified`), update the file header and this table in the same commit.

## Registry

| File | Labels | Notes |
|---|---|---|
| `AGENTS.md` | important | Shared agent rules; wins over PRD on conflicts |
| `CLAUDE.md` | important, config | Imports `AGENTS.md` for Claude Code |
| `README.md` | important | Public project summary for judges |
| `.gitignore` | config, important | Keeps secrets and build output out of git |
| `.env.example` | config | Template; copy to `.env` and add the key |
| `.env` (not in git) | sensitive | Real API key; gitignored |
| `docs/PRD.md` | important | Scope, milestones, metrics |
| `docs/SPIKE.md` | important, testing | Current task list and results table |
| `docs/CLAUDE_CODE_PROMPT.md` | reference | Kickoff prompt used to start Spike 0 |
| `docs/FILE_LABELS.md` | important, reference | This file |
| `docs/api-notes.md` | reference, important | Verified Meta Model API request shapes and prices |
| `docs/ARKIT_SAMPLE.md` | testing, reference | How to run Apple's ARKit sample on the iPhone (S0.1) |
| `spike/model_api_spike.py` | spike, needs-review, sensitive | Muse Spark + SAM 3.1 round trip; reads the API key |
| `spike/requirements.txt` | spike, config | Python deps for the spike |
| `spike/images/README.md` | spike, testing | Where to put the 5 test photos |
| `spike/out/` (not in git) | generated | Mask overlay PNGs |
| `logs/api_calls.csv` (not in git) | generated | Latency and cost log of every API call |
