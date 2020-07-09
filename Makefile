#
# Repository Maintenance
#

SHELL = /bin/bash

BUILDDIR ?= .
SRCDIR ?= .

BIN_CURL ?= curl
BIN_DOCKER ?= docker
BIN_FIND ?= find
BIN_GIT ?= git
BIN_JQ ?= jq
BIN_LS ?= ls
BIN_OSBUILD ?= osbuild
BIN_PYTHON3 ?= python3
BIN_TAR ?= tar

FN_BUILDDIR = $(patsubst ./%,%,$(BUILDDIR)/$(1))
FN_SRCDIR = $(patsubst ./%,%,$(SRCDIR)/$(1))

MAKE_SILENT = $(MAKE) --no-print-directory --silent

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

.PHONY: help
help:
	@echo "make [TARGETS...]"
	@echo
	@echo "This is the maintenance makefile of manifestdb. The following"
	@echo "targets are available:"
	@echo
	@echo "    help:               Print this usage information."

$(BUILDDIR)/:
	mkdir -p "$@"

$(BUILDDIR)/%/:
	mkdir -p "$@"

FORCE:

#
# Manifest Generation
#
# Generate manifests in `./manifests/` from the MPP sources in
# `./src/manifests/`. This allows us to dynamically create manifests for
# testing purposes.
#
# Note that we always commit all generated manifests. Therefore, another
# target is provided that verifies re-generating them does not create any
# uncommitted content.
#

.PHONY: mpp-generate
mpp-generate: | $(BUILDDIR)/cache/
	( \
		set -e ; \
		./mdb.sh \
			--cache "$(BUILDDIR)/cache" \
			preprocess \
			--dstdir "./manifests" \
			--srcdir "./src/manifests" \
			. ; \
	)

.PHONY: mpp-verify
mpp-verify: mpp-generate
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

#
# Verify Manifest Filetypes
#
# The `mtype-verify` command checks all files and directories in `./manifests/`
# and verifies files outside of `by-checksum` must be symlinks. We only allow
# manifests inserted by their checksum, every other index must be a reference.
#

.PHONY: mtype-verify
mtype-verify:
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
# Verify Manifest Formatting
#
# Run `osbuild --inspect` on all manifests under `./manifests/by-checksum/`
# and thus verify that they are valid manifests.
#

MFORMAT_MANIFESTS = $(wildcard $(SRCDIR)/manifests/by-checksum/*)
MFORMAT_TARGETS = $(patsubst %,mformat-%,$(MFORMAT_MANIFESTS))

$(MFORMAT_TARGETS): mformat-%: FORCE
	$(BIN_OSBUILD) \
		--inspect "$*" \
		>/dev/null

.PHONY: mformat-verify
mformat-verify: $(MFORMAT_TARGETS)

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
# The `msrc-list` helper target lists all tags from the remote registry. It
# is meant for checking which sources already exist. The `msrc-list-diff`
# target takes this list and subtracts it from the list of `mlist`, thus
# showing all manifests that lack a source image.
#

MSRC_IMAGE ?= sources
MSRC_REGISTRY ?= docker.pkg.github.com
MSRC_REPOSITORY ?= osbuild/manifestdb
MSRC_TRIPLE = $(MSRC_REGISTRY)/$(MSRC_REPOSITORY)/$(MSRC_IMAGE)

MSRC_MANIFESTS = $(wildcard $(SRCDIR)/manifests/by-checksum/*)
MSRC_PULL = $(patsubst %,msrc-pull-%,$(MSRC_MANIFESTS))
MSRC_PUSH = $(patsubst %,msrc-push-%,$(MSRC_MANIFESTS))

$(MSRC_PULL): msrc-pull-$(SRCDIR)/manifests/by-checksum/%: FORCE | $(BUILDDIR)/msrc/%/sources/
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

$(MSRC_PUSH): msrc-push-$(SRCDIR)/manifests/by-checksum/%: FORCE | $(BUILDDIR)/msrc/%/sources/
	./mdb.sh \
		prefetch \
		--output "$(BUILDDIR)/msrc/$*/sources" \
		"$(SRCDIR)/manifests/by-checksum/$*"
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

.PHONY: msrc-list
msrc-list:
	$(if $(MSRC_TOKEN),,$(error MSRC_TOKEN must be set))
	$(BIN_CURL) \
			--get \
			--header "Accept: application/json" \
			--header "Authorization: Bearer $(MSRC_TOKEN)" \
			--silent \
			"https://$(MSRC_REGISTRY)/v2/$(MSRC_REPOSITORY)/$(MSRC_IMAGE)/tags/list" \
		| $(BIN_JQ) -c \
			'.["tags"] - ["docker-base-layer"]'

.PHONY: msrc-list-diff
msrc-list-diff:
	echo "$$($(MAKE_SILENT) mlist)" "$$($(MAKE_SILENT) msrc-list)" \
		| $(BIN_JQ) -cs '.[0] - .[1]'

.PHONY: msrc-pull
msrc-pull:
	$(if $(MSRC_MANIFEST),,$(error MSRC_MANIFEST must be set))
	$(MAKE) msrc-pull-$(SRCDIR)/manifests/$(MSRC_MANIFEST)

.PHONY: msrc-push
msrc-push:
	$(if $(MSRC_MANIFEST),,$(error MSRC_MANIFEST must be set))
	$(MAKE) msrc-push-$(SRCDIR)/manifests/$(MSRC_MANIFEST)

#
# Manifest List
#
# List all manifests by their checksum. This simply turns the directory listing
# from `./manifests/by-checksum/` into a JSON array.
#

.PHONY: mlist
mlist:
	$(BIN_LS) \
			-1b \
			"$(SRCDIR)/manifests/by-checksum" \
		| $(BIN_JQ) -cR . \
		| $(BIN_JQ) -cs .
