#!/bin/bash
#
# ClickHouse DBMS build script for RHEL based distributions
#
# Important notes:
#  - build requires ~35 GB of disk space
#  - each build thread requires 2 GB of RAM - for example, if you
#    have dual-core CPU with 4 threads you need 8 GB of RAM
#  - build user needs to have sudo priviledges, preferrably with NOPASSWD
#
# Tested on:
#  - CentOS 6: 6.9 6.10
#  - CentOS 7: 7.4, 7.5
#
# Copyright (C) 2016 Red Soft LLC
# Copyright (C) 2017 Altinity Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Git repository of Clickhouse
CH_REPO="${CH_REPO:-https://github.com/ClickHouse/ClickHouse}"

# Git version of ClickHouse that we package
CH_VERSION="${CH_VERSION:-21.1.7.1}"

# Fill if some commits need to be cherry-picked before build
#CH_EXTRA_COMMITS=( 54a5b801b708701b1ddbda95887465b9f7ae5740 )
CH_EXTRA_COMMITS=()

# Git tag marker (stable/testing)
#CH_TAG="${CH_TAG:-lts}"
CH_TAG="${CH_TAG:-stable}"
#CH_TAG="${CH_TAG:-testing}"

# Hostname of the server used to publish packages
SSH_REPO_SERVER="${SSH_REPO_SERVER:-10.81.1.162}"

# SSH username used to publish packages
SSH_REPO_USER="${SSH_REPO_USER:-clickhouse}"

# Root directory for repositories on the server used to publish packages
SSH_REPO_ROOT="${SSH_REPO_ROOT:-/var/www/html/repos/clickhouse}"

# Current work dir
CWD_DIR="$(pwd)"

# This script location dir
MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# Base dir where ClickHouse sources are expected to be located
# This is crucial when we are building from sources and 
# are standing inside sources tree
CH_SRC_ROOT_DIR=$(readlink -e "$MY_DIR"/..)

# Docker build context root dir
DOCKER_CONTEXT_ROOT_DIR="$MY_DIR"

# Source files dir - relative to this script
SRC_DIR="$MY_DIR/src"

# Where RPMs would be built - relative to CWD - makes possible to build in whatever folder needed
RPMBUILD_ROOT_DIR="$CWD_DIR/rpmbuild"

# What version of devtoolset would be used
DEVTOOLSET_VERSION="9"

# Detect number of threads to run 'make' command
export THREADS=$(grep -c ^processor /proc/cpuinfo)

# Should ninja-build be used
#export USE_NINJA_BUILD="true"
export USE_NINJA_BUILD=""

# Source libraries
. "${SRC_DIR}"/os.lib.sh
. "${SRC_DIR}"/publish_packagecloud.lib.sh
. "${SRC_DIR}"/publish_ssh.lib.sh
. "${SRC_DIR}"/util.lib.sh

##
##
##
function set_rpmbuild_dirs()
{
	# Where RPMs would be built
	RPMBUILD_ROOT_DIR=$1

	# Where build process will be run
	BUILD_DIR="$RPMBUILD_ROOT_DIR/BUILD"

	# Where built binaries will be installed for packaging
	BUILDROOT_DIR="$RPMBUILD_ROOT_DIR/BUILDROOT"

	# Where build RPM files would be kept
	RPMS_DIR="$RPMBUILD_ROOT_DIR/RPMS/x86_64"

	# Where source files would be kept
	SOURCES_DIR="$RPMBUILD_ROOT_DIR/SOURCES"

	# Where RPM spec file would be kept
	SPECS_DIR="$RPMBUILD_ROOT_DIR/SPECS"

	# Where built SRPM files would be kept
	SRPMS_DIR="$RPMBUILD_ROOT_DIR/SRPMS"

	# Where temp files would be kept
	TMP_DIR="$RPMBUILD_ROOT_DIR/TMP"

	export BUILD_DIR
	export BUILDROOT_DIR
	export SOURCES_DIR
}

##
##
##
function check_sudo()
{
	if sudo --version > /dev/null; then
		echo "sudo available, continue"
	else
		echo "sudo is not available, try to install it"
		yum install -y sudo

		# Recheck sudo again
		if sudo --version > /dev/null; then
			echo "sudo available, continue"
		else
			echo "sudo is not available, can not continue"
			echo "Install sudo and start again"
			echo "Exit"
			
			exit 1
		fi
	fi
}

##
##
##
function install_general_dependencies()
{
	banner "Install general dependencies"
	check_sudo
	sudo yum install -y git wget curl zip unzip sed
}

##
##
##
function install_rpm_dependencies()
{
        banner "RPM build dependencies"
	check_sudo
	sudo yum install -y rpm-build redhat-rpm-config createrepo
}

