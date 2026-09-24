"""Run two or three different delegated tasks concurrently in one project root."""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


PROVIDERS = {"codex", "grok", "agy", "deepseek"}
EFFORT_FLAGS = {
    "codex": "-CodexReasoningEffort",
    "grok": "-GrokReasoningEffort",
    "agy": "-AgyReasoningEffort",
    "deepseek": "-DeepSeekReasoningEffort",
}


def inside(path: Path, root: Path) -> bool:
    return path == root or path.is_relative_to(root)


def file_state(path: Path) -> str:
    if path.is_symlink():
        return "LINK:" + os.readlink(path)
    if path.is_dir():
        return "DIRECTORY"
    if not path.is_file():
        return "ABSENT"
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_snapshot(root: Path) -> tuple[str, dict[str, tuple[str, str]]]:
    """Record Git-visible files and index states, or all files outside Git."""
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others",
         "--exclude-standard", "-z", "--", "."],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    if listing.returncode == 0:
        index = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--stage", "-z", "--", "."],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        if index.returncode:
            raise RuntimeError("Git index state could not be read")
        index_states = {}
        for raw in index.stdout.split(b"\0"):
            if not raw:
                continue
            metadata, separator, name = raw.partition(b"\t")
            if not separator:
                raise RuntimeError("Invalid Git index entry")
            relative = os.fsdecode(name).replace("\\", "/")
            index_states[relative] = os.fsdecode(metadata)
        paths = {os.fsdecode(raw).replace("\\", "/")
                 for raw in listing.stdout.split(b"\0") if raw}
        return "git_visible_only", {
            relative: (file_state(root / relative), index_states.get(relative, "UNTRACKED"))
            for relative in paths
        }
    states = {}
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(name for name in dirs if name != ".git")
        for name in sorted(files):
            path = Path(directory) / name
            states[path.relative_to(root).as_posix()] = (file_state(path), "NON_GIT")
    return "all_files_non_git", states


def path_key(path: str) -> str:
    normalized = path.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized.casefold() if os.name == "nt" else normalized


def prepare_workers(plan_path: Path, root: Path, run_dir: Path) -> list[dict]:
    plan = json.loads(plan_path.read_text(encoding="utf-8-sig"))
    workers = plan.get("workers") if isinstance(plan, dict) else None
    if not isinstance(workers, list) or not 2 <= len(workers) <= 3:
        raise ValueError("Plan must contain two or three workers")
    seen_ids = set()
    seen_tasks = set()
    prepared = []
    for index, worker in enumerate(workers, 1):
        if not isinstance(worker, dict):
            raise ValueError(f"Worker {index} must be an object")
        worker_id = worker.get("id")
        provider = worker.get("provider")
        if not isinstance(worker_id, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,39}", worker_id):
            raise ValueError(f"Worker {index} has an invalid id")
        if worker_id in seen_ids:
            raise ValueError(f"Duplicate worker id: {worker_id}")
        if provider not in PROVIDERS:
            raise ValueError(f"Worker {worker_id} has an invalid provider")
        task_raw = worker.get("task_file")
        if not isinstance(task_raw, str) or not Path(task_raw).is_absolute():
            raise ValueError(f"Worker {worker_id} task_file must be absolute")
        task_file = Path(task_raw).resolve(strict=True)
        if not task_file.is_file() or not task_file.read_text(encoding="utf-8-sig").strip():
            raise ValueError(f"Worker {worker_id} task_file is empty or missing")
        if task_file in seen_tasks:
            raise ValueError("Each worker must have its own task_file")
        seen_ids.add(worker_id)
        seen_tasks.add(task_file)
        for optional in ("model", "effort", "probe_file", "deepseek_access", "codex_sandbox"):
            if optional in worker and (not isinstance(worker[optional], str) or not worker[optional].strip()):
                raise ValueError(f"Worker {worker_id} {optional} must be nonempty text")
        timeout = worker.get("timeout_seconds")
        if timeout is not None and (type(timeout) is not int or not 30 <= timeout <= 7200):
            raise ValueError(f"Worker {worker_id} timeout_seconds must be 30..7200")
        if worker.get("deepseek_access") and provider != "deepseek":
            raise ValueError(f"Worker {worker_id} deepseek_access requires deepseek")
        if worker.get("codex_sandbox") and provider != "codex":
            raise ValueError(f"Worker {worker_id} codex_sandbox requires codex")
        prepared.append({**worker, "task_file": str(task_file),
                         "run_dir": str(run_dir / f"worker-{index}-{worker_id}")})
    return prepared


