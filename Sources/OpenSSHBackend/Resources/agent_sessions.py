import argparse
import datetime
import json
import math
import os
import pathlib
import shutil
import stat
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--history", action="store_true")
parser.add_argument("--tool", choices=("claude", "codex", "pi"))
parser.add_argument("--verify")
options = parser.parse_args()
home = pathlib.Path.home()
deadline = time.monotonic() + 60
notices = set()
records = {}
truncated = False
line_limit = 2 * 1024 * 1024
roots = {
    "claude": pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude"))) / "projects",
    "codex": pathlib.Path(os.environ.get("CODEX_HOME", str(home / ".codex"))) / "sessions",
    "pi": pathlib.Path(os.environ.get("PI_CODING_AGENT_SESSION_DIR", str(pathlib.Path(os.environ.get("PI_CODING_AGENT_DIR", str(home / ".pi/agent"))) / "sessions")))
}
roots = {tool: root.expanduser().absolute() for tool, root in roots.items()}


def valid_path(value):
    return isinstance(value, str) and value.startswith("/") and len(value) <= 8192 and not any(ord(char) < 32 or ord(char) == 127 for char in value)


def valid_id(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)).lower() == value.lower()
    except (ValueError, TypeError, AttributeError):
        return False


def timestamp(value):
    try:
        if isinstance(value, (float, int)) and not isinstance(value, bool):
            stamp = value / 1000 if value > 100000000000 else value
        elif isinstance(value, str):
            parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            stamp = parsed.replace(tzinfo=datetime.timezone.utc).timestamp() if parsed.tzinfo is None else parsed.timestamp()
        else:
            return 0
        return stamp if math.isfinite(stamp) and stamp >= 0 else 0
    except (ValueError, OverflowError, OSError):
        return 0


def title(value):
    if not isinstance(value, str):
        return ""
    return " ".join("".join(char for char in value if ord(char) >= 32 and ord(char) != 127).split())[:300]


def rows(file, tool):
    global truncated
    try:
        descriptor = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                notices.add(tool + ":unsupported-file")
                return
            while True:
                if time.monotonic() > deadline:
                    truncated = True
                    return
                line = stream.readline(line_limit + 1)
                if not line:
                    break
                if len(line) > line_limit:
                    notices.add(tool + ":oversized-record")
                    while line and not line.endswith(b"\n"):
                        if time.monotonic() > deadline:
                            truncated = True
                            return
                        line = stream.readline(line_limit + 1)
                    continue
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        yield value
                except (ValueError, UnicodeError, RecursionError):
                    notices.add(tool + ":malformed-record")
    except OSError:
        notices.add(tool + ":unreadable")


def files(root, tool):
    global truncated
    try:
        if not root.exists():
            notices.add(tool + ":root-missing")
            return
        if root.is_symlink():
            notices.add(tool + ":linked-root")
            return
    except OSError:
        notices.add(tool + ":unreadable")
        return
    def unreadable(error):
        notices.add(tool + ":unreadable-directory")
    for directory, folders, names in os.walk(root, followlinks=False, onerror=unreadable):
        if time.monotonic() > deadline:
            truncated = True
            return
        folders[:] = sorted((name for name in folders if name not in ("subagents", "tasks") and not pathlib.Path(directory, name).is_symlink()), reverse=True)
        for name in sorted(names, reverse=True):
            if time.monotonic() > deadline:
                truncated = True
                return
            if name.endswith(".jsonl"):
                yield pathlib.Path(directory, name)
            elif name.endswith((".jsonl.zst", ".jsonl.gz")):
                notices.add(tool + ":compressed-format-unavailable")


def session_index(tool):
    index = {}
    if tool == "codex":
        file = roots[tool].parent / "session_index.jsonl"
        if file.exists():
            for row in rows(file, tool):
                identifier = row.get("id")
                if valid_id(identifier):
                    index[identifier] = dict(title=title(row.get("thread_name")), updated=timestamp(row.get("updated_at")))
    return index


