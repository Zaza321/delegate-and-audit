#!/usr/bin/env python3
"""Explicit, isolated two- or three-provider review of one frozen Git worktree state."""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from sensitive_paths import sensitive_path


PROVIDERS = ("codex", "grok", "agy", "deepseek")
EFFORTS = {
    "codex": ("low", "medium", "high", "xhigh", "max", "ultra"),
    "grok": ("low", "medium", "high", "xhigh", "max"),
    "agy": ("low", "medium", "high"),
    "deepseek": ("none", "low", "high", "max"),
}
EFFORT_FLAGS = {
    "codex": "-CodexReasoningEffort",
    "grok": "-GrokReasoningEffort",
    "agy": "-AgyReasoningEffort",
    "deepseek": "-DeepSeekReasoningEffort",
}


def run(command, cwd=None, check=True, timeout=None):
    completed = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, check=False, timeout=timeout)
    if check and completed.returncode:
        raise RuntimeError(f"Command failed ({completed.returncode}): {command[0]} "
                           f"{completed.stderr.decode('utf-8', 'replace').strip()}")
    return completed


def run_worker(command, timeout, env=None):
    """Bound a worker and terminate its process tree if the outer guard fires."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        tree_error = None
        if os.name == "nt":
            try:
                killed = subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        check=False, timeout=20)
                if killed.returncode:
                    tree_error = killed.stderr.decode("utf-8", "replace").strip()
            except (OSError, subprocess.TimeoutExpired) as exc:
                tree_error = str(exc)
        if process.poll() is None:
            process.kill()
        try:
            process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        detail = f"; process-tree termination issue: {tree_error}" if tree_error else ""
        raise TimeoutError(f"Worker exceeded outer timeout ({timeout}s){detail}")
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def git(root, *args):
    return run(["git", "-C", str(root), *args]).stdout


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_hashes(base):
    hashes = {}
    for file in sorted(base.rglob("*")):
        if file.is_symlink():
            raise RuntimeError(f"Symlink in snapshot: {file}")
        relative = file.relative_to(base).as_posix()
        if file.is_dir():
            hashes[relative + "/"] = "DIRECTORY"
        elif file.is_file():
            hashes[relative] = sha_file(file)
    return hashes


def source_tree_hashes(root):
    """Detect writes to source files, including ignored files outside .git."""
    hashes = {}
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for name in dirs:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix() + "/"
            hashes[relative] = "SYMLINK:" + os.readlink(path) if path.is_symlink() else "DIRECTORY"
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink():
                hashes[path.relative_to(root).as_posix()] = "SYMLINK:" + os.readlink(path)
            elif path.is_file():
                hashes[path.relative_to(root).as_posix()] = sha_file(path)
    return hashes


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def gitlink_paths(root):
    entries = git(root, "ls-files", "--stage", "-z", "--", ".").split(b"\0")
    result = set()
    for entry in entries:
        if not entry:
            continue
        metadata, _, path = entry.partition(b"\t")
        if metadata.startswith(b"160000 ") and path:
            result.add(Path(os.fsdecode(path)).as_posix())
    return result


def submodule_files(subroot, task_root):
    """Copy checked-out, nonignored submodule files without Git metadata."""
    files = {}
    gitlinks = gitlink_paths(subroot)
    names = git(subroot, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    for raw in names:
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("Unsafe submodule path")
        child = subroot / relative
        if relative.as_posix() in gitlinks and not (child.is_dir() and (child / ".git").exists()):
            raise RuntimeError(f"Submodule is not checked out: {child.relative_to(task_root)}")
        if child.is_symlink() or not child.resolve().is_relative_to(subroot):
            raise RuntimeError(f"Symlink in submodule: {relative}")
        if child.is_dir() and (child / ".git").exists():
            files.update(submodule_files(child, task_root))
        elif child.is_file():
            task_relative = child.relative_to(task_root).as_posix()
            if not sensitive_path(task_relative):
                files[task_relative] = sha_file(child)
        elif child.exists():
            raise RuntimeError(f"Unsupported submodule entry: {relative}")
    if not files:
        raise RuntimeError(f"Submodule has no checked-out source files: {subroot.relative_to(task_root)}")
    return files


def get_source(root, include_paths=()):
    git_root = Path(git(root, "rev-parse", "--show-toplevel").decode("utf-8").strip()).resolve()
    head = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    names = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    gitlinks = gitlink_paths(root)
    files = {}
    changed = git(root, "diff", "--name-only", "--no-renames", "-z", "HEAD", "--", ".").split(b"\0")
    staged = git(root, "diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--", ".").split(b"\0")
    worktree_changed = {raw for raw in changed if raw}
    for raw in changed + staged:
        if raw and sensitive_path(os.fsdecode(raw)):
            raise RuntimeError("Sensitive file appears in tracked diff; cross review stopped before model calls")
    index_only = {raw for raw in staged if raw} - worktree_changed
    if index_only:
        names = ", ".join(sorted(os.fsdecode(raw) for raw in index_only))
        raise RuntimeError(f"Index-only staged content cannot be represented by the working-tree snapshot: {names}")
    for raw in names:
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"Unsafe Git path: {relative}")
        source_path = root / relative
        if relative.as_posix() in gitlinks and not (source_path.is_dir() and (source_path / ".git").exists()):
            raise RuntimeError(f"Submodule is not checked out: {relative}")
        if sensitive_path(relative.as_posix()):
            continue
        if any(part.is_symlink() for part in (root, *source_path.parents, source_path)):
            raise RuntimeError(f"Symlink in source path: {relative}")
        source = source_path.resolve()
        if not source.is_relative_to(root):
            raise RuntimeError(f"Source escapes task root: {relative}")
        if not source.exists():  # tracked deletion
            continue
        if source.is_dir() and (source / ".git").exists():
            files.update(submodule_files(source, root))
            continue
        if source.is_symlink() or not source.is_file():
            raise RuntimeError(f"Unsupported source entry: {relative}")
        files[relative.as_posix()] = sha_file(source)
    for raw in include_paths:
        path = Path(raw)
        if path.is_absolute() or ".." in path.parts or sensitive_path(path.as_posix()):
            raise RuntimeError(f"Unsafe or sensitive --include-path: {raw}")
        source = root / path
        if source.is_symlink() or not source.resolve().is_relative_to(root) or not source.is_file():
            raise RuntimeError(f"--include-path must name a regular file within task root: {raw}")
        files[path.as_posix()] = sha_file(source)
    # Git's -C is rooted at root: limit review to the selected task root.
    diff = git(root, "diff", "--relative", "--binary", "--submodule=diff", "HEAD", "--", ".")
    status_bytes = git(root, "status", "--porcelain=v1", "--untracked-files=all", "--", ".")
    status = status_bytes.decode("utf-8", "replace")
    return {"git_root": str(git_root), "head": head, "files": files,
            "diff_sha256": sha(diff), "diff": diff, "git_status": status,
            "git_status_sha256": sha(status_bytes)}


def source_identity(source):
    return {key: source[key] for key in ("git_root", "head", "files", "diff_sha256", "git_status", "git_status_sha256")}


def copy_snapshot(root, destination, files):
    destination.mkdir(parents=True)
    for relative, expected in files.items():
        source = root / relative
        if any(part.is_symlink() for part in (root, *source.parents, source)) or not source.resolve().is_relative_to(root):
            raise RuntimeError(f"Source path changed or escaped during snapshot: {relative}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if sha_file(source) != expected:
            raise RuntimeError(f"Source changed during snapshot: {relative}")
        with source.open("rb") as original, target.open("wb") as copied:
            shutil.copyfileobj(original, copied, length=1024 * 1024)
        if sha_file(target) != expected:
            raise RuntimeError(f"Source changed during snapshot copy: {relative}")
    result = file_hashes(destination)
    if {key: value for key, value in result.items() if not key.endswith("/")} != files:
        raise RuntimeError("Snapshot content differs from source manifest")
    return result


def choose_probe(snapshot, task_file):
    """Choose a safe readable challenge even when the project has no root README."""
    task_text = task_file.read_text(encoding="utf-8")
    preferred = ("README.md", "AGENTS.md", "CLAUDE.md", "package.json", "pyproject.toml")
    paths = [snapshot / name for name in preferred]
    paths.extend(sorted(snapshot.rglob("*")))
    seen = set()
    for path in paths:
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        relative = path.relative_to(snapshot).as_posix()
        if relative.startswith(".cross-review/") or sensitive_path(relative):
            continue
        try:
            if path.stat().st_size > 2_000_000:
                continue
            content = path.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError):
            continue
        if "\x00" in content:
            continue
        for line in content.splitlines():
            candidate = line.strip()
            if (30 <= len(candidate) <= 160 and not candidate.startswith("#") and
                    candidate not in task_text and
                    not re.search(r"(?i)(api.?key|password|secret|token)\s*[:=]", candidate)):
                return relative
    raise RuntimeError("Snapshot has no safe nonempty text line for PROJECT_READ_PROOF")


def worker(provider, index, args, snapshot, task_file, result_dir, baseline,
           selected_model, selected_effort):
    worker_timeout = args.grok_timeout_seconds if provider == "grok" else args.timeout_seconds
    command = [args.pwsh, "-NoProfile", "-NonInteractive", "-File", str(args.launcher),
               "-Provider", provider, "-TaskRoot", str(snapshot), "-TaskFile", str(task_file),
               "-RunDirectory", str(result_dir), "-ProbeFile", choose_probe(snapshot, task_file),
               "-TimeoutSeconds", str(worker_timeout)]
    if provider == "codex" and args.codex_sandbox:
        command.extend(["-CodexSandbox", args.codex_sandbox])
    if provider == "deepseek":
        command.extend(["-DeepSeekAccess", args.deepseek_access])
    if selected_model:
        command.extend(["-Model", selected_model])
    if selected_effort:
        command.extend([EFFORT_FLAGS[provider], selected_effort])
    try:
        worker_env = os.environ.copy()
        worker_env["PYTHONDONTWRITEBYTECODE"] = "1"
        ceilings = [str(snapshot.parent)]
        if worker_env.get("GIT_CEILING_DIRECTORIES"):
            ceilings.append(worker_env["GIT_CEILING_DIRECTORIES"])
        worker_env["GIT_CEILING_DIRECTORIES"] = os.pathsep.join(ceilings)
        process = run_worker(command, timeout=worker_timeout + 90, env=worker_env)
    except Exception as exc:
        try:
            after = file_hashes(snapshot)
            unchanged = after == baseline
            snapshot_error = None
        except Exception as snapshot_exc:
            after = None
            unchanged = False
            snapshot_error = str(snapshot_exc)
        return {"provider": provider, "index": index, "exit_code": None,
                "delegate_status": None, "snapshot_unchanged": unchanged,
                "snapshot_error": snapshot_error, "snapshot_hashes_after": after,
                "launch_error": str(exc),
                "stdout_tail": "", "stderr_tail": ""}
    status_path = result_dir / "status.json"
    try:
        delegate_status = json.loads(status_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        delegate_status = None
    try:
        after = file_hashes(snapshot)
        unchanged = after == baseline
    except Exception as exc:
        after = None
        unchanged = False
        snapshot_error = str(exc)
    else:
        snapshot_error = None
    return {"provider": provider, "index": index, "exit_code": process.returncode,
            "delegate_status": delegate_status, "snapshot_unchanged": unchanged,
            "snapshot_error": snapshot_error, "snapshot_hashes_after": after,
            "stdout_tail": process.stdout.decode("utf-8", "replace")[-2000:],
            "stderr_tail": process.stderr.decode("utf-8", "replace")[-2000:]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-root", type=Path, required=True)
    parser.add_argument("--task-file", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--provider-a", choices=PROVIDERS, required=True)
    parser.add_argument("--provider-b", choices=PROVIDERS, required=True)
    parser.add_argument("--provider-c", choices=PROVIDERS,
                        help="Optional third independent provider")
    parser.add_argument("--model-a", help="Model ID for provider A; omit for that provider's default")
    parser.add_argument("--model-b", help="Model ID for provider B; omit for that provider's default")
    parser.add_argument("--model-c", help="Model ID for provider C; requires --provider-c")
    parser.add_argument("--effort-a", help="Reasoning effort for provider A; omit for its default")
    parser.add_argument("--effort-b", help="Reasoning effort for provider B; omit for its default")
    parser.add_argument("--effort-c", help="Reasoning effort for provider C; requires --provider-c")
    parser.add_argument("--requested-by-user", action="store_true",
                        help="Required for any live model calls")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--include-path", action="append", default=[],
                        help="Explicitly include a non-sensitive ignored file (repeatable)")
    parser.add_argument("--deepseek-access", choices=("context", "read-tools"), default="context")
    parser.add_argument("--codex-sandbox", choices=("read-only", "workspace-write", "danger-full-access"),
                        help="Optional Codex sandbox; read-only can also block network on Windows")
    parser.add_argument("--timeout-seconds", type=int,
                        help="Worker timeout for all providers; default 900 seconds except Grok")
    parser.add_argument("--grok-timeout-seconds", type=int,
                        help="Override Grok timeout; default 2700 seconds unless --timeout-seconds is explicit")
    parser.add_argument("--launcher", type=Path,
                        default=Path(__file__).with_name("Invoke-Delegate.ps1"))
    parser.add_argument("--pwsh", default="pwsh")
    args = parser.parse_args()
    if args.provider_c is None and (args.model_c is not None or args.effort_c is not None):
        parser.error("--model-c and --effort-c require --provider-c")
    selected = [("a", args.provider_a, args.model_a, args.effort_a),
                ("b", args.provider_b, args.model_b, args.effort_b)]
    if args.provider_c:
        selected.append(("c", args.provider_c, args.model_c, args.effort_c))
    providers = [provider for _, provider, _, _ in selected]
    if len(set(providers)) != len(providers):
        parser.error("Cross review requires distinct provider families")
    for label, provider, model, effort in selected:
        if model is not None and not model.strip():
            parser.error(f"--model-{label} must not be empty")
        if effort is not None and effort not in EFFORTS[provider]:
            parser.error(f"--effort-{label} for {provider} must be one of {', '.join(EFFORTS[provider])}")
    if not args.dry_run and not args.requested_by_user:
        parser.error("Live cross review requires --requested-by-user")
    if args.timeout_seconds is not None and not 30 <= args.timeout_seconds <= 7200:
        parser.error("--timeout-seconds must be 30..7200")
    if args.grok_timeout_seconds is not None and not 30 <= args.grok_timeout_seconds <= 7200:
        parser.error("--grok-timeout-seconds must be 30..7200")
    args.grok_timeout_seconds = (args.grok_timeout_seconds if args.grok_timeout_seconds is not None
                                 else args.timeout_seconds if args.timeout_seconds is not None else 2700)
    args.timeout_seconds = 900 if args.timeout_seconds is None else args.timeout_seconds
    if not args.task_root.is_absolute():
        parser.error("--task-root must be an absolute path")
    root = args.task_root.resolve(strict=True)
    if not root.is_dir():
        parser.error("--task-root must be a directory")
    task_file = args.task_file.resolve(strict=True)
    if not task_file.is_file() or not task_file.read_text(encoding="utf-8").strip():
        parser.error("--task-file must contain a nonempty review task")
    run_dir = args.run_dir.resolve()
    if run_dir.is_relative_to(root) or root.is_relative_to(run_dir):
        parser.error("--run-dir must be outside the source task root")
    if run_dir.exists() and any(run_dir.iterdir()):
        parser.error("--run-dir must be empty")
    if not args.dry_run and not args.launcher.is_file():
        parser.error(f"Launcher not found: {args.launcher}")
    source = get_source(root, args.include_path)
    source_tree_before = source_tree_hashes(root)
    if not source["files"]:
        parser.error("No source files in Git task root")
    required_bytes = sum((root / path).stat().st_size for path in source["files"]) * len(selected) + 100_000_000
    disk_root = run_dir.parent
    while not disk_root.exists():
        parent = disk_root.parent
        if parent == disk_root:
            parser.error(f"Cannot find an existing parent drive or folder for --run-dir: {run_dir}")
        disk_root = parent
    if shutil.disk_usage(disk_root).free < required_bytes:
        parser.error(f"Insufficient free space for {len(selected)} snapshots")
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "frozen-diff.patch").write_bytes(source["diff"])
    manifest = source_identity(source)
    manifest["source_task_root"] = str(root)
    manifest["snapshot_id"] = sha(json.dumps(manifest, sort_keys=True, ensure_ascii=False).encode("utf-8"))
    save_json(run_dir / "snapshot-manifest.json", manifest)
    snapshots = []
    for index, (_, provider, _, _) in enumerate(selected, 1):
        folder = run_dir / f"snapshot-{index}-{provider}"
        baseline = copy_snapshot(root, folder, source["files"])
        review_dir = folder / ".cross-review"
        if review_dir.exists():
            raise RuntimeError("Source already contains reserved .cross-review path")
        review_dir.mkdir()
        (review_dir / "frozen-diff.patch").write_bytes(source["diff"])
        baseline = file_hashes(folder)
        snapshots.append((folder, baseline))
    if any(baseline != snapshots[0][1] for _, baseline in snapshots[1:]):
        raise RuntimeError("Provider snapshots differ")
    if source_identity(get_source(root, args.include_path)) != source_identity(source):
        raise RuntimeError("Original Git worktree changed during freeze; no providers called")
    if source_tree_hashes(root) != source_tree_before:
        raise RuntimeError("Original source files changed during freeze; no providers called")
    git_prefix = root.relative_to(Path(source["git_root"])).as_posix()
    display_prefix = "(repository root)" if git_prefix == "." else git_prefix
    review_instruction = (
        "This is an explicit, read-only cross review. Examine the frozen project snapshot. "
        "Do not edit files. State concrete findings with file and line references; "
        "separate verified facts from inference. Review the same task independently.\n\n"
        f"Original Git HEAD: {source['head']}\n"
        f"Snapshot ID: {manifest['snapshot_id']}\n"
        f"Original diff SHA256: {source['diff_sha256']}\n"
        "Inspect .cross-review/frozen-diff.patch inside this snapshot. In context mode, "
        "use its supplied FILE block; otherwise read it from the snapshot. It is the complete "
        "original tracked diff, including staged and unstaged changes. The snapshot also "
        "contains untracked, nonignored files. Frozen diff and snapshot paths are both "
        f"relative to the selected task root. "
        f"The selected task root within the Git tree is {display_prefix}.\n\n"
        "USER REVIEW TASK:\n" + task_file.read_text(encoding="utf-8")
    )
    for folder, _ in snapshots:
        (folder.parent / f"{folder.name}-task.txt").write_text(review_instruction, encoding="utf-8")
    result = {"schema_version": 1, "kind": "explicit_cross_review", "started_at": datetime.now(timezone.utc).isoformat(),
              "requested_by_user": args.requested_by_user, "dry_run": args.dry_run,
              "snapshot_id": manifest["snapshot_id"], "original_head": source["head"],
              "original_diff_sha256": source["diff_sha256"], "providers": providers,
              "provider_count": len(providers),
              "requested_models": [model for _, _, model, _ in selected],
              "requested_efforts": [effort for _, _, _, effort in selected],
              "timeout_seconds": args.timeout_seconds,
              "grok_timeout_seconds": args.grok_timeout_seconds,
              "snapshot_equal": True, "result_claims_verified": False, "workers": [],
              "source_unchanged_after_workers": None, "source_changed_paths": [],
              "source_integrity_error": None}
    if not args.dry_run:
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(selected)) as pool:
            futures = []
            for i, (_, provider, model, effort) in enumerate(selected, 1):
                folder, baseline = snapshots[i - 1]
                futures.append(pool.submit(worker, provider, i, args, folder,
                                           folder.parent / f"{folder.name}-task.txt",
                                           run_dir / f"worker-{i}-{provider}", baseline,
                                           model, effort))
            for index, future in enumerate(futures, 1):
                try:
                    result["workers"].append(future.result())
                except Exception as exc:
                    result["workers"].append({"provider": providers[index - 1],
                                              "index": index, "exit_code": None,
                                              "launch_error": str(exc), "snapshot_unchanged": False,
                                              "delegate_status": None})
    try:
        source_tree_after = source_tree_hashes(root)
        result["source_changed_paths"] = sorted(path for path in source_tree_before.keys() | source_tree_after.keys()
                                                if source_tree_before.get(path) != source_tree_after.get(path))[:200]
        result["source_unchanged_after_workers"] = (not result["source_changed_paths"] and
                                                     source_identity(get_source(root, args.include_path)) == source_identity(source))
    except Exception as exc:
        result["source_unchanged_after_workers"] = False
        result["source_integrity_error"] = str(exc)
    result["finished_at"] = datetime.now(timezone.utc).isoformat()
    result["status"] = "prepared" if args.dry_run else (
        "review_responses_ready_for_independent_audit" if result["source_unchanged_after_workers"] and all(
            w["exit_code"] == 0 and w["snapshot_unchanged"] and
            w["delegate_status"] and w["delegate_status"].get("status", "").startswith("verified_") and
            w["delegate_status"].get("read_proof_kind") in ("challenge_exact", "context_supplied") and
            w["delegate_status"].get("outcome") == "valid_report"
            for w in result["workers"]) else "review_incomplete")
    save_json(run_dir / "cross-review-status.json", result)
    print(json.dumps({key: result[key] for key in ("status", "snapshot_id", "providers", "snapshot_equal", "source_unchanged_after_workers", "result_claims_verified")}, ensure_ascii=False))
    return 0 if result["status"] != "review_incomplete" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Cross review failed: {error}", file=sys.stderr)
        sys.exit(2)
