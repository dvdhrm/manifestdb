manifestdb
==========

OSBuild Manifest Database

The OSBuild Manifest Database is a collection of manifests for the `osbuild(1)`
pipeline execution engine. The database contains manifests indexed by their
checksum as well as custom tags to allow easy and fast lookups. Furthermore,
the database provides consistency checks for all stored manifests, optionally
extended with further custom tests to catch possible regressions whenever the
osbuild engine is updated.

### Project

 * **Website**: <https://www.osbuild.org>
 * **Bug Tracker**: <https://github.com/osbuild/manifestdb/issues>

### Requirements

The requirements for this project are:

 * `python >= 3.7`
 * `osbuild >= 16`

### Repository:

 - **web**:   <https://github.com/osbuild/manifestdb>
 - **https**: `https://github.com/osbuild/manifestdb.git`
 - **ssh**:   `git@github.com:osbuild/manifestdb.git`

### License:

 - **Apache-2.0**
 - See LICENSE file for details.
