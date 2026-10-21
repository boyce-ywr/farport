import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


SCANNER = Path(__file__).resolve().parents[2] / "Sources/OpenSSHBackend/Resources/agent_sessions.py"


class AgentListingChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="farport-session-list-")
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, HOME=str(self.root),
                                CLAUDE_CONFIG_DIR=str(self.root / ".claude"),
                                CODEX_HOME=str(self.root / ".codex"),
                                PI_CODING_AGENT_DIR=str(self.root / ".pi/agent"),
                                PI_CODING_AGENT_SESSION_DIR=str(self.root / ".pi/agent/sessions"))

    def tearDown(self):
        self.temporary.cleanup()

    def session(self, tool, project, stamp, name, identifier=None):
        identifier = identifier or str(uuid.uuid4())
        directory = self.root / project
        directory.mkdir(exist_ok=True)
        roots = {"claude": self.root / ".claude/projects", "codex": self.root / ".codex/sessions",
                 "pi": self.root / ".pi/agent/sessions"}
        file = roots[tool] / project / (identifier + ".jsonl")
        file.parent.mkdir(parents=True, exist_ok=True)
        if tool == "codex":
            rows = [{"type": "session_meta", "timestamp": stamp,
                     "payload": {"id": identifier, "cwd": str(directory), "base_instructions": "PRIVATE_NOT_RETURNED"}},
                    {"type": "event_msg", "timestamp": stamp, "payload": {"type": "task_complete", "private": "PRIVATE_NOT_RETURNED"}}]
            index = self.root / ".codex/session_index.jsonl"
            with index.open("a") as stream:
                stream.write(json.dumps(dict(id=identifier, thread_name=name, updated_at=stamp)) + "\n")
        elif tool == "claude":
            rows = [{"type": "file-history-snapshot", "snapshot": {"timestamp": stamp}},
                    {"type": "user", "sessionId": identifier, "cwd": str(directory), "timestamp": stamp,
                     "message": {"content": "PRIVATE_NOT_RETURNED"}},
                    {"type": "custom-title", "sessionId": identifier, "customTitle": name},
                    {"type": "assistant", "sessionId": identifier, "timestamp": stamp,
                     "message": {"content": "PRIVATE_NOT_RETURNED"}}]
        else:
            rows = [{"type": "session", "version": 3, "id": identifier, "cwd": str(directory), "timestamp": stamp},
                    {"type": "session_info", "name": name, "timestamp": stamp},
                    {"type": "message", "timestamp": stamp, "message": {"role": "user", "content": "PRIVATE_NOT_RETURNED"}}]
        file.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        return identifier, file

    def query(self, tool):
        result = subprocess.run([sys.executable, str(SCANNER), "--history", "--tool", tool],
                                env=self.environment, text=True, capture_output=True, timeout=30, check=True)
        self.assertNotIn("PRIVATE_NOT_RETURNED", result.stdout)
        return json.loads(result.stdout)

    def test_all_projects_names_activity_order_and_agent_scope(self):
        for tool in ("claude", "codex", "pi"):
            older, oldfile = self.session(tool, "project-a", "2026-09-01T00:00:00Z", tool + " old")
            newer, newfile = self.session(tool, "project-b", "2026-10-20T12:34:56Z", tool + " 新会话")
            os.utime(oldfile, (1800000000, 1800000000))
            os.utime(newfile, (1600000000, 1600000000))
            listing = self.query(tool)
            self.assertEqual([row["sessionID"] for row in listing["sessions"]], [newer, older])
            self.assertEqual(listing["sessions"][0]["title"], tool + " 新会话")
            self.assertEqual(listing["sessions"][0]["activitySource"], "session")
            self.assertTrue(all(row["tool"] == tool for row in listing["sessions"]))
            expected = datetime.datetime(2026, 10, 20, 12, 34, 56, tzinfo=datetime.timezone.utc).timestamp()
            self.assertEqual(listing["sessions"][0]["lastActive"], expected)

    def test_does_not_cut_off_after_200(self):
        for index in range(240):
            self.session("pi", "project-" + str(index % 3), "2026-10-01T00:00:00Z", "session-" + str(index))
        listing = self.query("pi")
        self.assertEqual(len(listing["sessions"]), 240)
        self.assertFalse(listing["truncated"])

    def test_codex_archived_records_are_included(self):
        identifier, file = self.session("codex", "archived-project", "2026-10-20T00:00:00Z", "archived")
        archived = self.root / ".codex/archived_sessions" / file.name
        archived.parent.mkdir()
        file.rename(archived)
        listing = self.query("codex")
        self.assertEqual(listing["sessions"][0]["sessionID"], identifier)
        self.assertEqual(listing["sessions"][0]["file"], str(archived))
        record = listing["sessions"][0]
        verified = subprocess.run([sys.executable, str(SCANNER), "--verify", json.dumps(record)], env=self.environment,
                                  text=True, capture_output=True, timeout=30, check=True)
        self.assertEqual(json.loads(verified.stdout)["sessionID"], identifier)

    def test_unknown_compressed_history_is_reported(self):
        root = self.root / ".codex/sessions"
        root.mkdir(parents=True)
        (root / "rollout.jsonl.zst").write_bytes(b"unsupported compressed fixture")
        listing = self.query("codex")
        self.assertIn("codex:compressed-format-unavailable", listing["notices"])

    def test_missing_root_is_not_silently_an_empty_history(self):
        listing = self.query("claude")
        self.assertEqual(listing["sessions"], [])
        self.assertTrue(any("root-missing" in note for note in listing["notices"]))

    def test_titles_updates_and_many_metadata_lines(self):
        identifier, file = self.session("claude", "project", "2026-10-20T00:00:00Z", "old")
        original = file.read_text()
        file.write_text((json.dumps({"type": "file-history-snapshot"}) + "\n") * 12 + original)
        with file.open("a") as stream:
            stream.write(json.dumps({"type": "custom-title", "sessionId": identifier, "customTitle": "latest name"}) + "\n")
        listing = self.query("claude")
        self.assertEqual(listing["sessions"][0]["title"], "latest name")
        self.assertEqual(listing["sessions"][0]["sessionID"], identifier)

    def test_missing_timestamp_is_explicitly_estimated(self):
        identifier, file = self.session("pi", "project", "invalid", "name")
        listing = self.query("pi")
        self.assertEqual(listing["sessions"][0]["activitySource"], "file")
        self.assertEqual(listing["sessions"][0]["sessionID"], identifier)

    def test_full_scan_does_not_rewrite_session_files(self):
        _, file = self.session("pi", "project", "2026-10-20T00:00:00Z", "hello")
        before = (file.read_bytes(), file.stat().st_mtime_ns)
        self.query("pi")
        self.assertEqual((file.read_bytes(), file.stat().st_mtime_ns), before)

    def test_no_title_is_not_faked_from_directory(self):
        _, _ = self.session("pi", "project", "2026-10-20T00:00:00Z", "")
        self.assertEqual(self.query("pi")["sessions"][0]["title"], "")


if __name__ == "__main__":
    unittest.main()
