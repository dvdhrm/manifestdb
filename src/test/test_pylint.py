"""Run `pylint` on all python sources."""


import subprocess
import unittest


class TestPylint(unittest.TestCase):
    """Testcases of this unittest"""

    # pylint: disable=no-self-use
    def test_pylint(self):
        """Run pylint on all python sources"""

        files = subprocess.check_output(
            [
                "git",
                "ls-tree",
                "-rz",
                "--full-tree",
                "--name-only",
                "HEAD",
            ]
        ).decode()

        # File list is separated by NULs, so split into array.
        files = files.split('\x00')

        # Filter out all our python files.
        files = filter(lambda p: p.endswith(".py"), files)

        # Run pylint on all files.
        proc = subprocess.Popen(
            [
                "pylint",
                "--disable", "duplicate-code",
            ] + list(files),
            encoding="utf-8",
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        output, _ = proc.communicate()
        if proc.returncode != 0:
            print("FAILED")
            print(output)
            self.fail()
