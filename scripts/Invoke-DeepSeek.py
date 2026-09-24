#!/usr/bin/env python3
"""DeepSeek API worker for Invoke-Delegate.ps1. No persistent credential storage."""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from sensitive_paths import sensitive_path

API_URL = "https://api.deepseek.com/chat/completions"
SKIP_DIRS = {".git"}
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip",
                   ".gz", ".7z", ".exe", ".dll", ".so", ".dylib", ".woff", ".woff2",
                    ".ttf", ".otf", ".mp3", ".mp4", ".mov", ".wav", ".pyc"}
GENERATED_BULK_NAMES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml",
                        "cargo.lock", "poetry.lock", "uv.lock"}


def physical_lines(content: str) -> list[str]:
    """Count CR, LF and CRLF as line breaks, like .NET ReadAllLines."""
    if not content:
        return []
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n")
    if normalized.endswith("\n"):
        lines.pop()
    return lines


def proof_header_matches(text: str, expected_path: str, expected_line: str) -> bool:
    first_line = text.splitlines()[0] if text else ""
    reported = re.match(r"^PROJECT_READ_PROOF\|([^|\r\n]+)\|(\d+)\|", first_line)
    return bool(reported and reported.group(1).replace("\\", "/") == expected_path.replace("\\", "/")
                and reported.group(2) == expected_line)


def within(root: Path, raw: str) -> Path:
    path = (root / raw).resolve()
    if not path.is_relative_to(root):
        raise ValueError("Path is outside taskRoot")
    return path


def is_git_ignored(root: Path, relative: str) -> bool:
    try:
        result = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--", relative],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return False
    return result.returncode == 0


def git_visible_paths(root: Path) -> set[str] | None:
    try:
        result = subprocess.run(["git", "-C", str(root), "ls-files", "--cached", "--others",
                                 "--exclude-standard", "-z", "--", "."],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return None
    if result.returncode:
        return None
    paths = {os.fsdecode(raw).replace("\\", "/") for raw in result.stdout.split(b"\0") if raw}
    return {path.casefold() for path in paths} if os.name == "nt" else paths


def git_marker_present(root: Path) -> bool:
    ceilings = {Path(value).resolve() for value in os.environ.get("GIT_CEILING_DIRECTORIES", "").split(os.pathsep)
                if value}
    for directory in (root, *root.parents):
        if directory in ceilings:
            break
        if (directory / ".git").exists():
            return True
    return False


def visible_file(root: Path, relative: str, include_sensitive: bool,
                 include_ignored: bool, git_visible: set[str] | None = None) -> bool:
    normalized = relative.replace("\\", "/")
    if os.name == "nt":
        normalized = normalized.casefold()
    if not include_ignored and git_visible is None and git_marker_present(root):
        git_visible = git_visible_paths(root)
        if git_visible is None:
            raise ValueError("Git file listing failed; refusing to read ignored files")
    return ((include_sensitive or not sensitive_path(relative)) and
            (include_ignored or (normalized in git_visible if git_visible is not None
                                 else not is_git_ignored(root, relative))))


def files_under(root: Path, subdir: str = ".", limit: int = 500, offset: int = 0,
                include_sensitive: bool = False, include_ignored: bool = False) -> dict:
    base = within(root, subdir)
    if not base.is_dir():
        raise ValueError("Directory does not exist")
    if sensitive_path(str(base.relative_to(root))) and not include_sensitive:
        raise ValueError("Sensitive directory is excluded")
    start = int(offset)
    count = int(limit)
    if start < 0 or count < 1 or count > 5000:
        raise ValueError("offset must be nonnegative and limit must be 1..5000")
    names = []
    truncated = False
    visited = 0
    git_visible = None if include_ignored else git_visible_paths(root)
    if not include_ignored and git_visible is None and git_marker_present(root):
        raise ValueError("Git file listing failed; refusing to list ignored files")
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and
                         (include_sensitive or not sensitive_path(str((Path(directory) / d).relative_to(root)))))
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink():
                continue
            if not visible_file(root, str(path.relative_to(root)), include_sensitive,
                                include_ignored or git_visible is None, git_visible):
                continue
            if visited < start:
                visited += 1
                continue
            if len(names) >= count:
                truncated = True
                break
            names.append(str(path.relative_to(root)).replace("\\", "/"))
            visited += 1
        if truncated:
            break
    return {"files": names, "truncated": truncated, "next_offset": start + len(names) if truncated else None}


