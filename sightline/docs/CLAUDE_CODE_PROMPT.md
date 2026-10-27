# Claude Code kickoff prompt — Spike 0

Run from the repo root: `cd ~/Sightline && claude`, then paste everything below the line.

---

You are my technical partner on **Sightline**, a Meta Global AI Developer Hackathon project (Oct 26 – Nov 4, 2026). Read `AGENTS.md`, `docs/PRD.md` and `docs/SPIKE.md` first and follow them. I am not fluent in Swift; you write the code, I run it on the iPhone 15 Pro and report back.

Tonight's goal is **Spike 0** in `docs/SPIKE.md`. Do it in this order and stop at each checkpoint.

**Task 1: repo hygiene**
- Confirm `.gitignore` covers `.env`, `Secrets.xcconfig`, `logs/`, Xcode build output. Add `logs/` if missing.
- Create `.env.example` with `META_MODEL_API_KEY=` (no real value) and `spike/images/` with a `README.md` telling me to drop 5 test photos there (one must be a table with several similar items).
- Commit: `chore: spike scaffolding`.

**Task 2: Model API spike script** (`spike/model_api_spike.py`)
- Before writing request code, look up the current Meta Model API docs (https://dev.meta.ai/docs) for: Muse Spark chat/Responses with image input and `reasoning_effort`, and SAM 3.1 text-prompted image segmentation (request and response shape). Do not guess field names. Write what you find, with the doc URL, to `docs/api-notes.md`.
- Script flow for each image in `spike/images/`: downscale to 512 px long edge → Muse Spark (`muse-spark-1.3` or the latest non-contributor model the docs list, `reasoning_effort: medium`) returns ONE short noun for the main graspable object, or `UNSURE` → SAM 3.1 segments by that noun → save a mask overlay PNG to `spike/out/` → append a row to `logs/api_calls.csv`: timestamp, image, model, noun, latency_ms, input_tokens, output_tokens, est_cost_usd.
- Use Python stdlib + `openai` (OpenAI-compatible client, base URL `https://api.meta.ai/v1`) + `Pillow` only. Read the key from `.env`. Add `spike/requirements.txt`.
- Print a summary table at the end.
- **Checkpoint:** stop and tell me the exact commands to run. I will run it and paste the output.

**Task 3: ARKit sample instructions**
- Give me step-by-step instructions (Xcode menu paths) to download, sign with my free Apple ID, and run Apple's sample "Visualizing and Interacting with a Reconstructed Scene" on the iPhone 15 Pro, including Developer Mode and trusting the developer certificate on the phone.
- Do not copy Apple's sample into this repo.
- **Checkpoint:** wait for my result.

**Task 4: record results**
- When I paste results, fill the S0.1 / S0.2 rows in `docs/SPIKE.md` and commit: `docs: spike 0 results`.
- Then propose the plan for G1 (hand 3D accuracy) as a short file list + steps. Do not write the G1 code until I approve.

**Rules**
- Zero out-of-pocket: never suggest a paid plan; keep calls minimal; reuse the same 5 images.
- Never print or commit the API key.
- Keep explanations short. Commit messages end with your usual co-author line.
- I prefer replies in Traditional Chinese with technical terms in English.
