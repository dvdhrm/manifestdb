"""osbuild-mpp - OSBuild Manifest-Pre-Processor

The Manifest-Pre-Processor processes annotated osbuild manifests and produces
manifests ready to be consumed by osbuild. In its basic form, it takes a valid
osbuild manifest on standard-input and produces a copy on standard output. A
set of pre-processors is available which apply transformations to a manifest as
it flows through MPP.

The transformations available include simple converters that transform old
manifest versions to newer ones, but also annotated converters that replace
special annotations with generated content.
"""

# pylint: disable=invalid-name,too-few-public-methods


import argparse
import contextlib
import copy
import json
import os
import sys
import tempfile


def dict_enter(dct, key, default):
    """Access dictionary entry with a default value"""

    if key not in dct:
        dct[key] = default
    return dct[key]


def dict_strip(dct, key, condition):
    """Strip a dictionary entry if it matches"""

    if key in dct and dct[key] == condition:
        del dct[key]


def dict_contains_only(dct, allowed, allow_mpp=True):
    """Check whether a dictionary contains only allowed keys"""

    for key in dct.keys():
        if allow_mpp and key.startswith("mpp-"):
            continue
        if key in allowed:
            continue
        return False
    return True


class Manifest:
    """OSBuild Manifest"""

    _linkinfo = [
        {"link": "pipeline", "path": ["pipeline"], "default": {}},
        {"link": "stages", "path": ["pipeline", "stages"], "default": []},
        {"link": "sources", "path": ["sources"], "default": {}},
        {"link": "files", "path": ["sources", "org.osbuild.files"], "default": {}},
        {"link": "urls", "path": ["sources", "org.osbuild.files", "urls"], "default": {}},
    ]

    def __init__(self, data):
        self.data = data
        self.levels = []
        self.links = {}

        self.refresh()

    def _strip(self):
        # Create a copy of the entire manifest so we can modify it without
        # disrupting the cached links.
        manifest = copy.deepcopy(self.data)

        # Iterate the link-info array in reverse order and
        # drop every cached entry if it matches its default value. This keeps
        # manifests tidy.
        for info in reversed(self._linkinfo):
            itr = manifest
            for step in info["path"][:-1]:
                itr = itr.get(step)
                if not itr:
                    break
            else:
                dict_strip(itr, info["path"][-1], info["default"])

        return manifest

    @classmethod
    def from_stream(cls, stream):
        """Create a new manifest from a stream"""

        try:
            data = json.load(stream)
        except json.JSONDecodeError:
            print("Cannot JSON-decode input", file=sys.stderr)
            raise

        return cls(data)

    def to_stream(self, stream):
        """Write the manifest to a stream"""

        try:
            json.dump(self._strip(), stream, indent=2, sort_keys=True)
            print(end="\n", file=stream)
        except TypeError:
            print("Cannot JSON-encode manifest", file=sys.stderr)
            raise

    def refresh(self):
        """Refresh cached links"""

        self.levels = []
        self.links = {}

        # The top-level entry represents the manifest and is a dictionary. Make
        # sure it actually is a dictionary.
        assert isinstance(self.data, dict)

        # For faster access, we create links to some of the entries in the
        # manifest. The link-info array contains descriptions of every link we
        # create and cache.
        for info in self._linkinfo:
            itr = self.data
            for step in info["path"][:-1]:
                itr = itr[step]
            self.links[info["link"]] = dict_enter(itr, info["path"][-1], copy.copy(info["default"]))

        # To simplify recursive operations on the manifest, we collect all
        # pipelines as links. This allows iterating a plain array to access
        # all pipelines in a manifest.
        itr = self.data
        while itr:
            self.levels.append(itr)
            itr = itr.get("pipeline")
            if itr:
                itr = itr.get("build")

        # Some sanity tests to verify the manifest does not contain entries
        # that we do not know about.
        dict_contains_only(self.data, ["pipeline", "sources"])
        dict_contains_only(self.links["pipeline"], ["build", "stages"])
        dict_contains_only(self.links["sources"], ["org.osbuild.files"])
        dict_contains_only(self.links["files"], ["urls"])
        for itr in self.levels:
            if itr != self.data:
                dict_contains_only(itr, ["pipeline", "runner"])
            dict_contains_only(itr.get("pipeline", {}), ["build", "stages"])

    def update_urls(self, urls):
        """Update source URLs with the given data"""
        self.links["urls"].update(urls)

    def update_sources(self, sources):
        """Update sources with the given manifest-sources"""

        for key, value in sources.items():
            if key == "org.osbuild.files":
                assert dict_contains_only(value, ["urls"])
                if "urls" in value:
                    self.update_urls(value["urls"])
            else:
                raise ValueError("Unknown source type")