def read_file(root: Path, path: str, start_line: int = 1, max_lines: int = 250,
              include_sensitive: bool = False, include_ignored: bool = False) -> dict:
    target = within(root, path)
    relative = str(target.relative_to(root))
    if not visible_file(root, relative, include_sensitive, include_ignored):
        raise ValueError("Sensitive or Git-ignored file is excluded")
    if not target.is_file():
        raise ValueError("File does not exist")
    if target.stat().st_size > 2_000_000:
        raise ValueError("File exceeds 2 MB; request a smaller source file")
    data = target.read_bytes()
    if b"\x00" in data:
        raise ValueError("Binary file")
    lines = physical_lines(data.decode("utf-8-sig"))
    start = max(1, int(start_line))
    count = min(max(1, int(max_lines)), 300)
    part = lines[start - 1:start - 1 + count]
    content = "\n".join(f"{i}: {line}" for i, line in enumerate(part, start))
    if len(content) > 35_000:
        content = content[:35_000] + "\n[truncated]"
    return {"path": str(target.relative_to(root)).replace("\\", "/"), "total_lines": len(lines), "content": content}


def search_text(root: Path, query: str, subdir: str = ".", limit: int = 60, offset: int = 0,
                 include_sensitive: bool = False, include_ignored: bool = False) -> dict:
    if not query or len(query) > 200:
        raise ValueError("Query length must be 1..200")
    start = int(offset)
    if start < 0:
        raise ValueError("offset must be nonnegative")
    count = min(max(1, int(limit)), 100)
    found = []
    seen = 0
    file_offset = 0
    while True:
        listing = files_under(root, subdir, 3000, offset=file_offset,
                              include_sensitive=include_sensitive, include_ignored=include_ignored)
        for relative in listing["files"]:
            path = within(root, relative)
            if path.stat().st_size > 1_000_000:
                continue
            try:
                lines = physical_lines(path.read_text(encoding="utf-8-sig"))
            except (UnicodeError, OSError):
                continue
            for index, line in enumerate(lines, 1):
                if query.casefold() not in line.casefold():
                    continue
                seen += 1
                if seen <= start:
                    continue
                if len(found) == count:
                    return {"matches": found, "truncated": True,
                            "next_offset": start + count}
                found.append({"path": relative, "line": index, "text": line[:300]})
        if not listing["truncated"]:
            return {"matches": found, "truncated": False, "next_offset": None}
        file_offset = listing["next_offset"]


TOOLS = [
    {"type": "function", "function": {"name": "list_files", "description": "List project files under a directory relative to taskRoot. If truncated is true, call again with next_offset to see later files.", "parameters": {"type": "object", "properties": {"subdir": {"type": "string"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}}, "required": []}}},
    {"type": "function", "function": {"name": "read_file", "description": "Read a project source file with line numbers; paths are relative to taskRoot.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "start_line": {"type": "integer"}, "max_lines": {"type": "integer"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "search_text", "description": "Search literal text in project files and return matching paths and lines. Offset counts prior matches; continue with next_offset when it is present.", "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "subdir": {"type": "string"}, "offset": {"type": "integer"}}, "required": ["query"]}}},
]


def add_usage(total: dict, current: dict | None) -> None:
    """Account for every API turn, including tool and proof-repair turns."""
    if not isinstance(current, dict):
        return
    for name, value in current.items():
        if isinstance(value, dict):
            nested = total.setdefault(name, {})
            if isinstance(nested, dict):
                add_usage(nested, value)
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            total[name] = total.get(name, 0) + value


