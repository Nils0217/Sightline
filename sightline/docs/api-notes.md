<!-- labels: reference, important -->
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