class MppDepsolve:
    """Dependency Solving Transformation"""

    def __init__(self, mpp):
        self._mpp = mpp
        self._manifest = mpp.manifest
        self._path_dnfcache = None
        self._path_dnfpersist = None

    def _collect(self):
        # Create dnf-caches.
        self._path_dnfcache = os.path.join(self._mpp.path_cache, "dnf-cache")
        os.makedirs(self._path_dnfcache, exist_ok=True)
        self._path_dnfpersist = os.path.join(self._mpp.path_cache, "dnf-persist")
        os.makedirs(self._path_dnfpersist, exist_ok=True)

        # Collect all stages of interest.
        todos = []
        for itr in self._manifest.levels:
            for stage in itr.get("pipeline", {}).get("stages", []):
                if stage.get("name") != "org.osbuild.rpm":
                    continue
                if "mpp-depsolve" not in stage.get("options", {}):
                    continue
                todos.append(stage)

        return todos

    def _process_one(self, todo):
        todo_options = todo["options"]
        todo_mpp = todo_options["mpp-depsolve"]
        todo_baseurl = todo_mpp["baseurl"]

        # Resolve dependencies.
        deps = self._dnf_resolve(
            options=todo_mpp,
            path_cache=self._path_dnfcache,
            path_persist=self._path_dnfpersist,
        )

        # Append all packages to the RPM-pkg-list.
        urls = {}
        for dep in deps:
            dict_enter(todo_options, "packages", []).append(dep["checksum"])
            urls[dep["checksum"]] = todo_baseurl + "/" + dep["path"]

        # Update sources with the new URLs.
        self._manifest.update_urls(urls)

        del todo_options["mpp-depsolve"]

    def process(self):
        """Run pipeline processor"""

        todos = self._collect()
        for todo in todos:
            self._process_one(todo)
        return len(todos) > 0

    # pylint: disable=too-many-locals
    @staticmethod
    def _dnf_resolve(*, options, path_cache, path_persist):

        # pylint: disable=import-outside-toplevel,no-member
        import dnf
        # pylint: disable=import-outside-toplevel,no-member
        import hawkey

        # Fetch options early to have a uniform error location in case one
        # is not provided by the manifest.
        opt_architecture = options["architecture"]
        opt_fedora = options["fedora"]
        opt_packages = options.get("packages", [])

        def _dnf_repo(conf, repo_id, repo_metalink):
            repo = dnf.repo.Repo(repo_id, conf)
            repo.metalink = repo_metalink
            return repo

        def _dnf_base():
            base = dnf.Base()
            base.conf.cachedir = path_cache
            base.conf.config_file_path = "/dev/null"
            base.conf.module_platform_id = "f" + str(opt_fedora)
            base.conf.persistdir = path_persist
            base.conf.substitutions["arch"] = str(opt_architecture)
            base.conf.substitutions["basearch"] = str(dnf.rpm.basearch(opt_architecture))
            base.conf.substitutions["repo"] = "fedora-" + str(opt_fedora)

            base.repos.add(
                _dnf_repo(
                    base.conf,
                    "default",
                    "https://mirrors.fedoraproject.org/metalink?repo=$repo&arch=$basearch",
                )
            )

            base.fill_sack(load_system_repo=False)
            return base

        deps = []
        if len(opt_packages) > 0:
            base = _dnf_base()
            base.install_specs(opt_packages)
            base.resolve()

            for tsi in base.transaction:
                if tsi.action not in dnf.transaction.FORWARD_ACTIONS:
                    continue

                checksum_type = hawkey.chksum_name(tsi.pkg.chksum[0])
                checksum_hex = tsi.pkg.chksum[1].hex()
                pkg = {
                    "checksum": f"{checksum_type}:{checksum_hex}",
                    "name": tsi.pkg.name,
                    "path": tsi.pkg.relativepath,
                }
                deps.append(pkg)

        return sorted(deps, key=lambda dep: dep["checksum"])


