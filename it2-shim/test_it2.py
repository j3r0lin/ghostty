"""Unit tests for the it2 shim.

Loads the `it2` script (no .py extension) via SourceFileLoader and exercises
the pure functions plus a handful of command handlers with the AppleScript
runner mocked out, so no real osascript/it2 call is ever made.
"""
import argparse
import importlib.machinery
import importlib.util
import os
import sys
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


class ApplescriptTargetTests(unittest.TestCase):
    def test_normal_uuid_target_unchanged_shape(self):
        target = it2._applescript_target("ABCDEF12-3456-7890-ABCD-EF1234567890")
        self.assertEqual(
            target,
            'first terminal whose id is "ABCDEF12-3456-7890-ABCD-EF1234567890"',
        )

    def test_no_session_falls_back_to_focused_terminal(self):
        with mock.patch.object(it2, "_self_session_id", return_value=""):
            target = it2._applescript_target(None)
        self.assertEqual(target, "focused terminal of selected tab of front window")

    def test_malicious_session_id_is_escaped(self):
        target = it2._applescript_target(MALICIOUS_ID)
        self.assertTrue(
            _literal_is_closed_and_reconstructs(target, MALICIOUS_ID),
            f"session id leaked out of its string literal: {target!r}",
        )
        # Sanity: naive interpolation would have closed the literal at the
        # first embedded quote, well before the end of the string.
        naive = f'first terminal whose id is "{MALICIOUS_ID}"'
        self.assertNotEqual(target, naive)


class SessionFocusCloseInjectionTests(unittest.TestCase):
    def test_focus_escapes_session_id(self):
        args = argparse.Namespace(session=MALICIOUS_ID, session_id=None)
        with mock.patch.object(it2, "run_applescript") as run:
            run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            it2.cmd_session_focus(args)
        script = run.call_args[0][0]
        self.assertTrue(
            _literal_is_closed_and_reconstructs(script, MALICIOUS_ID),
            f"session id leaked into focus script unescaped: {script!r}",
        )

    def test_close_escapes_session_id(self):
        args = argparse.Namespace(session=MALICIOUS_ID)
        with mock.patch.object(it2, "run_applescript") as run:
            run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            it2.cmd_session_close(args)
        script = run.call_args[0][0]
        self.assertTrue(
            _literal_is_closed_and_reconstructs(script, MALICIOUS_ID),
            f"session id leaked into close script unescaped: {script!r}",
        )

    def test_tabs_escapes_self_session_id(self):
        with mock.patch.object(it2, "_self_session_id", return_value=MALICIOUS_ID), \
             mock.patch.object(it2, "run_applescript") as run:
            run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            it2.cmd_session_tabs(argparse.Namespace())
        script = run.call_args[0][0]
        # my_id appears twice in the script (guard + comparison); both
        # occurrences must be inside a closed, correctly-escaped literal.
        occurrences = script.count('"' + it2._escape_applescript(MALICIOUS_ID) + '"')
        self.assertEqual(occurrences, 2)
        self.assertNotIn(MALICIOUS_ID, script.replace(
            it2._escape_applescript(MALICIOUS_ID), ""))


if __name__ == "__main__":
    unittest.main()
