#!/usr/bin/python3

"""osbuild-mdb - OSBuild Manifest Database

This tool provides access to the OSBuild Manifest DB, performs maintenance
tasks on the database, and provides external access to the manifests.
"""

# pylint: disable=invalid-name,too-few-public-methods


import argparse
import contextlib
import errno
import hashlib
import json
import os
import stat
import subprocess
import sys
import urllib.request


@contextlib.contextmanager
def suppress_oserror(*errnos):
    """Suppress OSError Exceptions

    This is an extension to `contextlib.suppress()` from the python standard
    library. It catches any `OSError` exceptions and suppresses them. However,
    it only catches the exceptions that match the specified error numbers.

    Parameters
    ----------
    errnos
        A list of error numbers to match on. If none are specified, this
        function has no effect.
    """

    try:
        yield
    except OSError as e:
        if e.errno not in errnos:
            raise e


@contextlib.contextmanager
def open_tmpfile(dirpath, mode=0o777):
    """Open O_TMPFILE and optionally link it"""

    ctx = {"name": None, "stream": None, "link": True, "unlink": True}
    dirfd = None
    fd = None

    try:
        dirfd = os.open(dirpath, os.O_PATH | os.O_CLOEXEC)
        fd = os.open(".", os.O_RDWR | os.O_TMPFILE | os.O_CLOEXEC, mode, dir_fd=dirfd)
        with os.fdopen(fd, "rb+", closefd=False) as stream:
            ctx["stream"] = stream
            yield ctx
        if ctx["name"] is not None:
            if ctx["unlink"]:
                with suppress_oserror(errno.ENOENT):
                    os.unlink(ctx["name"], dir_fd=dirfd)
            if ctx["link"]:
                os.link(f"/proc/self/fd/{fd}", ctx["name"], dst_dir_fd=dirfd)
    finally:
        if fd is not None:
            os.close(fd)
        if dirfd is not None:
            os.close(dirfd)


class MdbBuild:
    """Database Command"""

    def __init__(self, mdb):
        self._mdb = mdb

    # pylint: disable=no-self-use
    def run(self):
        """Run database command"""

        return 0


class MdbPrefetch:
    """Database Command"""

    def __init__(self, mdb):
        self._mdb = mdb

    def _collect(self):
        sources = {
            "org.osbuild.files": {"urls": {}},
        }

        for itr in self._mdb.args.PATH:
            # Parse specified file as JSON document.
            try:
                with open(itr, "r") as filp:
                    data = json.load(filp)
            except json.JSONDecodeError:
                print(f"Cannot decode JSON in '{itr}'", file=sys.stderr)
                raise
            except OSError:
                print(f"Cannot open '{itr}'", file=sys.stderr)
                raise

            # Fetch "sources" and verify it is a dictionary.
            src = data.get("sources", {})
            if not isinstance(src, dict):
                raise ValueError(f"Sources definition not a dictionary in '{itr}'")

            # For each source, verify its content and merge into `sources`.
            for kind, args in src.items():
                if not isinstance(args, dict):
                    raise ValueError(f"Source entry '{kind}' not a dictionary in '{itr}'")

                if kind == "org.osbuild.files":
                    urls = args.get("urls", {})
                    if not isinstance(src, dict):
                        raise ValueError(f"URL collection not a dictionary in '{itr}'")

                    sources[kind]["urls"].update(urls)
                else:
                    raise ValueError(f"Unsupported source type '{kind}' in '{itr}'")

        return sources

    def _process_org_osbuild_files(self, args):
        urls = args.get("urls", {})
        if not urls:
            return

        dirpath = os.path.join(self._mdb.args.output, "org.osbuild.files")
        os.makedirs(dirpath, exist_ok=True)

        for checksum, url in urls.items():
            path = os.path.join(dirpath, checksum)

            print(f"Next source: {checksum}")
            print(f"             {path}")
            print(f"             {url}")

            if os.access(path, os.R_OK):
                print("             (cached)")

                with open(path, "rb") as filp:
                    hashproc = hashlib.sha256()
                    for block in iter(lambda: filp.read(4096), b''):
                        hashproc.update(block)

                    if "sha256:" + hashproc.hexdigest() != checksum:
                        raise ValueError(f"Wrong checksum in '{path}'")
            else:
                print("             (download)")

                with urllib.request.urlopen(url) as stream:
                    with open_tmpfile(dirpath, mode=0o644) as ctx:
                        hashproc = hashlib.sha256()
                        for block in iter(lambda: stream.read(4096), b''):
                            hashproc.update(block)
                            ctx["stream"].write(block)

                        if "sha256:" + hashproc.hexdigest() != checksum:
                            raise ValueError(f"Checksum mismatch for '{url}'")

                        ctx["name"] = checksum

    def run(self):
        """Run database command"""

        sources = self._collect()
        for kind, args in sources.items():
            if kind == "org.osbuild.files":
                self._process_org_osbuild_files(args)
            else:
                raise ValueError(f"Unsupported source type '{kind}' leaked from data collector")

        return 0