class MppPipelineBase:
    """Pipeline Base Transformation"""

    def __init__(self, mpp):
        self._mpp = mpp
        self._manifest = mpp.manifest

    def _collect(self):
        todos = []
        for itr in self._manifest.levels:
            if "mpp-pipeline-base" in itr.get("pipeline", {}):
                todos.append(itr["pipeline"])
        return todos

    def _process_one(self, todo):
        todo_mpp = todo["mpp-pipeline-base"]

        # Import the specified manifest.
        with open(os.path.join(self._mpp.path_cwd, todo_mpp), "r") as stream:
            imp = Manifest.from_stream(stream)

        # Bail out if there are build-pipeline conflicts.
        if todo.get("build") and imp.data.get("build"):
            raise ValueError("Importing conflicting build pipelines")

        # Update sources with all sources from the import.
        self._manifest.update_sources(imp.links["sources"])

        # Import the build-pipeline.
        if imp.data.get("build"):
            todo["build"] = imp.data["build"]

        # Rebase stages on the imported pipeline.
        stages = imp.links["stages"] + todo.get("stages", [])
        if stages:
            todo["stages"] = stages

        # Drop MPP annotation.
        del todo["mpp-pipeline-base"]

    def process(self):
        """Run pipeline processor"""

        todos = self._collect()
        for todo in todos:
            self._process_one(todo)
        return len(todos) > 0


class MppPipelineImport:
    """Pipeline Import Transformation"""

    def __init__(self, mpp):
        self._mpp = mpp
        self._manifest = mpp.manifest

    def _collect(self):
        todos = []
        for itr in self._manifest.levels:
            if "mpp-pipeline-import" in itr:
                todos.append(itr)
        return todos

    def _process_one(self, todo):
        todo_mpp = todo["mpp-pipeline-import"]

        # Import the specified manifest.
        with open(os.path.join(self._mpp.path_cwd, todo_mpp), "r") as stream:
            imp = Manifest.from_stream(stream)

        # Update sources with all sources from the import.
        self._manifest.update_sources(imp.links["sources"])

        # Import pipeline.
        todo["pipeline"] = imp.links["pipeline"]

        # Drop MPP annotation.
        del todo["mpp-pipeline-import"]

    def process(self):
        """Run pipeline processor"""

        todos = self._collect()
        for todo in todos:
            self._process_one(todo)
        return len(todos) > 0


class Mpp:
    """Manifest-Pre-Processor Application Class"""

    def __init__(self, argv):
        self._argv = argv
        self._ctx = contextlib.ExitStack()
        self._manifest = None
        self._path_cache = None
        self._path_cwd = None

    def _parse_args(self):
        parser = argparse.ArgumentParser(
            add_help=True,
            allow_abbrev=False,
            argument_default=None,
            description="OSBuild Manifest-Pre-Processor",
            prog="osbuild-mpp",
        )

        parser.add_argument(
            "--cache",
            help="Path to cache-directory to use",
            metavar="PATH",
            type=os.path.abspath,
        )

        parser.add_argument(
            "--cwd",
            help="Path to current-working-directory to use",
            metavar="PATH",
            type=os.path.abspath,
        )

        return parser.parse_args(self._argv[1:])

    def __enter__(self):
        with self._ctx as ctx:
            args = self._parse_args()

            # If `--cache=DIR` was specified, try creating the directory
            # (unless it exists already). If it was not specified, create a
            # temporary directory instead.
            if args.cache is None:
                self._path_cache = ctx.enter_context(tempfile.TemporaryDirectory())
            else:
                try:
                    self._path_cache = os.path.join(os.getcwd(), args.cache)
                    os.makedirs(self._path_cache, exist_ok=True)
                except OSError:
                    print("Cannot create cache directory", file=sys.stderr)
                    raise

            # If `--cwd` was specified, we use it as base for all relative
            # file-system operations. If not, we use the actual CWD of the
            # process.
            if args.cwd is None:
                self._path_cwd = os.getcwd()
            else:
                self._path_cwd = os.path.join(os.getcwd(), args.cwd)

            # We always expect a manifest on standard-input. Import it and
            # provide it as property.
            self._manifest = Manifest.from_stream(sys.stdin)

            # Initialization succeeded. Save the exit-stack for later.
            self._ctx = ctx.pop_all()

        return self

    def __exit__(self, exc_type, exc_value, exc_tb):
        with self._ctx:
            pass

    def run(self):
        """Execute the pre-processors"""

        # Run processors as long as there is progress.
        procs = [
            MppDepsolve,
            MppPipelineBase,
            MppPipelineImport,
        ]
        progress = True
        while progress:
            progress = False
            for proc in procs:
                if proc(self).process():
                    progress = True
                    self._manifest.refresh()

        # Write the resulting manifest to standard-output.
        self._manifest.to_stream(sys.stdout)
        return 0

    @property
    def manifest(self):
        """Access the linked manifest"""
        return self._manifest

    @property
    def path_cache(self):
        """Query path to the cache directory"""
        return self._path_cache

    @property
    def path_cwd(self):
        """Query path to the current working directory"""
        return self._path_cwd