##
##
##
function install_build_process_dependencies()
{
	banner "Install build tools"

	check_sudo
	sudo yum install -y make

	if os_centos; then
		sudo yum install -y epel-release
		sudo yum install -y cmake3
		if [ ! -z $USE_NINJA_BUILD ]; then
			# use ninja-build
			sudo yum install -y ninja-build
		fi

		sudo yum install -y centos-release-scl
		sudo yum install -y devtoolset-"${DEVTOOLSET_VERSION}"
	elif os_ol; then
		sudo yum install -y scl-utils
		sudo yum install -y devtoolset-"${DEVTOOLSET_VERSION}"
		sudo yum install -y cmake3
	else
		# fedora
		sudo yum install -y gcc-c++ libstdc++-static cmake
	fi

	banner "Install CH dev dependencies"

	# libicu-devel -  ICU (support for collations and charset conversion functions
	# libtool-ltdl-devel - cooperate with dynamic libs
	sudo yum install -y openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel
	#sudo yum install -y zlib-devel openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel
}

##
##
##
function install_workarounds()
{
	banner "Install workarounds"

	check_sudo

	# Now all workarounds are included into CMAKE_OPTIONS and MAKE_OPTIONS
}

##
## Install all required components before building RPMs
##
function install_dependencies()
{
	banner "Install dependencies"

	check_sudo

	install_general_dependencies
	install_rpm_dependencies
	install_build_process_dependencies

	install_workarounds
}

##
##
##
function install_docker()
{
	check_sudo

	sudo yum install -y yum-utils device-mapper-persistent-data lvm2
	sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
	sudo yum install -y docker-ce
	sudo systemctl start docker

	# Verify that docker is installed correctly by running the hello-world image.
	sudo docker run hello-world
}

##
##
##
function install_clickhouse_test_deps()
{
	check_sudo

	# Install dependencies required by clickhouse-test
	sudo yum install -y epel-release
	sudo yum install -y python-lxml
	sudo yum install -y python-requests
	sudo yum install -y python2-pip
	sudo pip install termcolor

	# Install dependencies required by test scripts to be run by clickhouse-test
	sudo yum install -y perl
	sudo yum install -y telnet
}

##
## Prepare $RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG.zip file
##
function prepare_sources()
{
	download_sources
	zip_sources
}

##
## Download sources into $RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG folder
##
function download_sources()
{
	banner "Ensure SOURCES dir is in place"
	mkdirs

	echo "Clean sources dir as rm -rf '$SOURCES_DIR/ClickHouse*'"
	rm -rf "$SOURCES_DIR"/ClickHouse*

	echo "Download sources"
	echo "Clone from github v${CH_VERSION}-${CH_TAG} into $SOURCES_DIR/ClickHouse-${CH_VERSION}-${CH_TAG}"

	cd "$SOURCES_DIR"

	# Go older way because older versions of git (CentOS 6.9, for example) do not understand new syntax of branches etc
	# Clone specified branch with all submodules into $SOURCES_DIR/ClickHouse-$CH_VERSION-$CH_TAG folder
	echo "Clone ClickHouse repo"
	git clone "${CH_REPO}" "ClickHouse-${CH_VERSION}-${CH_TAG}"

	cd "ClickHouse-${CH_VERSION}-${CH_TAG}"

	echo "Checkout specific tag v${CH_VERSION}-${CH_TAG}"
	git checkout "v${CH_VERSION}-${CH_TAG}"

	for commit in "${CH_EXTRA_COMMITS[@]}"; do
		echo "Cherry-pick commit $commit"
		git cherry-pick $commit
	done

	echo "Update submodules"
	git submodule update --init --recursive

	echo "Sources downloaded"
}

##
## Copy or move (depend on options) sources into .zip 
## $RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG.zip
##
function zip_sources()
{
	cd "$SOURCES_DIR"

#	echo "Move files into .zip with minimal compression"
#	zip -r0mq "ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "ClickHouse-${CH_VERSION}-${CH_TAG}"

	echo "Copy files into .zip with minimal compression"
	zip -r0q "ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "ClickHouse-${CH_VERSION}-${CH_TAG}"

	echo "Ensure .zip file is available"
	ls -l "ClickHouse-${CH_VERSION}-${CH_TAG}.zip"

	cd "$CWD_DIR"
}