class MdbPreprocess:
    """Database Command"""

    def __init__(self, mdb):
        self._mdb = mdb

    def _collect(self):
        paths = []

        for itr in self._mdb.args.PATH:
            itr_base = self._mdb.args.srcdir
            itr_path = os.path.join(itr_base, itr)
            info = os.stat(itr_path)
            if stat.S_ISDIR(info.st_mode):
                for level, _subdirs, files in os.walk(itr_path):
                    rel = os.path.relpath(level, itr_base)
                    for entry in files:
                        paths.append(os.path.join(rel, entry))
            else:
                paths.append(itr)

        return paths

    def _process(self, path):
        src_path = os.path.join(self._mdb.args.srcdir, path)

        dst_path = os.path.join(self._mdb.args.dstdir, "by-tag", path)
        dst_dir, _dst_file = os.path.split(dst_path)

        hash_path = None
        hash_file = None
        hash_dir = os.path.join(self._mdb.args.dstdir, "by-checksum")

        # As first step we open the source file and stream it into a temporary
        # file in the `by-checksum` directory. We compute the checksum on the
        # fly and eventually link the file under its own checksum as name.
        with open(src_path, "r") as src_stream:
            with open_tmpfile(hash_dir, mode=0o644) as ctx:
                cmd = [
                    "python3",
                    "-m", "mpp",
                    "--cwd", self._mdb.args.srcdir,
                ]
                if self._mdb.args.cache is not None:
                    cmd += ["--cache", self._mdb.args.cache]

                proc = subprocess.Popen(
                    cmd,
                    stdin=src_stream,
                    stdout=subprocess.PIPE
                )

                hashproc = hashlib.sha256()
                for block in iter(lambda: proc.stdout.read(4096), b''):
                    hashproc.update(block)
                    ctx["stream"].write(block)

                if proc.wait() != 0:
                    raise RuntimeError("MPP failed")

                hash_file = "sha256-" + hashproc.hexdigest()
                hash_path = os.path.join(hash_dir, hash_file)
                ctx["name"] = hash_file

        # As a second step we mirror the source path and create a symlink to
        # the checksum-file we just created.
        os.makedirs(dst_dir, exist_ok=True)
        with suppress_oserror(errno.ENOENT):
            os.unlink(dst_path)
        os.symlink(os.path.relpath(hash_path, dst_dir), dst_path)

    def run(self):
        """Run database command"""

        paths = self._collect()
        for path in paths:
            self._process(path)

        return 0


class Mdb(contextlib.AbstractContextManager):
    """Manifest Database"""

    def __init__(self, argv):
        self.args = None
        self._argv = argv
        self._ctx = contextlib.ExitStack()
        self._parser = None

    def _parse_args(self):
        self._parser = argparse.ArgumentParser(
            add_help=True,
            allow_abbrev=False,
            argument_default=None,
            description="OSBuild Manifest Database",
            prog="osbuild-mdb",
        )

        self._parser.add_argument(
            "--cache",
            help="Path to cache-directory to use",
            metavar="PATH",
            type=os.path.abspath,
        )

        db = self._parser.add_subparsers(
            dest="cmd",
            title="Database Maintenance",
        )

        _db_build = db.add_parser(
            "build",
            add_help=True,
            allow_abbrev=False,
            argument_default=None,
            description="Run osbuild pipelines defined by a manifest",
            help="Run manifest pipelines",
            prog=f"{self._parser.prog} build",
        )

        db_prefetch = db.add_parser(
            "prefetch",
            add_help=True,
            allow_abbrev=False,
            argument_default=None,
            description="Prefetch sources of osbuild manifests",
            help="Prefetch manifest sources",
            prog=f"{self._parser.prog} prefetch",
        )
        db_prefetch.add_argument(
            "--output",
            help="Path to output directory",
            metavar="PATH",
            required=True,
            type=os.path.abspath,
        )
        db_prefetch.add_argument(
            "PATH",
            help="Path to manifests to prefetch sources of",
            nargs="+",
            type=str,
        )

        db_preprocess = db.add_parser(
            "preprocess",
            add_help=True,
            allow_abbrev=False,
            argument_default=None,
            description="Preprocess osbuild manifest stubs",
            help="Preprocess manifests",
            prog=f"{self._parser.prog} preprocess",
        )
        db_preprocess.add_argument(
            "--dstdir",
            default=os.getcwd(),
            help="Path to destination directory",
            metavar="PATH",
            type=os.path.abspath,
        )
        db_preprocess.add_argument(
            "--srcdir",
            default=os.getcwd(),
            help="Path to source directory",
            metavar="PATH",
            type=os.path.abspath,
        )
        db_preprocess.add_argument(
            "PATH",
            help="Path to manifest/directory to preprocess",
            nargs="*",
            type=str,
        )

        return self._parser.parse_args(self._argv[1:])

    def __enter__(self):
        with self._ctx as ctx:
            self.args = self._parse_args()

            # Initialization succeeded. Save the exit-stack for later.
            self._ctx = ctx.pop_all()

        return self

    def __exit__(self, exc_type, exc_value, exc_tb):
        with self._ctx:
            pass

    def run(self):
        """Execute the selected database commands"""

        if not self.args.cmd:
            print("No subcommand specified", file=sys.stderr)
            self._parser.print_help(file=sys.stderr)
            ret = 1
        elif self.args.cmd == "build":
            ret = MdbBuild(self).run()
        elif self.args.cmd == "prefetch":
            ret = MdbPrefetch(self).run()
        elif self.args.cmd == "preprocess":
            ret = MdbPreprocess(self).run()
        else:
            raise RuntimeError("Subcommand mismatch")

        return ret


if __name__ == "__main__":
    with Mdb(sys.argv) as global_mdb:
        sys.exit(global_mdb.run())
