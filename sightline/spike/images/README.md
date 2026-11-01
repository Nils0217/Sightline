<!-- labels: spike, testing -->
# Spike test images

Drop 5 test photos here (JPEG, PNG or iPhone HEIC). They are reused for every spike run to keep API cost low.

Requirements:
- At least one photo of a table with several similar items (e.g. two cups, three remotes).
- Indoor scenes, one clear graspable object in each of the other photos.
- Any resolution; the script downscales to 512 px on the long edge before upload.

Avoid faces and personal documents: images are sent to the Meta Model API.

2026-10-31: these still photos test recognition and segmentation only; the hold check and hand motion need the device tests in `docs/FIND_TEST.md`.
