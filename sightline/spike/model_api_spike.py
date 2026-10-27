# labels: spike, needs-review, sensitive (reads the API key from .env; never prints it)
"""Spike 0 / S0.2: Muse Spark names the main object, SAM 3.1 segments it.

For each image in spike/images/:
  downscale to 512 px -> Muse Spark (one noun or UNSURE) -> SAM 3.1 by that noun
  -> mask overlay PNG in spike/out/ -> one row per API call in logs/api_calls.csv.

Request shapes: docs/api-notes.md.

Usage (from the sightline/ folder):
  python3 spike/model_api_spike.py            # all images
  python3 spike/model_api_spike.py --limit 1  # first image only (cheap smoke test)
"""

from __future__ import annotations

import argparse
import base64
import csv
import io
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from openai import OpenAI
from PIL import Image, ImageDraw, ImageOps

try:  # Meta's official mask decoder; optional until approved as a dependency.
    from meta_sam_parser import (
        CompletedOutcome,
        SegmentationMaskRecord,
        decode_mask_to_raster,
        image_segmentation_format,
    )
    HAVE_SAM_PARSER = True
except ImportError:
    HAVE_SAM_PARSER = False

ROOT = Path(__file__).resolve().parent.parent
IMAGES_DIR = ROOT / "spike" / "images"
OUT_DIR = ROOT / "spike" / "out"
LOG_PATH = ROOT / "logs" / "api_calls.csv"
ENV_PATH = ROOT / ".env"

BASE_URL = "https://api.meta.ai/v1"
SAM_MODEL = "sam-3.1"
MAX_EDGE_PX = 512
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}  # no HEIC: Pillow cannot open it

# USD, from https://dev.meta.ai/docs/pricing-rate-limits (2026-10-27).
SPARK_INPUT_PER_M = 1.25
SPARK_OUTPUT_PER_M = 4.25  # reasoning tokens are billed as output
SAM_PER_IMAGE = 0.0025

NAMING_PROMPT = (
    "You help a blind user find objects. Name the single main graspable object in this photo "
    "as one short lowercase noun phrase (1 to 3 words) that works as a segmentation prompt, "
    "e.g. 'cup' or 'tv remote'. If you are not sure, reply exactly UNSURE. "
    "Reply with the noun phrase only."
)

LOG_FIELDS = [
    "timestamp", "image", "model", "noun", "latency_ms",
    "input_tokens", "output_tokens", "est_cost_usd",
]

BOX_RE = re.compile(r"<\|box;([^|]*)\|>")


def load_api_key() -> str:
    """Read META_MODEL_API_KEY from the environment or sightline/.env."""
    key = os.environ.get("META_MODEL_API_KEY", "")
    if not key and ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            name, sep, value = line.partition("=")
            if sep and name.strip() == "META_MODEL_API_KEY":
                key = value.strip().strip("'\"")
    if not key:
        sys.exit("Missing META_MODEL_API_KEY: copy .env.example to .env and add your key.")
    return key


def downscale(path: Path) -> Image.Image:
    """Apply EXIF rotation and shrink so the long edge is at most MAX_EDGE_PX."""
    img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    img.thumbnail((MAX_EDGE_PX, MAX_EDGE_PX))
    return img


def to_data_url(img: Image.Image) -> str:
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def user_message(text: str, data_url: str) -> list[dict]:
    return [{
        "type": "message",
        "role": "user",
        "content": [
            {"type": "input_text", "text": text},
            {"type": "input_image", "image_url": data_url},
        ],
    }]


def log_call(image: str, model: str, noun: str, latency_ms: float,
             input_tokens: int | None, output_tokens: int | None, cost: float) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    is_new = not LOG_PATH.exists()
    with LOG_PATH.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=LOG_FIELDS)
        if is_new:
            writer.writeheader()
        writer.writerow({
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "image": image,
            "model": model,
            "noun": noun,
            "latency_ms": round(latency_ms),
            "input_tokens": "" if input_tokens is None else input_tokens,
            "output_tokens": "" if output_tokens is None else output_tokens,
            "est_cost_usd": f"{cost:.6f}",
        })


def name_object(client: OpenAI, model: str, data_url: str) -> tuple[str, float, int, int, float]:
    """Return (noun, latency_ms, input_tokens, output_tokens, cost_usd)."""
    start = time.perf_counter()
    response = client.responses.create(
        model=model,
        input=user_message(NAMING_PROMPT, data_url),
        reasoning={"effort": "medium"},
        max_output_tokens=1024,  # covers reasoning + the one-word answer
    )
    latency_ms = (time.perf_counter() - start) * 1000
    noun = (response.output_text or "").strip().strip(".'\"").lower() or "unsure"
    if noun == "unsure":
        noun = "UNSURE"
    usage = response.usage
    in_tok = usage.input_tokens if usage else 0
    out_tok = usage.output_tokens if usage else 0
    cost = in_tok / 1e6 * SPARK_INPUT_PER_M + out_tok / 1e6 * SPARK_OUTPUT_PER_M
    return noun, latency_ms, in_tok, out_tok, cost


