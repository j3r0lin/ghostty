"""Unit tests for the it2 shim.

Loads the `it2` script (no .py extension) via SourceFileLoader and exercises
the pure functions plus a handful of command handlers with the AppleScript
runner mocked out, so no real osascript/it2 call is ever made.
"""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from unittest import mock

MODULE_PATH = os.path.join(os.path.dirname(__file__), "it2")


def _load_it2():
    loader = importlib.machinery.SourceFileLoader("it2_shim_under_test", MODULE_PATH)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


it2 = _load_it2()

# A session id crafted to break out of a naively-embedded AppleScript string
# literal: closing quote, string concatenation, a shell-out, and then
# re-opening a literal to keep the surrounding script syntactically valid.
MALICIOUS_ID = 'x" & (do shell script "touch /tmp/pwn") & "'


def _literal_is_closed_and_reconstructs(script, original, marker='id is "'):
    """True if `script` contains a single double-quoted AppleScript literal,
    starting right after `marker`, that once AppleScript-unescaped equals
    `original` -- i.e. the value never terminates the literal early with an
    unescaped double quote.
    """
    marker_pos = script.index(marker)
    start = marker_pos + len(marker) - 1
    i = start + 1
    out = []
    while i < len(script):
        c = script[i]
        if c == "\\" and i + 1 < len(script):
            out.append(script[i + 1])
            i += 2
            continue
        if c == '"':
            # literal closes here
            recovered = "".join(out)
            return recovered == original
        out.append(c)
        i += 1
    return False  # never closed


class SessionIdEscapingTests(unittest.TestCase):
    def test_malicious_session_id_is_escaped(self):
        escaped = it2._escape_js(MALICIOUS_ID)
        literal = f'resolve("{escaped}")'
        self.assertTrue(
            _literal_is_closed_and_reconstructs(literal, MALICIOUS_ID, 'resolve("'),
            f"session id leaked out of its string literal: {literal!r}",
        )
        naive = f'resolve("{MALICIOUS_ID}")'
        self.assertNotEqual(literal, naive)


class SessionFocusCloseInjectionTests(unittest.TestCase):
    def _body(self, run):
        return run.call_args[0][0]

    def test_focus_escapes_session_id(self):
        args = argparse.Namespace(session=MALICIOUS_ID, session_id=None)
        with mock.patch.object(it2, "run_jxa") as run:
            run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            it2.cmd_session_focus(args)
        body = self._body(run)
        self.assertTrue(
            _literal_is_closed_and_reconstructs(body, MALICIOUS_ID, 'resolve("'),
            f"session id leaked into focus script unescaped: {body!r}",
        )

    def test_close_escapes_session_id(self):
        args = argparse.Namespace(session=MALICIOUS_ID)
        with mock.patch.object(it2, "run_jxa") as run:
            run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            it2.cmd_session_close(args)
        body = self._body(run)
        self.assertTrue(
            _literal_is_closed_and_reconstructs(body, MALICIOUS_ID, 'resolve("'),
            f"session id leaked into close script unescaped: {body!r}",
        )

    def test_tabs_escapes_self_session_id(self):
        with mock.patch.object(it2, "_self_session_id", return_value=MALICIOUS_ID), \
             mock.patch.object(it2, "run_jxa") as run:
            run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            it2.cmd_session_tabs(argparse.Namespace())
        body = self._body(run)
        escaped = '"' + it2._escape_js(MALICIOUS_ID) + '"'
        self.assertIn(escaped, body)
        self.assertNotIn(MALICIOUS_ID, body.replace(it2._escape_js(MALICIOUS_ID), ""))


class InstanceSelectionTests(unittest.TestCase):
    def setUp(self):
        it2._instance_pid = None

    def test_ancestor_instance_is_used_when_it_owns_the_session(self):
        with mock.patch.object(it2, "_ancestor_ghostty_pid", return_value=100), \
             mock.patch.object(it2, "_instance_owning", return_value=100), \
             mock.patch.object(it2, "_ghostty_pids", return_value=[100, 200]):
            self.assertEqual(it2._select_instance("sess-a"), 100)

    def test_session_id_selects_the_instance_that_owns_it(self):
        # The ancestor instance does not own the requested session, so the
        # selection follows the session id to the other instance.
        def owns(session_id, pids):
            return 200 if 200 in pids else None

        with mock.patch.object(it2, "_ancestor_ghostty_pid", return_value=100), \
             mock.patch.object(it2, "_instance_owning", side_effect=owns), \
             mock.patch.object(it2, "_ghostty_pids", return_value=[100, 200]):
            self.assertEqual(it2._select_instance("sess-b"), 200)

    def test_ancestor_is_used_when_no_session_is_given(self):
        with mock.patch.object(it2, "_ancestor_ghostty_pid", return_value=100), \
             mock.patch.object(it2, "_ghostty_pids") as pids:
            self.assertEqual(it2._select_instance(None), 100)
        pids.assert_not_called()

    def test_single_instance_is_used_when_nothing_else_matches(self):
        with mock.patch.object(it2, "_ancestor_ghostty_pid", return_value=None), \
             mock.patch.object(it2, "_ghostty_pids", return_value=[300]):
            self.assertEqual(it2._select_instance(None), 300)

    def test_multiple_instances_without_a_match_exit_listing_pids(self):
        with mock.patch.object(it2, "_ancestor_ghostty_pid", return_value=None), \
             mock.patch.object(it2, "_ghostty_pids", return_value=[100, 200]), \
             contextlib.redirect_stderr(io.StringIO()) as err:
            with self.assertRaises(SystemExit) as ctx:
                it2._select_instance(None)
        self.assertNotEqual(ctx.exception.code, 0)
        message = err.getvalue()
        self.assertIn("100", message)
        self.assertIn("200", message)


class SessionCaptureHistoryTests(unittest.TestCase):
    def test_history_flag_errors_without_running_applescript(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.txt")
            args = argparse.Namespace(session=None, output=out, history=True)
            with mock.patch.object(it2, "run_jxa") as run, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as ctx:
                    it2.cmd_session_capture(args)
            run.assert_not_called()
            self.assertNotEqual(ctx.exception.code, 0)
            self.assertFalse(os.path.exists(out))

    def test_without_history_flag_writes_visible_screen(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.txt")
            args = argparse.Namespace(session=None, output=out, history=False)
            with mock.patch.object(it2, "run_jxa") as run, \
                 contextlib.redirect_stdout(io.StringIO()):
                run.return_value = mock.Mock(returncode=0, stdout="screen contents\n", stderr="")
                it2.cmd_session_capture(args)
            with open(out) as f:
                self.assertEqual(f.read(), "screen contents")


if __name__ == "__main__":
    unittest.main()