def run_worker(worker: dict, root: Path, launcher: Path, dry_run: bool) -> dict:
    provider = worker["provider"]
    command = ["pwsh", "-NoProfile", "-File", str(launcher),
               "-Provider", provider, "-TaskRoot", str(root),
               "-TaskFile", worker["task_file"], "-RunDirectory", worker["run_dir"]]
    for key, flag in (("model", "-Model"), ("probe_file", "-ProbeFile"),
                      ("timeout_seconds", "-TimeoutSeconds"),
                      ("deepseek_access", "-DeepSeekAccess"),
                      ("codex_sandbox", "-CodexSandbox")):
        if key in worker:
            command.extend((flag, str(worker[key])))
    if "effort" in worker:
        command.extend((EFFORT_FLAGS[provider], worker["effort"]))
    if dry_run:
        command.append("-DryRun")
    command.append("-SharedRootParallel")
    timeout = worker.get("timeout_seconds", 2700 if provider == "grok" else 900)
    process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               encoding="utf-8", errors="replace")
    try:
        stdout, stderr = process.communicate(timeout=timeout + 90)
        exit_code = process.returncode
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        else:
            process.kill()
        stdout, stderr = process.communicate()
        exit_code = 124
    status_path = Path(worker["run_dir"]) / "status.json"
    try:
        status = json.loads(status_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        status = {}
    contract = status.get("result_contract") or {}
    return {"id": worker["id"], "provider": provider, "task_file": worker["task_file"],
            "run_directory": worker["run_dir"], "launcher_exit_code": exit_code,
            "status": status.get("status", "missing_status"),
            "outcome": status.get("outcome", "missing_status"),
            "observed_model": status.get("observed_model"),
            "final_available": status.get("final_available", False),
            "reported_changed_files": contract.get("reported_changed_files", []),
            "changed_files_check": contract.get("changed_files_check"),
            "status_file": str(status_path), "launcher_error": stderr[-1000:] if exit_code else ""}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-root", type=Path, required=True)
    parser.add_argument("--plan-file", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--requested-by-user", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.dry_run and not args.requested_by_user:
        parser.error("Live parallel delegation requires --requested-by-user")
    if not args.task_root.is_absolute() or not args.run_dir.is_absolute():
        parser.error("task-root and run-dir must be absolute paths")
    root = args.task_root.resolve(strict=True)
    run_dir = args.run_dir.resolve()
    if not root.is_dir() or inside(run_dir, root):
        parser.error("run-dir must be outside the project root")
    if run_dir.exists() and any(run_dir.iterdir()):
        parser.error("run-dir must be empty")
    plan_path = args.plan_file.resolve(strict=True)
    workers = prepare_workers(plan_path, root, run_dir)
    launcher = Path(__file__).with_name("Invoke-Delegate.ps1")
    if not launcher.is_file():
        raise FileNotFoundError(f"Missing launcher: {launcher}")
    before_scope, before = ("not_run_dry_run", {}) if args.dry_run else source_snapshot(root)
    run_dir.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(workers)) as pool:
        futures = [pool.submit(run_worker, worker, root, launcher, args.dry_run)
                   for worker in workers]
        results = []
        for worker, future in zip(workers, futures):
            try:
                results.append(future.result())
            except Exception as error:
                results.append({"id": worker["id"], "provider": worker["provider"],
                                "outcome": "launch_error", "error": str(error)})
    expected = "launch_prepared" if args.dry_run else "pending_parallel_group_check"
    group_check = {"state": "not_run_dry_run", "scope": before_scope}
    if not args.dry_run:
        try:
            after_scope, after = source_snapshot(root)
            observed = {path_key(path): path for path in before.keys() | after.keys()
                        if before.get(path) != after.get(path)}
            claims = {}
            duplicate = set()
            for result in results:
                for path in result.get("reported_changed_files", []):
                    key = path_key(path)
                    if key in claims:
                        duplicate.add(path)
                    claims[key] = path
            unclaimed = sorted(observed[key] for key in observed.keys() - claims.keys())
            unchanged_claims = sorted(claims[key] for key in claims.keys() - observed.keys())
            match = (before_scope == after_scope and not unclaimed and
                     not unchanged_claims and not duplicate)
            group_check = {"state": "matched" if match else "mismatch",
                           "scope": before_scope, "observed_changed_files": sorted(observed.values()),
                           "unclaimed_changed_files": unclaimed,
                           "claimed_unchanged_files": unchanged_claims,
                           "duplicate_claims": sorted(duplicate),
                           "individual_attribution_verified": False}
        except Exception as error:
            group_check = {"state": "failed", "scope": before_scope, "error": str(error)}
    summary = {"mode": "parallel_distinct_tasks", "task_root": str(root),
               "shared_project_root": True, "snapshots_created": False,
               "workers": results, "group_changed_files_check": group_check,
               "all_ready": group_check["state"] in {"matched", "not_run_dry_run"} and all(
                   result.get("outcome") == expected and result.get("launcher_exit_code") == 0
                   for result in results)}
    status_path = run_dir / "parallel-status.json"
    status_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(str(status_path))
    return 0 if summary["all_ready"] else 2


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
