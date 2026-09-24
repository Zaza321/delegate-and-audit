"""Focused offline checks for the public release candidate."""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

scripts = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(scripts))
from sensitive_paths import sensitive_path

spec = importlib.util.spec_from_file_location("deepseek_worker", scripts / "Invoke-DeepSeek.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
review_spec = importlib.util.spec_from_file_location("cross_review", scripts / "Invoke-CrossReview.py")
review = importlib.util.module_from_spec(review_spec)
review_spec.loader.exec_module(review)

for path in (".env-local", ".env_prod", "prod.env", "config/app.env",
             "user.ppk", "store.jks", "key.p8", "main.tfvars",
             "main.tfvars.json", ".docker/config.json"):
    assert sensitive_path(path), path
for path in ("src/app.py", "README.md", "config/example.yaml"):
    assert not sensitive_path(path), path

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    (root / "README.md").write_text("A real project file for offline testing.\n", encoding="utf-8")
    (root / ".env-local").write_text("SECRET_SENTINEL\n", encoding="utf-8")
    (root / "model.onnx").write_bytes(b"\0binary")
    (root / "data.sqlite").write_bytes(b"\xff\xfe\0binary")
    (root / "package-lock.json").write_text("x" * 70_000, encoding="utf-8")
    skipped = []
    bundle, included, omitted = worker.context_pack(root, skipped=skipped)
    assert not omitted
    assert included == ["README.md"], included
    assert "SECRET_SENTINEL" not in bundle
    reasons = {item["path"]: item["reason"] for item in skipped}
    assert reasons["model.onnx"] == "binary_nontext"
    assert reasons["data.sqlite"] == "binary_nontext"
    assert reasons["package-lock.json"] == "generated_bulk"
    (root / "oversized.py").write_text("x" * 70_000, encoding="utf-8")
    _, _, omitted = worker.context_pack(root)
    assert omitted, "Unbounded source text must still fail closed"

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    for number in range(1500):
        (root / f"frame_{number:04d}_{'x' * 82}.png").write_bytes(b"\0")
    bundle, included, omitted = worker.context_pack(root)
    assert not omitted and not included
    assert len(bundle) <= 180_000, len(bundle)
    assert bundle.count("frame_0000_") == 1
    short_bundle, _, short_omitted = worker.context_pack(root, max_chars=5000)
    assert short_omitted and len(short_bundle) <= 5000
    assert "CONTEXT_COMPLETE=false" in short_bundle

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    (root / "README.md").write_text("A project description long enough for a review.\n", encoding="utf-8")
    (root / ".env-local").write_text("SECRET_SENTINEL\n", encoding="utf-8")
    docker = root / ".docker"
    docker.mkdir()
    (docker / "config.json").write_text("SECRET_SENTINEL\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(root), "-c", "user.name=Offline Test",
                    "-c", "user.email=offline@example.invalid", "commit", "-qm", "fixture"], check=True)
    source = review.get_source(root)
    assert list(source["files"]) == ["README.md"], source["files"]

print(json.dumps({"sensitive_policy": "passed", "context_pack": "passed",
                  "context_size_limit": "passed",
                  "cross_review_snapshot_filter": "passed"}))
