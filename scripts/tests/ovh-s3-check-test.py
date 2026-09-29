#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import os
import sys
import unittest
from unittest import mock


SCRIPT = os.path.join(os.path.dirname(__file__), "..", "ovh-s3-check.py")
SPEC = importlib.util.spec_from_file_location("ovh_s3_check", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class S3CheckTest(unittest.TestCase):
    def run_check(self, codes):
        with (
            mock.patch.dict(
                os.environ,
                {"AWS_ACCESS_KEY_ID": "test", "AWS_SECRET_ACCESS_KEY": "test"},
                clear=True,
            ),
            mock.patch.object(sys, "argv", [SCRIPT, "bucket", "gra", "https://example.invalid"]),
            mock.patch.object(CHECK, "call", side_effect=codes) as call,
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as exited,
        ):
            CHECK.main()
        return exited.exception.code, call

    def test_delete_failure_fails_probe(self):
        code, _ = self.run_check([200, 200, 200, 500])
        self.assertEqual(code, 1)

    def test_random_key_and_success(self):
        with mock.patch.object(CHECK.secrets, "token_hex", return_value="random"):
            code, call = self.run_check([200, 200, 200, 204])
        self.assertEqual(code, 0)
        self.assertEqual(call.call_args_list[1].args[3], ".infrafactory-s3-probe-random")


if __name__ == "__main__":
    unittest.main()
