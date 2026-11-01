<!-- labels: reference, important -->

> Update 2026-10-31: this document keeps the original experiment and reference record. Current find-and-grab behaviour, call counts and acceptance are in [PRD](PRD.md), [TEST_LOG](TEST_LOG.md) (T10) and [FIND_TEST](FIND_TEST.md). Earlier passes do not mean the current version has been tested on the device or with blind users.
# Meta Model API notes

Verified against the official docs on 2026-10-27. Update this file whenever a request shape is confirmed or changes on a live call.

## Basics
- Base URL: `https://api.meta.ai/v1` (OpenAI-compatible). Source: https://dev.meta.ai/docs
- Auth: `Authorization: Bearer <key>`. Our key lives in `.env` as `META_MODEL_API_KEY` (docs call it `MODEL_API_KEY`).
- Python: official `openai` SDK with `base_url="https://api.meta.ai/v1"`.

## Models (https://dev.meta.ai/docs/models)
| Model | Use |
|---|---|
| `muse-spark-1.3` | Commander. Standard mode; use this one |
| `muse-spark-1.3-contributor` | Cheaper, but Meta may train on our content. **Do not use** (user images of homes) |
| `sam-3.1` | Text-prompted image / video segmentation |

## Muse Spark — image input (https://dev.meta.ai/docs/image-understanding, https://dev.meta.ai/docs/reasoning)

Responses API, `POST /v1/responses`:

```python
client.responses.create(
    model="muse-spark-1.3",
    input=[{
        "type": "message",
        "role": "user",
        "content": [
            {"type": "input_text", "text": "..."},
            {"type": "input_image", "image_url": f"data:image/jpeg;base64,{b64}"},
        ],
    }],
    reasoning={"effort": "medium"},
    max_output_tokens=1024,
)
# text: response.output_text ; usage: response.usage.input_tokens / output_tokens
```

- Reasoning effort: Responses API uses `reasoning: {"effort": ...}`; Chat Completions uses top-level `reasoning_effort`. Values: `minimal, low, medium, high, xhigh, max`. `none` returns HTTP 400.
- Output cap: `max_output_tokens` (Responses) / `max_tokens` (Chat Completions). **Reasoning tokens count toward the cap and are billed as output**, so the cap cannot be tiny even for one-word answers.
- Images only in `user` messages. JPEG / PNG / GIF / WebP. ≤ 50 MB inline, ≤ 50 images per request.
- Chat Completions alternative: `{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}`, read `choices[0].message.content`.

## SAM 3.1 — text-prompted image segmentation (https://dev.meta.ai/docs/sam/segmenting)

`POST /v1/responses`, streamed:

```python
stream = client.responses.create(
    model="sam-3.1",
    input=[{
        "type": "message",
        "role": "user",
        "content": [
            {"type": "input_text", "text": "cup"},          # one short noun phrase
            {"type": "input_image", "image_url": data_url},  # URL or base64 data URL
        ],
    }],
    stream=True,
    metadata={"include_confidence": "true"},  # optional: adds c= to records
)
# collect event.delta from "response.output_text.delta" events
```