def call_api(key: str, payload: dict, timeout: int = 150) -> dict:
    request = urllib.request.Request(
        API_URL,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read(2000).decode("utf-8", errors="replace")
        raise RuntimeError(f"DeepSeek HTTP {error.code}: {body}") from None


def context_pack(root: Path, max_chars: int = 180_000,
                 include_sensitive: bool = False, include_ignored: bool = False,
                 skipped: list | None = None) -> tuple[str, list[str], bool]:
    listing = files_under(root, ".", 5000, include_sensitive=include_sensitive,
                          include_ignored=include_ignored)
    git_visible = git_visible_paths(root) if not include_ignored else None
    binary_files = [p for p in listing["files"] if Path(p).suffix.casefold() in BINARY_SUFFIXES]
    newly_detected_nontext = []
    bulk_files = [p for p in listing["files"] if Path(p).name.casefold() in GENERATED_BULK_NAMES]
    active = [
        p for p in listing["files"]
        if ".bak-" not in Path(p).name.lower() and
        Path(p).suffix.casefold() not in BINARY_SUFFIXES and
        Path(p).name.casefold() not in GENERATED_BULK_NAMES
    ]
    order = sorted(active, key=lambda p: (0 if Path(p).name.lower() in {"agents.md", "claude.md", "readme.md"} else 1, p))
    parts = ["PROJECT FILE INDEX (taskRoot relative):\n" + "\n".join(order)]
    if binary_files:
        parts.append("BINARY FILES EXCLUDED FROM TEXT CONTEXT:\n" + "\n".join(binary_files))
        if skipped is not None:
            skipped.extend({"path": path, "reason": "binary_nontext"} for path in binary_files)
    if bulk_files:
        parts.append("GENERATED BULK FILES EXCLUDED FROM TEXT CONTEXT:\n" + "\n".join(bulk_files))
        if skipped is not None:
            skipped.extend({"path": path, "reason": "generated_bulk"} for path in bulk_files)
    included = []
    size = sum(len(part) for part in parts)
    omitted = listing["truncated"] or size > max_chars
    if size > max_chars and skipped is not None:
        skipped.append({"path": "<file index>", "reason": "file_index_limit"})
    if (root / ".git").exists() and git_visible is None and not include_ignored:
        omitted = True
        if skipped is not None:
            skipped.append({"path": "<Git index>", "reason": "git_listing_failed"})
    if listing["truncated"] and skipped is not None:
        skipped.append({"path": "<file listing>", "reason": "file_list_limit"})
    for relative in order:
        path = within(root, relative)
        try:
            with path.open("rb") as source:
                data = source.read(60_001)
            if not data and relative.replace("\\", "/") != ".cross-review/frozen-diff.patch":
                continue
            if len(data) > 60_000:
                omitted = True
                if skipped is not None:
                    skipped.append({"path": relative, "reason": "over_60kb"})
                continue
            content = data.decode("utf-8-sig") if data else "[empty file: no tracked diff]"
        except UnicodeError:
            newly_detected_nontext.append(relative)
            if skipped is not None:
                skipped.append({"path": relative, "reason": "binary_nontext"})
            continue
        except OSError:
            omitted = True
            if skipped is not None:
                skipped.append({"path": relative, "reason": "unreadable_file"})
            continue
        if "\x00" in content:
            newly_detected_nontext.append(relative)
            if skipped is not None:
                skipped.append({"path": relative, "reason": "binary_nontext"})
            continue
        block = f"\n--- FILE {relative} ---\n" + "\n".join(f"{i}: {line}" for i, line in enumerate(physical_lines(content), 1))
        if size + len(block) > max_chars:
            omitted = True
            if skipped is not None:
                skipped.append({"path": relative, "reason": "package_limit"})
            continue
        parts.append(block)
        included.append(relative)
        size += len(block)
    if newly_detected_nontext:
        parts.append("ADDITIONAL NON-UTF8/BINARY FILES EXCLUDED FROM TEXT CONTEXT:\n"
                     + "\n".join(sorted(set(newly_detected_nontext))))
    scope = "CONTEXT_SCOPE=readable_utf8_text_except_generated_bulk"
    bundle = "\n".join(parts + [scope, "CONTEXT_COMPLETE=" + str(not omitted).lower()])
    if len(bundle) > max_chars:
        omitted = True
        if skipped is not None:
            skipped.append({"path": "<context package>", "reason": "package_limit"})
        ending = "\n[context package truncated]\n" + scope + "\nCONTEXT_COMPLETE=false"
        bundle = bundle[:max(0, max_chars - len(ending))] + ending
        bundle = bundle[:max_chars]
    return bundle, included, omitted


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-root", required=True)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--result-file", required=True)
    parser.add_argument("--model", default="deepseek-v4-pro")
    parser.add_argument("--access", choices=("read-tools", "context"), default="context")
    parser.add_argument("--reasoning-effort", choices=("none", "low", "high", "max"), default="high")
    parser.add_argument("--http-timeout", type=int, default=900)
    parser.add_argument("--probe-file", required=True)
    parser.add_argument("--include-sensitive", action="store_true")
    parser.add_argument("--include-ignored", action="store_true")
    args = parser.parse_args()
    if args.http_timeout < 30:
        parser.error("--http-timeout must be at least 30 seconds")
    deadline = time.monotonic() + args.http_timeout
    key = os.environ.get("DEEPSEEK_API_KEY", "")
    if not key:
        raise RuntimeError("DEEPSEEK_API_KEY environment variable is missing")
    root = Path(args.task_root).resolve()
    prompt = Path(args.prompt_file).read_text(encoding="utf-8-sig")
    probe_path = str(within(root, args.probe_file).relative_to(root)).replace("\\", "/")
    if not visible_file(root, probe_path, args.include_sensitive, args.include_ignored):
        raise ValueError("Probe file is sensitive or Git-ignored; select a different probe")
    proof_request = re.search(r"PROJECT_READ_PROOF\|([^|\r\n]+)\|(\d+)\|<", prompt)
    proof_prefix = (
        f"PROJECT_READ_PROOF|{proof_request.group(1)}|{proof_request.group(2)}|"
        if proof_request else None
    )
    read_paths = []
    omitted = False
    skipped = []
    if args.access == "context":
        bundle, read_paths, omitted = context_pack(root, include_sensitive=args.include_sensitive,
                                                  include_ignored=args.include_ignored, skipped=skipped)
        if probe_path not in read_paths:
            omitted = True
            skipped.append({"path": probe_path, "reason": "probe_not_in_context"})
        if omitted:
            output = {"text": "", "model": None, "usage": {}, "finish_reason": None,
                      "read_paths": read_paths, "access": args.access, "tool_calls": 0,
                      "request_count": 0, "context_incomplete": True, "skipped_files": skipped}
            Path(args.result_file).write_text(json.dumps(output, ensure_ascii=False), encoding="utf-8")
            return 3
        prompt += "\n\n" + bundle
    messages = [
        {"role": "system", "content": (
            "Work only within the provided taskRoot. Read actual project files before architectural claims. "
            "Report uncertainty. Do not claim to have edited files unless you did. "
            + (f"You must call read_file for {probe_path} before answering. "
               "Your final answer must start with the exact PROJECT_READ_PROOF line requested by the user, "
               "with the file's real line text and no Markdown prefix." if args.access == "read-tools" else "")
        )},
        {"role": "user", "content": prompt},
    ]
    last_model = None
    usage = {}
    finish_reason = None
    final = ""
    tool_calls_count = 0
    request_count = 0
    proof_retries = 0
    tool_rounds = 0
    while True:
        force_final = args.access == "read-tools" and tool_rounds >= 16
        if force_final:
            messages.append({"role": "user", "content": (
                "Tool budget reached. Finish now from the files already read. "
                "Include the exact PROJECT_READ_PROOF first line and the result JSON contract. "
                "Report any remaining uncertainty; do not request another tool.")})
        payload = {"model": args.model, "messages": messages,
                   "reasoning_effort": args.reasoning_effort,
                   "stream": False}
        if args.access == "read-tools":
            payload["tools"] = TOOLS
            payload["tool_choice"] = "none" if force_final else "auto"
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            finish_reason = "http_time_budget_exhausted"
            break
        response = call_api(key, payload, timeout=max(1, remaining))
        request_count += 1
        last_model = response.get("model")
        add_usage(usage, response.get("usage"))
        choice = response["choices"][0]
        finish_reason = choice.get("finish_reason")
        message = choice["message"]
        calls = message.get("tool_calls") or []
        if not calls:
            final = message.get("content") or ""
            if args.access == "read-tools" and proof_retries < 2 and not force_final:
                has_read_probe = probe_path in read_paths
                has_proof = bool(proof_request and proof_header_matches(
                    final, proof_request.group(1), proof_request.group(2)))
                if not has_read_probe or not has_proof:
                    messages.append(message)
                    if not has_read_probe:
                        correction = f"Before answering, call read_file for {probe_path}. Then give the full answer."
                    else:
                        correction = (
                            "Your answer omitted the required first line. Give the full corrected answer, "
                            f"starting exactly with {proof_prefix}<the file's exact line text>. "
                            "Do not put it in a code block or add a Markdown prefix."
                        )
                    messages.append({"role": "user", "content": correction})
                    proof_retries += 1
                    continue
            break
        if args.access != "read-tools":
            raise RuntimeError("Unexpected tool call in context mode")
        if force_final:
            finish_reason = "tool_turn_limit"
            break
        tool_rounds += 1
        messages.append(message)
        for call in calls:
            name = call.get("function", {}).get("name")
            try:
                options = json.loads(call["function"].get("arguments") or "{}")
                if not isinstance(options, dict):
                    raise ValueError("Tool arguments must be an object")
                if name == "list_files":
                    result = files_under(root, options.get("subdir", "."), min(int(options.get("limit", 500)), 500), options.get("offset", 0), args.include_sensitive, args.include_ignored)
                elif name == "read_file":
                    result = read_file(root, options["path"], options.get("start_line", 1), options.get("max_lines", 250), args.include_sensitive, args.include_ignored)
                    read_paths.append(result["path"])
                elif name == "search_text":
                    result = search_text(root, options["query"], options.get("subdir", "."),
                                         offset=options.get("offset", 0),
                                         include_sensitive=args.include_sensitive,
                                         include_ignored=args.include_ignored)
                else:
                    raise ValueError("Unknown tool")
                tool_calls_count += 1
            except (ValueError, KeyError, OSError, TypeError) as error:
                result = {"error": str(error)}
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": json.dumps(result, ensure_ascii=False)})
    output = {"text": final, "model": last_model, "usage": usage, "finish_reason": finish_reason,
              "read_paths": read_paths, "access": args.access, "tool_calls": tool_calls_count,
              "request_count": request_count, "context_incomplete": omitted, "skipped_files": skipped}
    Path(args.result_file).write_text(json.dumps(output, ensure_ascii=False), encoding="utf-8")
    return 0 if final.strip() and finish_reason not in {"length", "tool_turn_limit", "http_time_budget_exhausted"} else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
