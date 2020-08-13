#
# Repository Maintenance
#

SHELL = /bin/bash -o pipefail

BUILDDIR ?= .
SRCDIR ?= .

BIN_CAT ?= cat
BIN_CP ?= cp
BIN_CURL ?= curl
BIN_CUT ?= cut
BIN_DNF ?= dnf
BIN_DOCKER ?= docker
BIN_FIND ?= find
BIN_GIT ?= git
BIN_JQ ?= jq
BIN_LN ?= ln
BIN_LS ?= ls
BIN_MKDIR ?= mkdir
BIN_MV ?= mv
BIN_OSBUILD ?= osbuild
BIN_PYTHON3 ?= python3
BIN_RM ?= rm
BIN_S3CMD ?= s3cmd
BIN_SHA256SUM ?= sha256sum
BIN_TAR ?= tar
BIN_TEST ?= test
BIN_TOUCH ?= touch
BIN_XARGS ?= xargs

MAKE_SILENT = $(MAKE) --no-print-directory --silent

FN_BUILDDIR = $(patsubst ./%,%,$(BUILDDIR)/$(1))
FN_SRCDIR = $(patsubst ./%,%,$(SRCDIR)/$(1))

MSRC_IMAGE ?= sources
MSRC_REGISTRY ?= docker.pkg.github.com
MSRC_REPOSITORY ?= osbuild/manifestdb
MSRC_TOKEN ?=
MSRC_TRIPLE = $(MSRC_REGISTRY)/$(MSRC_REPOSITORY)/$(MSRC_IMAGE)

#
# Generic Targets
#
# The following is a set of generic targets used across the makefile. The
# following targets are defined:
#
#     help
#         This target prints all supported targets. It is meant as
#         documentation of targets we support and might use outside of this
#         repository.
#         This is also the default target.
#
#     $(BUILDDIR)/
#     $(BUILDDIR)/%/
#         This target simply creates the specified directory. It is limited to
#         the build-dir as a safety measure. Note that this requires you to use
#         a trailing slash after the directory to not mix it up with regular
#         files. Lastly, you mostly want this as order-only dependency, since
#         timestamps on directories do not affect their content.
#
#     FORCE
#         Dummy target to use as dependency to force `.PHONY` behavior on
#         targets that cannot use `.PHONY`.
#
#     in-srcdir:
#         This target asserts that `$(SRCDIR)` refers to the current working
#         directory. Note that `$(BUILDDIR)` might still refer to other
#         directories, and we always support out-of-tree builds. However, some
#         commands (e.g., `git`) do not support specifying a directory for all
#         possible commands, so some targets may need to be run from the source
#         directory.
#
#     .SECONDARY:
#         An empty SECONDARY target signals gnu-make to keep every intermediate
#         files around, even on failure.
#

.PHONY: help
help:
	@echo "make [TARGETS...]"
	@echo
	@echo "This is the maintenance makefile of manifestdb. The following"
	@echo "targets are available:"
	@echo
	@echo "    help:               Print this usage information."

$(BUILDDIR)/:
	$(BIN_MKDIR) -p "$@"

$(BUILDDIR)/%/:
	$(BIN_MKDIR) -p "$@"

.PHONY: FORCE
FORCE:

.PHONY: in-srcdir
in-srcdir:
	$(if \
		$(subst $(abspath $(CURDIR)),,$(abspath $(SRCDIR))), \
		$(error Changes to SRCDIR not supported by this target) \
	)

.SECONDARY:

#
# Manifest Enumeration
#
# This provides some helper collections for all the manifest-targets. It lists
# available manifests and provides them as collections.
#
# Different targets are provided that produce JSON formatted manifest lists:
#
#   mlist-checksum:
#     Produces a JSON array with all manifests checksums (i.e., an enumeration
#     of `./manifests/by-checksum/`).
#
#   mlist-checksum-diff:
#     Produces a subset of `mlist-checksum` including only the manifests that
#     have changes between git-revision `$(MLIST_A)` and `$(MLIST_B)`.
#
#   mlist-msrc:
#     List all manifest checksums which have a source-image cached via the
#     `msrc` targets. This queries the registry set in `$(MSRC_REGISTRY)` to
#     return a list of stored source-images.
#
#   mlist-msrc-diff:
#     Produces the difference of `mlist-checksum` and `mlist-msrc`, listing
#     only the manifests that lack a source-image in `$(MSRC_REGISTRY)`.
#

MANIFEST_PATHS = $(wildcard $(SRCDIR)/manifests/by-checksum/*)
MANIFEST_FILES = $(patsubst $(SRCDIR)/manifests/by-checksum/%,%,$(MANIFEST_PATHS))

.PHONY: mlist-checksum
mlist-checksum:
	$(BIN_LS) \
			-1b \
			"$(SRCDIR)/manifests/by-checksum" \
		| $(BIN_JQ) -cR . \
		| $(BIN_JQ) -cs .

.PHONY: mlist-checksum-diff
mlist-checksum-diff: in-srcdir
	$(if $(MLIST_A),,$(error MLIST_A must be set))
	$(if $(MLIST_B),,$(error MLIST_B must be set))
	$(BIN_GIT) \
			diff \
			--diff-filter=d \
			--name-only \
			--relative=manifests/by-checksum \
			"$(MLIST_A)" \
			"$(MLIST_B)" \
			-- \
			"./manifests/by-checksum" \
		| $(BIN_JQ) -cR . \
		| $(BIN_JQ) -cs .

.PHONY: mlist-msrc
mlist-msrc:
	$(if $(MSRC_TOKEN),,$(error MSRC_TOKEN must be set))
	$(BIN_CURL) \
			--get \
			--header "Accept: application/json" \
			--header "Authorization: Bearer $(MSRC_TOKEN)" \
			--silent \
			"https://$(MSRC_REGISTRY)/v2/$(MSRC_REPOSITORY)/$(MSRC_IMAGE)/tags/list" \
		| $(BIN_JQ) -c \
			'.["tags"] - ["docker-base-layer"]'

.PHONY: mlist-msrc-diff
mlist-msrc-diff:
	echo "$$($(MAKE_SILENT) mlist-checksum)" "$$($(MAKE_SILENT) mlist-msrc)" \
		| $(BIN_JQ) -cs '.[0] - .[1]'

#
# Manifest Generation
#
# Generate manifests in `./manifests/` from the MPP sources in
# `./src/manifests/`. This allows us to dynamically create manifests for
# testing purposes.
#

.PHONY: mpp
mpp: in-srcdir | $(BUILDDIR)/cache/
	./mdb.sh \
		--cache "$(BUILDDIR)/cache" \
		preprocess \
		--dstdir "$(SRCDIR)/manifests" \
		--srcdir "$(SRCDIR)/src/manifests" \
		.

#
# Manifest Verification
#
# The `verify-*` targets run basic sanity checks on all manifests in the
# database:
#
#   verify-diff:
#     Check that all files in the manifest database are committed. Usually,
#     this is run after regenerating manifests, and thus checking that all
#     content is committed properly.
#
#   verify-format:
#     Run `osbuild --inspect` on all (or selected) manifests, verifying that
#     the file-format is valid.
#
#   verify-type:
#     Check that files in `manifests/by-checksum/*` are proper files, and
#     anything else in `manifests/*` is either a directory or a symlink.
#

VERIFY_FORMAT = $(patsubst %,verify-format-%,$(MANIFEST_FILES))

$(VERIFY_FORMAT): verify-format-%: FORCE
	$(BIN_OSBUILD) \
		--inspect "$(SRCDIR)/manifests/by-checksum/$*" \
		>/dev/null

.PHONY: verify-diff
verify-diff: in-srcdir
	( \
		set -e ; \
		FOUND=$$( \
			$(BIN_GIT) status --porcelain -- ./manifests ; \
		) ; \
		if [[ ! -z $${FOUND} ]]; then \
			echo "Manifests not up-to-date:" ; \
			echo "$${FOUND}" ; \
			exit 1 ; \
		fi ; \
	)

.PHONY: verify-format
verify-format: $(VERIFY_FORMAT)

.PHONY: verify-type
verify-type:
	( \
		set -e ; \
		FOUND=$$( \
			$(BIN_FIND) \
				$(call FN_SRCDIR,manifests) \
					\( \
					-path "$(call FN_SRCDIR,manifests/by-checksum)/*" \
					-and \
					-not \( -type f -or -type d \) \
					-print \
					\) \
				-or \
					\( \
					-not -path "$(call FN_SRCDIR,manifests/by-checksum)/*" \
					-and \
					-not \( -type l -or -type d \) \
					-print \
					\) \
		) ; \
		if [[ ! -z $${FOUND} ]]; then \
			echo "Wrong manifest file-types:" ; \
			echo "$${FOUND}" ; \
			exit 1 ; \
		fi ; \
	)

#
# Push/Pull Manifest Sources
#
# Prefetch sources of a manifest, stash them into a docker image and upload
# it to the selected Docker Registry. We use this to save a working set of
# sources with our manifests, so we can reproduce them later on.
#
# The reverse operation finds the right docker image for a given manifest,
# downloads it, and extracts the sources.
#
# The images are tagged with the manifest-checksum.
#

MSRC_PREFETCH = $(patsubst %,msrc-prefetch-%,$(MANIFEST_FILES))
MSRC_PULL = $(patsubst %,msrc-pull-%,$(MANIFEST_FILES))
MSRC_PUSH = $(patsubst %,msrc-push-%,$(MANIFEST_FILES))
MSRC_WIPE = $(patsubst %,msrc-wipe-%,$(MANIFEST_FILES))

$(MSRC_PREFETCH): msrc-prefetch-%: FORCE in-srcdir | $(BUILDDIR)/msrc/%/sources/
	./mdb.sh \
		prefetch \
		--output "$(BUILDDIR)/msrc/$*/sources" \
		"$(SRCDIR)/manifests/by-checksum/$*"

$(MSRC_PULL): msrc-pull-%: FORCE | $(BUILDDIR)/msrc/%/sources/
	$(BIN_DOCKER) \
		pull \
		"$(MSRC_TRIPLE):$*"
	( \
		set -e ; \
		CID=$$($(BIN_DOCKER) \
			create \
			--rm \
			"$(MSRC_TRIPLE):$*" \
			/init \
		) ; \
		$(BIN_DOCKER) \
			cp \
			"$${CID}:/sources" \
			"$(BUILDDIR)/msrc/$*/" ; \
		$(BIN_DOCKER) container rm "$${CID}" ; \
	)
	$(BIN_DOCKER) \
		image \
		rm \
		"$(MSRC_TRIPLE):$*"

$(MSRC_PUSH): msrc-push-%: msrc-prefetch-% | $(BUILDDIR)/msrc/%/sources/
	$(BIN_TAR) \
			-c \
			-C "$(BUILDDIR)/msrc/$*" \
			"sources" \
		| $(BIN_DOCKER) \
			import \
			- \
			"$(MSRC_TRIPLE):$*"
	$(BIN_DOCKER) \
		push \
		"$(MSRC_TRIPLE):$*"
	$(BIN_DOCKER) \
		image \
		rm \
		"$(MSRC_TRIPLE):$*"

$(MSRC_WIPE): msrc-wipe-%: FORCE
	$(BIN_TAR) \
			-c \
			--files-from /dev/null \
		| $(BIN_DOCKER) \
			import \
			- \
			"$(MSRC_TRIPLE):$*"
	$(BIN_DOCKER) \
		push \
		"$(MSRC_TRIPLE):$*"
	$(BIN_DOCKER) \
		image \
		rm \
		"$(MSRC_TRIPLE):$*"

.PHONY: msrc-prefetch
msrc-prefetch:
	$(if $(MANIFEST),,$(error MANIFEST must be set))
	$(MAKE) msrc-prefetch-$(MANIFEST)

.PHONY: msrc-pull
msrc-pull:
	$(if $(MANIFEST),,$(error MANIFEST must be set))
	$(MAKE) msrc-pull-$(MANIFEST)

.PHONY: msrc-push
msrc-push:
	$(if $(MANIFEST),,$(error MANIFEST must be set))
	$(MAKE) msrc-push-$(MANIFEST)

.PHONY: msrc-wipe
msrc-wipe:
	$(if $(MANIFEST),,$(error MANIFEST must be set))
	$(MAKE) msrc-wipe-$(MANIFEST)

#
# Manifest Test
#
# WIP
#

MTEST_BUILD = $(patsubst %,mtest-build-%,$(MANIFEST_FILES))
MTEST_MSRC = $(patsubst %,mtest-msrc-%,$(MANIFEST_FILES))

$(MTEST_BUILD): mtest-build-%: FORCE | $(BUILDDIR)/mtest/%/output/ $(BUILDDIR)/mtest/%/store/
	$(BIN_OSBUILD) \
		--output-directory "$(BUILDDIR)/mtest/$*/output" \
		--store "$(BUILDDIR)/mtest/$*/store" \
		"$(SRCDIR)/manifests/by-checksum/$*"

$(MTEST_MSRC): mtest-msrc-%: FORCE | $(BUILDDIR)/mtest/%/store/
	$(BIN_CP) \
		--link \
		--recursive \
		-- \
		"$(BUILDDIR)/msrc/$*/sources" \
		"$(BUILDDIR)/mtest/$*/store/"

.PHONY: mtest-build
mtest-build:
	$(if $(MANIFEST),,$(error MANIFEST must be set))
	$(MAKE) mtest-build-$(MANIFEST)

#
# Distrepo Management
#
# WIP
#

DISTREPO_METALINK ?=
DISTREPO_MODULEID ?=
DISTREPO_OS ?=

$(BUILDDIR)/cache/distrepo/empty: | $(BUILDDIR)/cache/distrepo/
	$(BIN_TOUCH) "$@"

$(BUILDDIR)/distrepo/%/repo0/repodata/repomd.xml: \
		| $(BUILDDIR)/cache/distrepo/root/%/ \
		  $(BUILDDIR)/distrepo/%/repo0/ \
		  $(BUILDDIR)/distrepo/%/rpm/
	$(if $(DISTREPO_METALINK),,$(error DISTREPO_METALINK must be set))
	$(if $(DISTREPO_MODULEID),,$(error DISTREPO_MODULEID must be set))
	$(BIN_LN) -fs "../rpm" "$(BUILDDIR)/distrepo/$*/repo0/Packages"
	echo "[main]"                                    >"$(BUILDDIR)/cache/distrepo/dnf.$*.conf"
	echo "module_platform_id=$(DISTREPO_MODULEID)"  >>"$(BUILDDIR)/cache/distrepo/dnf.$*.conf"
	echo "[repo0]"                                  >>"$(BUILDDIR)/cache/distrepo/dnf.$*.conf"
	echo "name=repo0"                               >>"$(BUILDDIR)/cache/distrepo/dnf.$*.conf"
	echo "metalink=$(DISTREPO_METALINK)"            >>"$(BUILDDIR)/cache/distrepo/dnf.$*.conf"
	$(BIN_DNF) \
		-v \
		reposync \
			--config "$(BUILDDIR)/cache/distrepo/dnf.$*.conf" \
			--installroot "$(abspath $(BUILDDIR))/cache/distrepo/root/$*" \
			--setopt "fastestmirror=true" \
			--setopt "reposdir=" \
			--setopt "skip_if_unavailable=false" \
			\
			--download-metadata \
			--download-path "$(BUILDDIR)/distrepo/$*/"

$(BUILDDIR)/distrepo/%/hash: \
		$(BUILDDIR)/distrepo/%/repo0/repodata/repomd.xml \
		| $(BUILDDIR)/distrepo/%/repo/
	$(BIN_SHA256SUM) <"$<" | $(BIN_CUT) -d " " -f 1 >"$(@)v"
	$(BIN_LN) -fs "../repo0" "$(BUILDDIR)/distrepo/$*/repo/$*-$$(cat "$(@)v")"
	$(BIN_MV) "$(@)v" "$@"

$(BUILDDIR)/distrepo/%/metadata.s3sync: \
		$(BUILDDIR)/distrepo/%/hash
	$(if $(DISTREPO_OS),,$(error DISTREPO_OS must be set))
	echo "Synchronize metadata to S3..."
	$(BIN_S3CMD) \
		--acl-public \
		--follow-symlinks \
		sync \
			"$(BUILDDIR)/distrepo/$*/repo0/repodata/" \
			"s3://manifestdb/distrepo/$(DISTREPO_OS)/repo/$*-$$(cat '$(BUILDDIR)/distrepo/$*/hash')/repodata/"
	$(BIN_S3CMD) --acl-public put "$<" "s3://manifestdb/distrepo/$(DISTREPO_OS)/repo/$*-$$(cat '$(BUILDDIR)/distrepo/$*/hash')/metadata.s3sync"
	$(BIN_CAT) <"$(BUILDDIR)/distrepo/$*/hash" >"$@"

$(BUILDDIR)/distrepo/%/pkglink.s3sync: \
		$(BUILDDIR)/cache/distrepo/empty \
		$(BUILDDIR)/distrepo/%/hash
	$(if $(DISTREPO_OS),,$(error DISTREPO_OS must be set))
	echo "Synchronize package-links to S3..."
	$(BIN_FIND) \
			"$(BUILDDIR)/distrepo/$*/repo0/Packages" \
			-type f \
			-printf "%P\0" \
		| $(BIN_XARGS) \
			"-I{}" \
			--null \
			$(BIN_S3CMD) \
				--acl-public \
				--add-header="x-amz-website-redirect-location:/distrepo/$(DISTREPO_OS)/rpm/{}" \
				put \
					"$(BUILDDIR)/cache/distrepo/empty" \
					"s3://manifestdb/distrepo/$(DISTREPO_OS)/repo/$*-$$(cat '$(BUILDDIR)/distrepo/$*/hash')/Packages/{}"
	$(BIN_S3CMD) --acl-public put "$<" "s3://manifestdb/distrepo/$(DISTREPO_OS)/repo/$*-$$(cat '$(BUILDDIR)/distrepo/$*/hash')/pkglink.s3sync"
	$(BIN_CAT) <"$(BUILDDIR)/distrepo/$*/hash" >"$@"

$(BUILDDIR)/distrepo/%/pkgrpm.s3sync: \
		$(BUILDDIR)/distrepo/%/hash
	$(if $(DISTREPO_OS),,$(error DISTREPO_OS must be set))
	echo "Synchronize package-rpms to S3..."
	$(BIN_S3CMD) \
		--acl-public \
		sync \
			"$(BUILDDIR)/distrepo/$*/repo0/Packages/" \
			"s3://manifestdb/distrepo/$(DISTREPO_OS)/rpm/"
	$(BIN_S3CMD) --acl-public put "$<" "s3://manifestdb/distrepo/$(DISTREPO_OS)/repo/$*-$$(cat '$(BUILDDIR)/distrepo/$*/hash')/pkgrpm.s3sync"
	$(BIN_CAT) <"$(BUILDDIR)/distrepo/$*/hash" >"$@"