##
##
##
function build_spec_file()
{
	banner "Ensure SPECS dir is in place"
	mkdirs

	banner "Build .spec file"

	if os_centos_6; then
		echo "CentOS 6 has some special CMAKE_OPTIONS"
		# jemalloc should build as long as the Linux kernel version is >= 2.6.38, otherwise it needs to be disabled.
		# MADV_HUGEPAGE compilation error encounters
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DENABLE_JEMALLOC=0"
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DGLIBC_COMPATIBILITY=0"
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DENABLE_RDKAFKA=0"
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DNO_WERROR=1"
	fi

	if os_centos_7; then
		echo "CentOS 7 has some special CMAKE_OPTIONS"
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DGLIBC_COMPATIBILITY=OFF"
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DNO_WERROR=1"
		# Starting with v20.3 there is new option to tolerate warnings
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DWERROR=0"
	fi

	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DHAVE_THREE_PARAM_SCHED_SETAFFINITY=1"
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DOPENSSL_SSL_LIBRARY=/usr/lib64/libssl.so -DOPENSSL_CRYPTO_LIBRARY=/usr/lib64/libcrypto.so -DOPENSSL_INCLUDE_DIR=/usr/include/openssl"
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DNO_WERROR=1"
	#CMAKE_OPTIONS="${CMAKE_OPTIONS} -DUSE_INTERNAL_ZLIB_LIBRARY=0"
		  
	MAKE_OPTIONS="${MAKE_OPTIONS}"

	# Create spec file from template
	cat "$SRC_DIR/clickhouse.spec.in" | sed \
		-e "s|@CH_VERSION@|$CH_VERSION|" \
		-e "s|@CH_TAG@|$CH_TAG|" \
		-e "s|@CMAKE_OPTIONS@|$CMAKE_OPTIONS|" \
		-e "s|@MAKE_OPTIONS@|$MAKE_OPTIONS|" \
		-e "/@CLICKHOUSE_SPEC_FUNCS_SH@/ { 
r $SRC_DIR/clickhouse.spec.funcs.sh
d }" \
		> "$SPECS_DIR/clickhouse.spec"

	banner "Looking for .spec file"
	ls -l "$SPECS_DIR/clickhouse.spec"
}


##
## Build RPMs
##
function build_RPMs()
{
	banner "Ensure build dirs are in place"
	mkdirs

	banner "Setup RPM Macros"
	echo '%_topdir '"$RPMBUILD_ROOT_DIR"'
%_tmppath '"$TMP_DIR"'
%_smp_mflags -j'"$THREADS" > ~/.rpmmacros
	if [ "${FLAG_DEBUGINFO}" == "no" ]; then
		echo "%debug_package %{nil}" >> ~/.rpmmacros

	fi


	banner "Setup path to compilers"
	if os_centos || os_ol; then
		export CMAKE="cmake3"
		export CC="/opt/rh/devtoolset-${DEVTOOLSET_VERSION}/root/usr/bin/gcc"
		export CXX="/opt/rh/devtoolset-${DEVTOOLSET_VERSION}/root/usr/bin/g++"
		#export CXXFLAGS="${CXXFLAGS} -Wno-maybe-uninitialized"
	else
		export CMAKE=cmake
		export CC=gcc
		export CXX=g++
	fi

	echo "CMAKE=$CMAKE"
	echo "CC=$CC"
	echo "CXX=$CXX"

	echo "cd into $CWD_DIR"
	cd "$CWD_DIR"

	banner "Build RPMs"

	banner "Build SRPMs"
	if rpmbuild -v -bs "$SPECS_DIR/clickhouse.spec"; then
		echo "SRPMs build completed"
	else
		banner "SRPMs build FAILED"
	fi
	
	
	banner "Build RPMs"
	if rpmbuild -v -bb "$SPECS_DIR/clickhouse.spec"; then
		echo "RPMs build completed"
	else
		banner "RPMs build FAILED. Can not continue"
		exit 1
	fi

	banner "Build RPMs completed"

	# Display results
	list_RPMs
	list_SRPMs
}

##
## Build packages:
## 1. clean folders
## 2. prepare sources
## 3. build spec file
## 4. build RPMs
##
function build_packages()
{
	banner "Ensure build dirs are in place"
	mkdirs
	
	# Prepare $SOURCES_DIR/ClickHouse-$CH_VERSION-$CH_TAG.zip file
	prepare_sources

	echo "Clean up spec from previous run"
	rm -f "$SPECS_DIR"/clickhouse.spec

	# Build $SPECS_DIR/clickhouse.spec file
	build_spec_file
 
	echo "Clean up .rpm and .srpm from previous run"
	rm -f "$RPMS_DIR"/clickhouse*
	rm -f "$SRPMS_DIR"/clickhouse*

	banner "Build RPM packages"
	# Compile sources and build RPMS
	build_RPMs
}

##
##
##
function setup_local_build_dirs()
{
	# Check whether ClickHouse source dir exists
	if ! cd $CH_SRC_ROOT_DIR 2>/dev/null; then
		echo "Are we inside ClickHouse sources?"
		exit 1
	fi
	cd "$CWD_DIR"

	DOCKER_CONTEXT_ROOT_DIR="${CH_SRC_ROOT_DIR}/build"

	set_rpmbuild_dirs "${CH_SRC_ROOT_DIR}/build/rpmbuild"
}