def segment(client: OpenAI, noun: str, data_url: str) -> tuple[str, float, int | None, int | None]:
    """Return (raw SAM output text, latency_ms, input_tokens, output_tokens)."""
    start = time.perf_counter()
    stream = client.responses.create(
        model=SAM_MODEL,
        input=user_message(noun, data_url),
        stream=True,
        metadata={"include_confidence": "true"},
    )
    deltas: list[str] = []
    final_parts: list[str] = []
    usage = None
    for event in stream:
        if event.type == "response.output_text.delta":
            deltas.append(event.delta)
        elif event.type == "response.content_part.done" and getattr(event.part, "type", "") == "output_text":
            final_parts.append(event.part.text)
        elif event.type == "response.completed":
            usage = event.response.usage
    latency_ms = (time.perf_counter() - start) * 1000
    # The live SAM API may finalize only via content_part.done; prefer it when present.
    text = "".join(final_parts) or "".join(deltas)
    in_tok = usage.input_tokens if usage else None
    out_tok = usage.output_tokens if usage else None
    return text, latency_ms, in_tok, out_tok


def parse_boxes(sam_text: str) -> list[dict[str, float]]:
    boxes = []
    for fields in BOX_RE.findall(sam_text):
        pairs = dict(kv.split("=", 1) for kv in fields.split(";") if "=" in kv)
        try:
            boxes.append({k.strip(): float(v) for k, v in pairs.items()})
        except ValueError:
            continue
    return boxes


def draw_overlay(img: Image.Image, sam_text: str, noun: str, out_path: Path) -> int:
    """Draw masks (if the parser is installed) and boxes; return the number of objects."""
    overlay = img.convert("RGBA")
    if HAVE_SAM_PARSER:
        parser = image_segmentation_format().create_parser()
        parser.push(sam_text if sam_text.endswith("\n") else sam_text + "\n", emit=False)
        records = parser.finish(CompletedOutcome()).result.records
        for record in records:
            if not isinstance(record, SegmentationMaskRecord):
                continue
            raster = decode_mask_to_raster(record.mask)
            w, h = record.mask.width, record.mask.height
            alpha = Image.frombytes("L", (w, h), bytes(v * 120 for v in raster))
            tint = Image.new("RGBA", (w, h), (0, 200, 255, 0))
            tint.putalpha(alpha)
            overlay.alpha_composite(tint, (int(record.bounds.left), int(record.bounds.top)))

    boxes = parse_boxes(sam_text)
    draw = ImageDraw.Draw(overlay)
    for i, box in enumerate(boxes):
        # Scale in case SAM reports a frame size different from the uploaded image.
        sx = img.width / box.get("w", img.width)
        sy = img.height / box.get("h", img.height)
        rect = (box["x1"] * sx, box["y1"] * sy, box["x2"] * sx, box["y2"] * sy)
        draw.rectangle(rect, outline=(255, 60, 60, 255), width=2)
        label = f"{noun} #{i}" + (f" {box['c']:.2f}" if "c" in box else "")
        draw.text((rect[0] + 3, rect[1] + 3), label, fill=(255, 255, 0, 255))
    overlay.convert("RGB").save(out_path)
    return len(boxes)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="muse-spark-1.3", help="Muse Spark model id (not -contributor)")
    parser.add_argument("--limit", type=int, default=0, help="process only the first N images")
    args = parser.parse_args()

    images = sorted(p for p in IMAGES_DIR.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)
    if args.limit:
        images = images[: args.limit]
    if not images:
        sys.exit(f"No images in {IMAGES_DIR}. See spike/images/README.md.")
    if not HAVE_SAM_PARSER:
        print("Note: meta-sam-parser not installed; overlays show boxes only, no masks.\n")

    client = OpenAI(base_url=BASE_URL, api_key=load_api_key())
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    rows = []
    for path in images:
        img = downscale(path)
        data_url = to_data_url(img)
        row = {"image": path.name, "noun": "-", "spark_ms": 0.0, "sam_ms": 0.0, "objects": 0, "cost": 0.0, "error": ""}
        try:
            noun, ms, in_tok, out_tok, cost = name_object(client, args.model, data_url)
            log_call(path.name, args.model, noun, ms, in_tok, out_tok, cost)
            row.update(noun=noun, spark_ms=ms, cost=cost)

            if noun != "UNSURE":
                sam_text, ms, in_tok, out_tok = segment(client, noun, data_url)
                log_call(path.name, SAM_MODEL, noun, ms, in_tok, out_tok, SAM_PER_IMAGE)
                row.update(sam_ms=ms, cost=row["cost"] + SAM_PER_IMAGE)
                (OUT_DIR / f"{path.stem}.sam.txt").write_text(sam_text)
                row["objects"] = draw_overlay(img, sam_text, noun, OUT_DIR / f"{path.stem}_mask.png")
        except Exception as exc:  # keep going so one bad image doesn't waste the run
            row["error"] = f"{type(exc).__name__}: {exc}"[:120]
        rows.append(row)
        print(f"{path.name}: {row['noun']} ({row['objects']} objects){'  ERROR ' + row['error'] if row['error'] else ''}")

    print()
    header = f"{'image':<28}{'noun':<18}{'spark ms':>9}{'sam ms':>9}{'objs':>6}{'cost $':>10}"
    print(header)
    print("-" * len(header))
    for r in rows:
        print(f"{r['image'][:27]:<28}{r['noun'][:17]:<18}{r['spark_ms']:>9.0f}{r['sam_ms']:>9.0f}{r['objects']:>6}{r['cost']:>10.4f}")
    total = sum(r["cost"] for r in rows)
    print("-" * len(header))
    print(f"{'total':<28}{'':<18}{'':>9}{'':>9}{'':>6}{total:>10.4f}")
    print(f"\nOverlays: {OUT_DIR}\nLog: {LOG_PATH}")


if __name__ == "__main__":
    main()
