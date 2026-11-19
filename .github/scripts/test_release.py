import unittest
from unittest.mock import patch

from release import next_tag, note_lines


class ReleaseTests(unittest.TestCase):
    def test_version_reuses_only_its_own_candidate(self):
        self.assertEqual(next_tag("", "a", {}), "v0.3.0")
        self.assertEqual(next_tag("v0.3.0", "a", {"v0.3.1": "a"}), "v0.3.1")
        self.assertEqual(next_tag("v0.3.0", "b", {"v0.3.1": "a"}), "v0.3.2")

    @patch("release.git", return_value="d\nm")
    def test_notes_credit_original_pull_request_and_direct_commit(self, git):
        commits = [("s", "base", "Sticky notes"), ("d", "s", "Test"), ("m", "s d", "Merge PR")]
        pr = {
            "number": 42, "merged_at": "today", "merge_commit_sha": "m",
            "title": "Fix [notes]", "user": {"login": "author"},
            "html_url": "https://github.com/owner/repo/pull/42",
        }
        lines = list(note_lines(commits, [pr, {**pr, "merged_at": None}], "owner/repo", "base", "m"))
        self.assertEqual(lines[:2], [
            r"- Fix \[notes\] by @author in [#42](https://github.com/owner/repo/pull/42)",
            "- Sticky notes ([`s`](https://github.com/owner/repo/commit/s))",
        ])
        self.assertIn("/compare/base...m", lines[-1])
        git.assert_called_once_with("rev-list", "m^1..m")


if __name__ == "__main__":
    unittest.main()