##
##
##
function setup_local_build()
{
	setup_local_build_dirs

	# Try to extract CH version specification from sources
	# In case we can extract version spec this means we are inside CH sources
	# in case we are unable to extract version spec there is no reason to continue build

	# For v18.14.13-stable

	# Ex.: 54409
	VERSION_REVISION=$(grep "set(VERSION_REVISION" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_REVISION \(.*\)$/\1/' | sed 's/[) ].*//')

	# Ex.: 18 for v18.14.13-stable
	VERSION_MAJOR=$(grep "set(VERSION_MAJOR" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_MAJOR \(.*\)/\1/' | sed 's/[) ].*//')

	# Ex.:14 for v18.14.13-stable
	VERSION_MINOR=$(grep "set(VERSION_MINOR" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_MINOR \(.*\)/\1/' | sed 's/[) ].*//')

	# Ex.:13 for v18.14.13-stable
	VERSION_PATCH=$(grep "set(VERSION_PATCH" ${CH_SRC_ROOT_DIR}/dbms/cmake/version.cmake | sed 's/^.*VERSION_PATCH \(.*\)/\1/' | sed 's/[) ].*//')

	echo "Extracting from src: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH} rev:$VERSION_REVISION"

	if [ -z "$VERSION_MAJOR" ] || [ -z "$VERSION_MINOR" ] || [ -z "$VERSION_PATCH" ]; then
		echo "Are we inside ClickHouse sources?"
		exit 1
	fi

	# Looks like we are inside ClickHouse sources
	# We need to extract "stable" or "testing" tag/suffix to name RPMs

	# May be we are standing directly on tagged commit is git
	# Let's check this theory
	# Ex.: v18.14.13-stable
	GIT_TAG=$(cd "$CH_SRC_ROOT_DIR" && git describe --tags && cd "$CWD_DIR")
	echo "Extracting from git: $GIT_TAG"

	if [ -z "GIT_TAG" ]; then
		echo "Are those ClickHouse sources tagged?"
		exit 1
	fi

	# Extract "stable" or "testing" from git tag, which is expected to be like "v18.14.13-stable"
	# Extract everything after the first '-' in extracted git tag
	TAG=$(echo $GIT_TAG | awk -F: '{st = index($0, "-"); print substr($0, st+1)}')

	if [ -z "TAG" ]; then
		# TAG has to be specified. Expecting "stable" or "testing"
		echo "Can not recognize CH tag $TAG"
		exit 1
	fi

	# Extract version from git tag
	# Expected result v18.14.13
	# Extract everything before the first '-' in extracted git tag
	VER=$(echo $GIT_TAG | awk 'BEGIN {FS="-"}{print $1}')

	if [ "${FLAG_NO_VERSION_CHECK}" ]; then
		# Do not validate version, e.g. for master or PR builds.
		echo "Version: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}-${TAG}"
	elif [ "v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}" == "${VER}" ]; then
		# Version looks good
		echo "Version parsed: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}-${TAG}"
	else
		set +x
		echo "Tag (git describe --tags) is not equal version extracted from sources"
		echo "git describe --tags reported ${GIT_TAG}"
		echo "Version extracted from git tag is: ${VER}"
		echo "Version extracted from sources is: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
		echo "${VER} != v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
		echo "Do not know how to name result RPM"
		echo "Most likely you'd like to checkout specific tag in repo, like:"
		echo "git checkout v18.14.17-testing"
		echo "and start RPM build process again, so we'd know exactly how to name RPMs"
		echo "Exiting"
		exit 1
	fi

	CH_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
	CH_TAG="${TAG}"

	# Ensure build dirs are in place
	mkdirs

	# Build archive of CH sources in SOURCES

	# Figure out, how current dir is called. Fetch last entry in dir path
	# Ex.: fetch 'clickhouse' out of '/home/user/src/clickhouse'
	CH_SRC_ROOT_DIR_SHORT=${CH_SRC_ROOT_DIR##*/}

	# How link should be named - the same as .zip file should be called
	CH_SRC_ROOT_DIR_LINK="ClickHouse-${CH_VERSION}-${CH_TAG}"

	# Step one level up of current sources and make link to current sources dir
	cd ${CH_SRC_ROOT_DIR}/..
	ln -s ${CH_SRC_ROOT_DIR_SHORT} ${CH_SRC_ROOT_DIR_LINK}

	# Archive current sources dir via symlink - thus archive would
	# contain ClickHouse-18.14.13-stable folder in ClickHouse-18.14.13-stable.zip file
	# and do not include 'build' folder into archive
	rm -f "${SOURCES_DIR}/ClickHouse-${CH_VERSION}-${CH_TAG}.zip"
	zip -r0q "${SOURCES_DIR}/ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "${CH_SRC_ROOT_DIR_LINK}" -x "${CH_SRC_ROOT_DIR_LINK}/build/*"

	# Now we have .zip file in rpmbuild/SOURCES folder ready
	# Remove unused symlink - check whether it is a symlink and remove it
	cd ${CH_SRC_ROOT_DIR}/..
	[ -L ${CH_SRC_ROOT_DIR_LINK} ] && rm ${CH_SRC_ROOT_DIR_LINK}

	cd "${CWD_DIR}"
}

##
##
##
function run_test_docker()
{
	set -x
	if ! command -v docker; then
		echo "Docker is not available. Can not continue"
		exit 1
	fi

	mkdir -p $TMP_DIR

	cd $DOCKER_CONTEXT_ROOT_DIR
	if [ "$MY_DIR" != "$DOCKER_CONTEXT_ROOT_DIR" ]; then
		cp "$MY_DIR"/Dockerfile   "$DOCKER_CONTEXT_ROOT_DIR"/
		cp "$MY_DIR"/runscript.sh "$DOCKER_CONTEXT_ROOT_DIR"/
		chmod a+x "$DOCKER_CONTEXT_ROOT_DIR"/runscript.sh
	fi

	IMAGE_NAME="clickhouse_test_$(date +%s)"

	banner "Building Docker image ${IMAGE_NAME}"
	sudo docker build -t "$IMAGE_NAME" .

	banner "Running Docker image ${IMAGE_NAME}"
	#sudo docker run -it --mount src="$(pwd)",target=/clickhouse/result,type=bind $IMAGE_NAME
	sudo docker run --mount src="$TMP_DIR",target=/clickhouse/result,type=bind -e CH_TEST_NAMES="$CH_TEST_NAMES" $IMAGE_NAME

	cd $CWD_DIR
	
	banner "Test results"
	tail $TMP_DIR/out.txt
	tail $TMP_DIR/out.code.txt
		
	echo "Test result files availbale at $TMP_DIR"
	ls -l $TMP_DIR
}

##
##
##
function usage()
{
	# disable commands print
	set +x

	echo "Usage:"
	echo
	echo "./builder version"
	echo "		display default version to build"
	echo
	echo "./builder all [--debuginfo=no] [--cmake-build-type=Debug]"
	echo "		install build deps, download sources, build RPMs"
	echo "./builder all --test [--debuginfo=no]"
	echo "		install build+test deps, download sources, build+test and test RPMs"
	echo
	echo "./builder install --build-deps"
	echo "		install build dependencies"
	echo "./builder install --test-deps"
	echo "		install test dependencies"
	echo "./builder install --deps"
	echo "		install all dependencies (both build and test)"
	echo "./builder install --rpms [--from-sources]"
	echo "		install RPMs, if available (do not build RPMs)"
	echo
	echo "./builder build --spec"
	echo "		just create SPEC file"
	echo "		do not download sources, do not build RPMs"
	echo "./builder build --rpms [--debuginfo=no] [--cmake-build-type=Debug] [--test] [--no-version-check]"
	echo "		download sources, build SPEC file, build RPMs"
	echo "		do not install dependencies"
	echo "./builder build --download-sources"
	echo "		just download sources into \$RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-\$CH_VERSION-\$CH_TAG folder"
	echo "		(do not create SPEC file, do not install dependencies, do not build)"
	echo "./builder build --rpms --from-sources-in-BUILD-dir [--debuginfo=no] [--cmake-build-type=Debug] [--test]"
	echo "		just build RPMs from unpacked sources - most likely you have modified them"
	echo "		sources are in \$RPMBUILD_ROOT_DIR/BUILD/ClickHouse-\$CH_VERSION-\$CH_TAG folder"
	echo "		(do not download sources, do not create SPEC file, do not install dependencies)"
	echo "./builder build --rpms --from-sources-in-SOURCES-dir [--debuginfo=no] [--cmake-build-type=Debug] [--test]"
	echo "		just build RPMs from unpacked sources - most likely you have modified them"
	echo "		sources are in \$RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-\$CH_VERSION-\$CH_TAG folder"
	echo "		(do not download sources, do not create SPEC file, do not install dependencies)"
	echo "./builder build --rpms --from-archive [--debuginfo=no] [--cmake-build-type=Debug] [--test]"
	echo "		just build RPMs from \$RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-\$CH_VERSION-\$CH_TAG folder.zip sources"
	echo "		(do not download sources, do not create SPEC file, do not install dependencies)"
	echo "./builder build --rpms --from-sources [--debuginfo=no] [--cmake-build-type=Debug] [--test]"
	echo "		build from source codes"
	echo
	echo "./builder test --docker [--from-sources]"
	echo "		build Docker image and install produced RPM files in it. Run clickhouse-test"
	echo "./builder test --local"
	echo "		install required dependencies and run clickhouse-test on locally installed ClickHouse"
	echo "./builder test --local-sql"
	echo "		run several SQL queries on locally installed ClickHouse"
	echo
	echo "./builder repo --publish --packagecloud=<packagecloud USER ID> [FILE 1] [FILE 2] [FILE N]"
	echo "		publish packages on packagecloud as USER. In case no files(s) provided, rpmbuild/RPMS/x86_64/*.rpm would be used"
	echo "./builder repo --delete  --packagecloud=<packagecloud USER ID> file1_URL [file2_URL ...]"
	echo "		delete packages (specified as URL to file) on packagecloud as USER"
	echo "		URL to file to be deleted can be copy+pasted from packagecloud.io site and is expected as:"
	echo "		https://packagecloud.io/Altinity/clickhouse/packages/el/7/clickhouse-test-19.4.3.1-1.el7.x86_64.rpm"
	echo ""
	echo "		OS=centos DISTR_MAJOR=7 DISTR_MINOR=5 ./builder repo --publish --packagecloud=XYZ [file(s)]"
	echo "		OS=centos DISTR_MAJOR=7 DISTR_MINOR=5 ./builder repo --publish --path=altinity/clickhouse-altinity-stable --packagecloud=XYZ [file(s)]"
	echo "		./builder repo --delete URL1 URL2 URL3"
	echo "./builder repo --download [--path=altinity/clickhouse-altinity-stable] <VERSION>"

	echo
	echo "./builder list --rpms"
	echo "		list available RPMs"
	echo
	echo "./builder src --download"
	echo "		just download sources"

	# This should probably be moved to --help someday
	echo "Tests launched in Docker honor CH_TEST_NAMES env var which is a regexp to choose what tests to run"
	echo "CH_TEST_NAMES='^(?!00700_decimal_math).*$' in case you'd like to skip problematic decimal math test"
	echo "It is actulally run as clickhouse-test "\$CH_TEST_NAMES" so check for more info with clickhouse-test"
	echo "This env var is recognized by: './builder all --test' and './builder test --docker'"
}

if [ -z "$1" ]; then
	usage
	exit 0
fi

#OPTIONS=$(getopt -o brg --long color:: -- "$@")
# ./getopt.sh before1 --colo -brg after1
# $OPTIONS= --color '' -b -r -g -- 'before1' 'after1'
# opt1=--color
# opt2=
# opt3=-b
# opt4=-r
# opt5=-g
# opt6=--
# opt7=before1
# opt8=after1

# Arg flags
FLAG_TEST=''
FLAG_BUILD_DEPS=''
FLAG_TEST_DEPS=''
FLAG_DEPS=''
FLAG_RPMS=''
FLAG_SPEC=''
FLAG_DOWNLOAD_SOURCES=''
FLAG_FROM_SOURCES_IN_BUILD_DIR=''
FLAG_FROM_SOURCES_IN_SOURCES_DIR=''
FLAG_FROM_ARCHIVE=''
FLAG_FROM_SOURCES=''
FLAG_DEBUGINFO='yes'
FLAG_CMAKE_BUILD_TYPE=''
FLAG_DOCKER=''
FLAG_LOCAL=''
FLAG_LOCAL_SQL=''
FLAG_PUBLISH=''
FLAG_PATH='altinity/clickhouse'
FLAG_PACKAGECLOUD=''
FLAG_DELETE=''
FLAG_DOWNLOAD=''
FLAG_NO_VERSION_CHECK=''

OPTIONS=$(getopt -o ''  --longoptions \
test,\
build-deps,\
test-deps,\
deps,\
rpms,\
spec,\
download-sources,\
from-sources-in-BUILD-dir,\
from-sources-in-SOURCES-dir,\
from-archive,\
from-sources,\
debuginfo:,\
cmake-build-type:,\
docker,\
local,\
local-sql,\
publish,\
path:,\
packagecloud:,\
delete,\
download,\
no-version-check\
	-- "$@")

#echo "OPTIONS=$OPTIONS"
# Verify provided options
RET=$?
[ $RET -eq 0 ] || { 
	echo "Incorrect options provided"
	usage
	exit 1
}

# Apply normalized options back as agrs, so we'll be able to parse args
eval set -- "$OPTIONS"

#
# Parse args
#

# Un-dashed arg position
POSITION=0

# Array of un-dashed args
UNDASHED_ARGS=()
while true; do
	if [ "$#" == "0" ]; then
		# Number of args available - 0
		break
	fi

	# Recognize arg
	case "$1" in
	--test)
		FLAG_TEST='yes'
		;;
	--build-deps)
		FLAG_BUILD_DEPS='yes'
		;;
	--test-deps)
		FLAG_TEST_DEPS='yes'
		;;
	--deps)
		FLAG_DEPS='yes'
		;;
	--rpms)
		FLAG_RPMS='yes'
		;;
	--spec)
		FLAG_SPEC='yes'
		;;
	--download-sources)
		FLAG_DOWNLOAD_SOURCES='yes'
		;;
	--from-sources-in-BUILD-dir)
		FLAG_FROM_SOURCES_IN_BUILD_DIR='yes'
		;;
	--from-sources-in-SOURCES-dir)
		FLAG_FROM_SOURCES_IN_SOURCES_DIR='yes'
		;;
	--from-archive)
		FLAG_FROM_ARCHIVE='yes'
		;;
	--from-sources)
		FLAG_FROM_SOURCES='yes'
		;;
	--debuginfo)
		# Arg is recognized, shift to the value, which is the next arg
		shift

		# $1 is value of --debuginfo=x

		if [ "$1" == "no" ] || [ "$1" == "0" ] || [ "$1" == "off" ]; then
			echo "DEBUGINFO turned OFF"
			FLAG_DEBUGINFO="no"
		elif [ "$1" == "yes" ] || [ "$1" == "1" ] || [ "$1" == "on" ]; then
			echo "DEBUGINFO turned ON"
			FLAG_DEBUGINFO="yes"
		else
			echo "Unrecognized value '$1' of --debuginfo"
			echo "Possible values yes/no 1/0 on/off"
			exit 1
		fi
		;;
	--cmake-build-type)
		# Arg is recognized, shift to the value, which is the next arg
		shift

		# $1 is value of --cmake-build-type=x
		
		# Full list is here: https://cmake.org/cmake/help/v3.0/variable/CMAKE_BUILD_TYPE.html
		if [ "$1" == "Debug" ] || [ "$1" == "Release" ] || [ "$1" == "RelWithDebugInfo" ] || [ "$1" == "MinSizeRel" ]; then
			FLAG_CMAKE_BUILD_TYPE="$1"
		else
			echo "Unrecognized value '$1' of --cmake-buid-type"
			echo "Possible values: Debug Release RelWithDebugInfo MinSizeRel"
			exit 1
		fi
		;;
	--no-version-check)
		FLAG_NO_VERSION_CHECK='yes'
		;;
	--docker)
		FLAG_DOCKER='yes'
		;;
	--local)
		FLAG_LOCAL='yes'
		;;
	--local-sql)
		FLAG_LOCAL_SQL='yes'
		;;
	--publish)
		FLAG_PUBLISH='yes'
		;;
	--path)
		# Arg is recognized, shift to the value, which is the next arg
		shift

		FLAG_PATH=$1
		;;
	--packagecloud)
		# Arg is recognized, shift to the value, which is the next arg
		shift

		FLAG_PACKAGECLOUD=$1
		;;
	--delete)
		FLAG_DELETE='yes'
		;;
	--download)
		FLAG_DOWNLOAD='yes'
		;;
	--)
		# Just skip dashed and un-dashed args delimiter
		;;
	*)
		# Un-dashed args
		UNDASHED_ARGS[$POSITION]=$1
		POSITION=$((POSITION+1))
		;;
	esac

	# Shift to the next arg
	shift
done

UNDASHED_ARGS_NUM=${#UNDASHED_ARGS[*]}
if [[ $UNDASHED_ARGS_NUM -lt 1 ]]; then
	echo "Please provide a command"
	usage
	exit 1
fi

COMMAND=${UNDASHED_ARGS[0]}

export REBUILD_RPMS="no"
export FLAG_DEBUGINFO
export FLAG_CMAKE_BUILD_TYPE
set_rpmbuild_dirs $RPMBUILD_ROOT_DIR
os_detect
if os_centos_6; then
	# ninja is not used on CentOS6
	export USE_NINJA_BUILD=""
fi

case $COMMAND in

version)
	echo "v$CH_VERSION-$CH_TAG"
	;;

enlarge)
	# enlarge AWS disk partition up to the whole disk
	check_sudo

	sudo lsblk
	sudo yum install -y epel-release
	sudo yum install -y cloud-utils-growpart
	sudo growpart /dev/xvda 1
	sudo reboot
	;;

all)
	if [ ! -z "$FLAG_TEST" ]; then
		banner "all --test"

		export TEST_BINARIES="yes"
		ensure_os_rpm_based
		set_print_commands
		# build deps
		install_dependencies
		# test deps
		install_docker
		install_clickhouse_test_deps
		# build
		build_packages
		# test
		run_test_docker

	else
		banner "all"

		ensure_os_rpm_based
		set_print_commands
		install_dependencies
		build_packages
	fi
	;;

install)
	if [ ! -z "$FLAG_BUILD_DEPS" ]; then
		banner "install --build-deps"

		ensure_os_rpm_based
		set_print_commands
		# build deps
		install_dependencies

	elif [ ! -z "$FLAG_TEST_DEPS" ]; then
		banner "install --test-deps"

		ensure_os_rpm_based
		set_print_commands
		# test deps
		install_docker
		install_clickhouse_test_deps

	elif [ ! -z "$FLAG_DEPS" ]; then
		banner "install --deps"

		ensure_os_rpm_based
		set_print_commands
		# build deps
		install_dependencies
		# test deps
		install_docker
		install_clickhouse_test_deps

	elif [ ! -z "$FLAG_RPMS" ]; then

		if [ ! -z "$FLAG_FROM_SOURCES" ]; then
			banner "install --rpms --from-sources"
			setup_local_build_dirs
		else
			banner "install --rpms"
		fi

		ensure_os_rpm_based

		RPMFILES_NUM=$(ls $RPMS_DIR/clickhouse-*.rpm 2> /dev/null|wc -l)
		if [ $RPMFILES_NUM -gt 0 ]; then
			check_sudo
			sudo yum install -y $RPMS_DIR/clickhouse*.rpm
			sudo service clickhouse-server restart
		else
			echo "No RPM file available at $RPMS_DIR"
		fi

	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

build)
	if [ ! -z "$FLAG_SPEC" ]; then
		banner "build --spec"

		ensure_os_rpm_based

		set_print_commands
		build_spec_file

	elif [ ! -z "$FLAG_DOWNLOAD_SOURCES" ]; then
		banner "build --download-sources"
		download_sources

	elif [ ! -z "$FLAG_RPMS" ]; then
		# build --rpms

		ensure_os_rpm_based

		export TEST_BINARIES="no"
		export REBUILD_RPMS="no"

		if [ ! -z "$FLAG_TEST" ]; then
			# build --rpms --test
			export TEST_BINARIES="yes"
		fi

		if [ -z "$FLAG_FROM_ARCHIVE" ] && [ -z "$FLAG_FROM_SOURCES_IN_BUILD_DIR" ] && [ -z "$FLAG_FROM_SOURCES_IN_SOURCES_DIR" ] && [ -z "$FLAG_FROM_SOURCES" ]; then
			banner "build --rpms [--test]"

			ensure_os_rpm_based
			set_print_commands
			build_packages

		elif [ ! -z "$FLAG_FROM_ARCHIVE" ]; then
			banner "build --rpms --from-archive [--test]"

			ensure_os_rpm_based
			set_print_commands
			build_RPMs

		elif [ ! -z "$FLAG_FROM_SOURCES_IN_BUILD_DIR" ]; then
			banner "build --rpms --from-sources-in-BUILD-dir [--test]"

			export REBUILD_RPMS="yes"
			ensure_os_rpm_based
			set_print_commands
			build_RPMs

		elif [ ! -z "$FLAG_FROM_SOURCES_IN_SOURCES_DIR" ]; then
			banner "build --rpms --from-sources-in-SOURCES-dir [--test]"

			ensure_os_rpm_based
			set_print_commands
			zip_sources
			build_RPMs

		elif [ ! -z "$FLAG_FROM_SOURCES" ]; then
			banner "build --rpms --from-sources [--test]"

			set_print_commands
			ensure_os_rpm_based

			setup_local_build
			build_spec_file
			build_RPMs

		else
			echo "Unknwon $COMMAND path"
			exit 1
		fi
	fi
	;;

test)
	if [ ! -z "$FLAG_DOCKER" ]; then

		if [ ! -z "$FLAG_FROM_SOURCES" ]; then
			banner "test --docker --from-sources"
			setup_local_build_dirs
		else
			banner "test --docker"
		fi

		run_test_docker

	elif [ ! -z "$FLAG_LOCAL" ]; then
		banner "test --local"

		ensure_os_rpm_based

		install_clickhouse_test_deps
		clickhouse-test

	elif [ ! -z "$FLAG_LOCAL_SQL" ]; then
		banner "test --local-sql"

		echo "1) SELECT with settings"
		clickhouse-client -q 'SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1 settings enable_optimize_predicate_expression=0 FORMAT PrettyCompact'

		echo "2) SELECT w/o settings"
		clickhouse-client -q 'SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1 FORMAT PrettyCompact'

		echo "3) CREATE DATABASE qwe"
		clickhouse-client -q 'CREATE DATABASE qwe'

		echo "4) SHOW DATABASES"
		clickhouse-client -q 'SHOW DATABASES FORMAT PrettyCompact'

		echo "5) DROP DATABASE qwe"
		clickhouse-client -q 'DROP DATABASE qwe'

		echo "6) SHOW DATABASES"
		clickhouse-client -q 'SHOW DATABASES FORMAT PrettyCompact'

	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

repo)
	if [ ! -z "$FLAG_PUBLISH" ] && [ ! -z "$FLAG_PACKAGECLOUD" ]; then
		banner "repo --publish --path=a/b/c --packagecloud=XYZ"

		ensure_os_rpm_based
		# for publish command list of files to be published is the list of undashed args after the first one (which is 'repo')
		FILES=("${UNDASHED_ARGS[@]:1}")
		publish_packagecloud $FLAG_PACKAGECLOUD $FLAG_PATH ${FILES[@]/#/}


	elif [ ! -z "$FLAG_DELETE" ] && [ ! -z "$FLAG_PACKAGECLOUD" ]; then
		banner "repo --delete --packagecloud=ABC"

		# run publish script with all the rest of CLI params
		FILES=("${UNDASHED_ARGS[@]:1}")
		publish_packagecloud_delete $FLAG_PACKAGECLOUD ${FILES[@]/#/}

	elif [ ! -z "$FLAG_DOWNLOAD" ]; then
		banner "repo --download"

		# run publish script with all the rest of CLI params
		VERSIONS=("${UNDASHED_ARGS[@]:1}")
		publish_packagecloud_download $FLAG_PATH ${VERSIONS[@]/#/}
	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

list)
	if [ ! -z "$FLAG_RPMS" ]; then
		banner "list --rpms"
		list_RPMs
		#list_SRPMs
	fi

	;;

src)
	if [ ! -z "$FLAG_DOWNLOAD" ]; then
		banner "src --download"

		set_print_commands
		prepare_sources

	else
		echo "Unknwon $COMMAND path"
		exit 1
	fi
	;;

*)
	echo "Unknown command $COMMAND"
	usage
	exit 1
	;;

esac