Output (https://dev.meta.ai/docs/sam/reading-segmentation) is special-token text, one line per frame:

```text
<0f>0<|box;x1=..;y1=..;x2=..;y2=..;w=<W>;h=<H>[;c=..]|><|mask;x=0;y=0;data=<h>,<w>,~<base85>|>,1<|box;...|><|mask;...|>
```

- Box corners are source pixels, `x2`/`y2` inclusive. `w`/`h` = source image size.
- Mask raster is box-local (`h`×`w` = box height × width), placed at the box's top-left.
- Mask payload is a custom base85 (`~` lossless default, `!` one_bit via `metadata.mask_encoding: "one_bit"`). Do not hand-decode; use Meta's parser.
- Decoder: `meta-sam-parser` on PyPI (Meta, dependency-free, Python ≥ 3.10): `image_segmentation_format().create_parser()`, `.push(text)`, `.finish(CompletedOutcome()).result.records`, `decode_mask_to_raster(record.mask)` → row-major 0/1 bytes. Repo: https://github.com/meta-models/meta-sam. A Swift port will be needed for the app.

## Prices (https://dev.meta.ai/docs/pricing-rate-limits)
| Item | Price |
|---|---|
| `muse-spark-1.3` input | $1.25 / 1M tokens |
| `muse-spark-1.3` output (incl. reasoning) | $4.25 / 1M tokens |
| `muse-spark-1.3` cached input | $0.15 / 1M tokens |
| `sam-3.1` image | $0.0025 / image |
| `sam-3.1` video | $0.20 / 1000 frames, min 50 frames per request |

Rate limits (per team): `muse-spark-1.3` 3000 RPM / 4M TPM; `sam-3.1` 3000 RPM.

## Confirmed on live calls
2026-10-27, first spike run (5 iPhone photos, 512×384 JPEG, `muse-spark-1.3`, effort `medium`):
- Responses API image request worked as documented. Input = **343 tokens** (prompt + one 512 px image).
- Reasoning used **755 to over 1024 output tokens** for a one-word answer. With `max_output_tokens=1024`, 3/5 calls hit the cap and `output_text` came back empty. Raised to 2048.
- Latency **4.6–7.5 s** per Spark call. This alone breaks the G4 target (command → first guidance ≤ 3 s); see the open question in `docs/SPIKE.md`.
- Cost ≈ $0.004–0.005 per Spark image call, almost all of it reasoning tokens.

2026-10-27, second run (ranked-list prompt, cap 2048):
- Spark input **360 tokens**; output 849–1970 tokens (reasoning ≈ 99%). Latency 4.1–11.5 s. Raised cap to 4096.
- SAM 3.1 streamed request worked as documented. Latency **0.5–1.5 s**. `usage` reports 0 tokens (billed per image).
- `metadata={"include_confidence": "true"}` adds `c=` to both box and mask tokens.
- One noun can return several objects (ids 0,1,2), **not sorted by confidence**.
- `meta-sam-parser` 0.1.0 decoded all masks; mask raster is box-local as documented.

## Fine-tuning (checked 2026-10-28)
- Hosted `muse-spark-1.3` and `sam-3.1` on the Model API: **no fine-tuning, LoRA or custom training is documented.** Source: https://dev.meta.ai/docs (full section list).
- Post-training exists only for the **open-weight** models, self-hosted with TorchTitan (SFT on own text/image/audio conversations, or RL with GRPO): https://dev.meta.ai/docs/cookbook/post-training
  - Muse Spark Open: 816B MoE, 42B active. Muse Glimmer: 30B, "built for local and edge deployment". Both need your own GPUs; not covered by the Model API credit. https://dev.meta.ai/docs/open-weight-models
- For accuracy at `minimal` effort use the levers the hosted API has: tighter prompts with a few examples, structured output (https://dev.meta.ai/docs/structured-output), prompt caching for the fixed prefix ($0.15 / 1M cached input), and on-device context (the user's spoken noun) so the model has less to infer.

## Muse Spark tool calling (https://dev.meta.ai/docs/tool-calling; confirmed live 2026-10-28)
- `tools`: flat `{"type":"function","name","description","parameters":{JSON Schema, "type":"object"}}`; optional `strict`.
- Output items with `type: "function_call"`: `name`, `arguments` (JSON string), `call_id`.
- Return results with a new request: `input` = `[{"type":"function_call_output","call_id","output": "<string>"}]`, `previous_response_id` = the previous response's `id`, same `tools`.
- `tool_choice`: only `"auto"` (others → HTTP 400), so handle plain-text replies too. `parallel_tool_calls: false` = at most one call per turn.
- Used by `Sightline/Sightline/API/MuseAgent.swift`; smoke test `spike/agent_spike.py`.
- **Live (2026-10-28, spike/agent_spike.py):** shapes work as documented; Spark used get_state / find_object / ask_user / say / select_target sensibly.
- **Do not use `previous_response_id` for latency-sensitive loops.** Follow-up turns took 9.5–29.7 s with it vs 0.9–4.5 s when we resend the history (`input` = original message + each `function_call` item + its `function_call_output`). First turns ~1.2–1.8 s either way.
- Putting the state in the first message removes the get_state turn: "I'm thirsty" 21 s → 7.8 s (manual history) → 4.8 s (+ state in prompt). Two-cups case 56 s → 8–13 s (medium; plus the user's answer time).

## SAM 3.1: empty output = nothing found (2026-10-29)
When the noun is not in the image, the stream completes with status 200 and **no `output_text` at all**: no records, and no error event. Treat this as "no instance", not as an error. Until v4 the app threw `emptyOutput`, so these calls were logged as `api_error` (`docs/TEST_LOG.md` 5.2). The call is still billed per image.

## Muse Spark: several images in one message (2026-10-29)
The strict hold check sends two `input_image` parts after the text, in order (reference photo, then the current hand crop), and refers to them as "image 1" and "image 2" in the prompt. The docs allow up to 50 images per request. This shape is built from the documented content-part format, but it has not been checked on the device yet; confirm it in the v5 run with the `hold_check_result` rows.

## Call counts, v8 (2026-10-30, obsolete)

v8 (ChatGPT rewrite) collected up to 3 hold observations per check cycle (3 SAM + 3 identity Spark calls, 35 s cap) and asked the user for a 4 cm movement. Replaced in v9; kept as a record. The request shapes did not change.

## Call counts, v9 (2026-10-31)

Each hold check is one photo: 1 SAM call (where the object is now) and 1 Spark call at minimal effort (`verifyHolding`: the photo plus the reference crop from the lock), run in parallel. Any pick-up starts one; at most 6 automatic checks per search, plus double taps; the hold-SAM budget stays 12 per search. All event-triggered. Request shapes, endpoints and models are unchanged; no new real API calls were made for this change.
