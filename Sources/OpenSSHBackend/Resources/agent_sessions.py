import argparse
import json
import os
import pathlib
import shutil
import stat
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--history", action="store_true")
parser.add_argument("--verify")
options = parser.parse_args()
home = pathlib.Path.home()
deadline = time.monotonic() + 8
notices = set()
records = {}
truncated = False
visited = 0

def valid_path(value):
    return isinstance(value, str) and value.startswith("/") and len(value) <= 8192 and not any(ord(char) < 32 or ord(char) == 127 for char in value)

def readable_object(line):
    if len(line) > 65536:
        return {}
    try:
        result = json.loads(line)
        return result if isinstance(result, dict) else {}
    except (ValueError, UnicodeError, RecursionError):
        return {}

def metadata(file, tool):
    try:
        info = file.lstat()
        if not stat.S_ISREG(info.st_mode):
            return None
        descriptor = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            current = os.fstat(stream.fileno())
            if not stat.S_ISREG(current.st_mode) or (current.st_ino, current.st_dev) != (info.st_ino, info.st_dev):
                notices.add(tool + ":file-changed")
                return None
            for index in range(8 if tool == "claude" else 1):
                line = stream.readline(65537)
                if len(line) > 65536:
                    notices.add(tool + ":oversized-metadata")
                    return None
                value = readable_object(line)
                if tool == "codex":
                    value = value.get("payload", {}) if value.get("type") == "session_meta" else {}
                    if not isinstance(value, dict):
                        return None
                    identifier = value.get("id")
                elif tool == "pi":
                    if value.get("type") != "session" or value.get("version") not in (1, 2, 3):
                        notices.add("pi:unsupported-format")
                        return None
                    identifier = value.get("id")
                else:
                    identifier = value.get("sessionId")
                directory = value.get("cwd")
                if isinstance(identifier, str) and valid_path(directory):
                    try:
                        uuid.UUID(identifier)
                    except (ValueError, TypeError, AttributeError):
                        return None
                    return dict(tool=tool, sessionID=identifier, directory=directory, file=str(file),
                                dataRoot=str(roots[tool].expanduser().absolute()), modified=info.st_mtime, title=pathlib.Path(directory).name[:300] or directory)
        notices.add(tool + ":unrecognized-metadata")
    except (OSError, ValueError):
        notices.add(tool + ":unreadable")
    return None

def files(root):
    global visited, truncated
    if not root.exists() or root.is_symlink():
        return
    def unreadable(error):
        notices.add("history:unreadable-directory")
    for directory, folders, names in os.walk(root, followlinks=False, onerror=unreadable):
        visited += 1
        if visited > 15000 or time.monotonic() > deadline:
            truncated = True
            return
        if len(pathlib.Path(directory).relative_to(root).parts) >= 8:
            if folders:
                truncated = True
            folders[:] = []
        folders[:] = sorted((name for name in folders if name not in ("subagents", "tasks") and not pathlib.Path(directory, name).is_symlink()), reverse=True)
        for name in sorted(names, reverse=True):
            visited += 1
            if visited > 15000 or time.monotonic() > deadline:
                truncated = True
                return
            if name.endswith(".jsonl"):
                yield pathlib.Path(directory, name)

roots = {
    "claude": pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude"))) / "projects",
    "codex": pathlib.Path(os.environ.get("CODEX_HOME", str(home / ".codex"))) / "sessions",
    "pi": pathlib.Path(os.environ.get("PI_CODING_AGENT_SESSION_DIR", str(pathlib.Path(os.environ.get("PI_CODING_AGENT_DIR", str(home / ".pi/agent"))) / "sessions")))
}
if options.verify:
    requested = json.loads(options.verify)
    tool = requested["tool"]
    source = pathlib.Path(requested["file"])
    if tool not in roots or not valid_path(str(source)):
        raise SystemExit("invalid session source")
    try:
        source.resolve().relative_to(roots[tool].expanduser().resolve())
    except ValueError:
        raise SystemExit("session outside tool root")
    record = metadata(source, tool)
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
        for tool, root in roots.items():
            for source in files(root.expanduser().absolute()):
                record = metadata(source, tool)
                if record:
                    key = (tool, record["sessionID"], record["directory"])
                    if key not in records or records[key]["modified"] < record["modified"]:
                        records[key] = record
            if truncated:
                break
    ordered = sorted(records.values(), key=lambda row: row["modified"], reverse=True)
    print(json.dumps(dict(home=str(home), user=str(os.getuid()), tools=tools, sessions=ordered[:200],
                          notices=sorted(notices), truncated=truncated or len(ordered) > 200), ensure_ascii=False))