def metadata(file, tool, index=None, verify=False):
    try:
        info = file.lstat()
        if not stat.S_ISREG(info.st_mode):
            notices.add(tool + ":unsupported-file")
            return None
    except OSError:
        notices.add(tool + ":unreadable")
        return None
    identifier = None
    directory = None
    named = ""
    summary = ""
    last_active = 0
    activity_source = "session"
    count = 0
    for value in rows(file, tool):
        count += 1
        kind = value.get("type")
        if tool == "claude" and value.get("isSidechain") is True:
            return None
        stamp = timestamp(value.get("timestamp"))
        if tool == "pi" and kind == "message" and isinstance(value.get("message"), dict):
            stamp = max(stamp, timestamp(value["message"].get("timestamp")))
        last_active = max(last_active, stamp)
        payload = value.get("payload") if tool == "codex" and kind == "session_meta" else value
        if not isinstance(payload, dict):
            payload = {}
        if identifier is None:
            if tool == "codex" and kind == "session_meta":
                candidate = payload.get("id")
            elif tool == "pi" and kind == "session":
                if value.get("version", 1) not in (1, 2, 3):
                    notices.add(tool + ":unsupported-format")
                    return None
                candidate = payload.get("id")
            elif tool == "claude":
                candidate = value.get("sessionId")
            else:
                candidate = None
            if valid_id(candidate) and valid_path(payload.get("cwd")):
                identifier = candidate
                directory = payload["cwd"]
        if tool == "claude":
            named = title(value.get("customTitle")) or named
            summary = title(value.get("aiTitle")) or (title(value.get("summary")) if kind == "summary" else "") or summary
        elif tool == "pi" and kind == "session_info":
            named = title(value.get("name")) or named
        elif tool == "codex" and kind == "session_meta":
            named = title(payload.get("thread_name")) or title(payload.get("name")) or named
        if verify and identifier:
            break
        if verify and count >= 128:
            break
    if not identifier:
        notices.add(tool + ":unrecognized-metadata")
        return None
    indexed = (index or {}).get(identifier, {})
    if tool == "codex":
        named = indexed.get("title") or named
    if not last_active and indexed.get("updated"):
        last_active = indexed["updated"]
        activity_source = "index"
    if not last_active:
        last_active = max(0, info.st_mtime)
        activity_source = "file"
    return dict(tool=tool, sessionID=identifier, directory=directory, file=str(file), dataRoot=str(roots[tool]),
                modified=info.st_mtime, lastActive=last_active, activitySource=activity_source, title=named or summary)


if options.verify:
    requested = json.loads(options.verify)
    tool = requested["tool"]
    source = pathlib.Path(requested["file"])
    if tool not in roots or not valid_path(str(source)) or not valid_id(requested.get("sessionID")):
        raise SystemExit("invalid session source")
    allowed = [roots[tool]]
    if tool == "codex":
        allowed.append(roots[tool].parent / "archived_sessions")
    def belongs(root):
        try:
            source.resolve().relative_to(root.resolve())
            return True
        except ValueError:
            return False
    if not any(belongs(root) for root in allowed):
        raise SystemExit("session outside tool root")
    record = metadata(source, tool, verify=True)
    if record is None or any(record[key] != requested[key] for key in ("tool", "sessionID", "directory", "file", "dataRoot")):
        raise SystemExit("session changed or unavailable")
    if not pathlib.Path(record["directory"]).is_dir():
        raise SystemExit("working directory unavailable")
    print(json.dumps(record, ensure_ascii=False))
else:
    tools = []
    for tool in roots:
        candidate = shutil.which(tool)
        if candidate is None:
            for directory in (home / ".local/bin", home / ".npm-global/bin", pathlib.Path("/opt/homebrew/bin"), pathlib.Path("/usr/local/bin")):
                executable = directory / tool
                if executable.is_file() and os.access(executable, os.X_OK):
                    candidate = str(executable)
                    break
        tools.append(dict(tool=tool, executable=os.path.abspath(candidate) if candidate else None))
    if options.history:
        for tool in ([options.tool] if options.tool else roots):
            index = session_index(tool)
            sources = [roots[tool]]
            if tool == "codex" and (roots[tool].parent / "archived_sessions").exists():
                sources.append(roots[tool].parent / "archived_sessions")
            for root in sources:
                for source in files(root, tool):
                    record = metadata(source, tool, index)
                    if record:
                        key = (tool, record["sessionID"])
                        if key not in records or records[key]["lastActive"] < record["lastActive"]:
                            records[key] = record
                if truncated:
                    break
            if truncated:
                break
    ordered = sorted(records.values(), key=lambda row: (-row["lastActive"], row["sessionID"]))
    output_rows = []
    output_bytes = 0
    for record in ordered:
        output_bytes += len(json.dumps(record, ensure_ascii=False).encode("utf-8")) + 1
        if output_bytes > 12 * 1024 * 1024:
            notices.add("history:output-limit")
            truncated = True
            break
        output_rows.append(record)
    print(json.dumps(dict(home=str(home), user=str(os.getuid()), tools=tools, sessions=output_rows,
                          notices=sorted(notices), truncated=truncated), ensure_ascii=False))
