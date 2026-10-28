# labels: testing, needs-review
"""Build SAM decoding fixtures for the Swift tests from real spike outputs.

Reads spike/out/*.sam.txt, decodes every record with Meta's meta-sam-parser and writes
Packages/SightlineCore/Tests/SightlineCoreTests/Fixtures/sam_fixtures.json:
the raw SAM text plus, per record, the box, confidence, mask size, number of set
pixels, SHA-256 of the 0/1 raster and its centroid. The Swift port must match exactly.

Run: .venv/bin/python tools/make_sam_fixtures.py
"""
import hashlib
import json
from pathlib import Path

from meta_sam_parser import (
    CompletedOutcome,
    SegmentationMaskRecord,
    decode_mask_to_raster,
    image_segmentation_format,
)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Packages/SightlineCore/Tests/SightlineCoreTests/Fixtures/sam_fixtures.json"

fixtures = []
for path in sorted((ROOT / "spike/out").glob("*.sam.txt")):
    text = path.read_text()
    parser = image_segmentation_format().create_parser()
    parser.push(text if text.endswith("\n") else text + "\n", emit=False)
    records = []
    for r in parser.finish(CompletedOutcome()).result.records:
        if not isinstance(r, SegmentationMaskRecord):
            continue
        raster = decode_mask_to_raster(r.mask)
        w, h = r.mask.width, r.mask.height
        ones = [(i % w, i // w) for i, v in enumerate(raster) if v]
        cx = sum(x for x, _ in ones) / len(ones) if ones else None
        cy = sum(y for _, y in ones) / len(ones) if ones else None
        records.append({
            "id": r.object_id,
            "left": r.bounds.left, "top": r.bounds.top, "right": r.bounds.right, "bottom": r.bounds.bottom,
            "confidence": r.confidence,
            "mask_width": w, "mask_height": h,
            "ones": len(ones),
            "sha256": hashlib.sha256(bytes(raster)).hexdigest(),
            "centroid_x": cx, "centroid_y": cy,
        })
    fixtures.append({"name": path.stem.removesuffix(".sam"), "text": text, "records": records})
    print(f"{path.name}: {len(records)} records")

OUT.write_text(json.dumps(fixtures, indent=1))
print(f"wrote {OUT.relative_to(ROOT)}")
