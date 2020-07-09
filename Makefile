#
# Repository Maintenance
#

SHELL = /bin/bash

BUILDDIR ?= .
SRCDIR ?= .

BIN_FIND ?= find
BIN_OSBUILD ?= osbuild
BIN_PYTHON3 ?= python3

FN_BUILDDIR = $(patsubst ./%,%,$(BUILDDIR)/$(1))
FN_SRCDIR = $(patsubst ./%,%,$(SRCDIR)/$(1))

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
mpp-generate:
	( \
		set -e ; \
		./mdb.sh \
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
