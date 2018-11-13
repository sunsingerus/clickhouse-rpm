#!/bin/bash
#
# Yandex ClickHouse DBMS build script for RHEL based distributions
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

# Git version of ClickHouse that we package
CH_VERSION="${CH_VERSION:-18.14.13}"

# Git tag marker (stable/testing)
CH_TAG="${CH_TAG:-stable}"
#CH_TAG="${CH_TAG:-testing}"

# Hostname of the server used to publish packages
SSH_REPO_SERVER="${SSH_REPO_SERVER:-10.81.1.162}"

# SSH username used to publish packages
SSH_REPO_USER="${SSH_REPO_USER:-clickhouse}"

# Root directory for repositories on the server used to publish packages
SSH_REPO_ROOT="${SSH_REPO_ROOT:-/var/www/html/repos/clickhouse}"

# This script dir
MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# Current work dir
CWD_DIR="$(pwd)"

# Source files dir - relative to this script
SRC_DIR="$MY_DIR/src"

# Where RPMs would be built - relative to CWD - makes possible to build in whatever folder needed
RPMBUILD_ROOT_DIR="$CWD_DIR/rpmbuild"

# Detect number of threads to run 'make' command
export THREADS=$(grep -c ^processor /proc/cpuinfo)

# Build most libraries using default GCC
export PATH=${PATH/"/usr/local/bin:"/}:/usr/local/bin

# export LD_LIBRARY_PATH=/usr/lib:/usr/local/lib:/opt/rh/devtoolset-7/root/usr/lib64

# Source libraries
. "${SRC_DIR}"/os.lib.sh
. "${SRC_DIR}"/publish_packagecloud.lib.sh
. "${SRC_DIR}"/publish_ssh.lib.sh
. "${SRC_DIR}"/util.lib.sh

function set_rpmbuild_dirs()
{
	# Where RPMs would be built
	RPMBUILD_ROOT_DIR=$1

	# Where build process will be run
	BUILD_DIR="$RPMBUILD_ROOT_DIR/BUILD"

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
	export SOURCES_DIR
}

##
##
##
function install_general_dependencies()
{
	banner "Install general dependencies"
	sudo yum install -y git wget curl zip unzip sed
}

##
##
##
function install_rpm_dependencies()
{
        banner "RPM build dependencies"
	sudo yum install -y rpm-build redhat-rpm-config createrepo
}

##
##
##
function install_mysql_libs()
{
	banner "Install MySQL client library"

	# which repo should be used:
	#   http://yum.mariadb.org/10.2/fedora26-amd64
	#   http://yum.mariadb.org/10.2/centos6-amd64
	#   http://yum.mariadb.org/10.2/centos7-amd64
	# however OL has to be called RHEL in this place, because Maria DB has no personal repo for OL
	if os_ol; then
		MARIADB_REPO_URL="http://yum.mariadb.org/10.2/rhel${DISTR_MAJOR}-amd64"
	else
		MARIADB_REPO_URL="http://yum.mariadb.org/10.2/${OS}${DISTR_MAJOR}-amd64"
	fi

	# create repo file
	sudo bash -c "cat << EOF > /etc/yum.repos.d/mariadb.repo
[mariadb]
name=MariaDB
baseurl=${MARIADB_REPO_URL}
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF"
	# install RPMs using newly created repo file
	sudo yum install -y MariaDB-devel MariaDB-shared
}

##
##
##
function install_build_process_dependencies()
{
	banner "Install build tools"

	sudo yum install -y m4 make

	if os_centos; then
		sudo yum install -y epel-release
		sudo yum install -y cmake3

		sudo yum install -y centos-release-scl
		sudo yum install -y devtoolset-7
	elif os_ol; then
		sudo yum install -y scl-utils
		sudo yum install -y devtoolset-7
		sudo yum install -y cmake3
	else
		# fedora
		sudo yum install -y gcc-c++ libstdc++-static cmake
	fi

	banner "Install CH dev dependencies"

	# libicu-devel -  ICU (support for collations and charset conversion functions
	# libtool-ltdl-devel - cooperate with dynamic libs
	sudo yum install -y zlib-devel openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel
}

##
##
##
function install_workarounds()
{
	banner "Install workarounds"

	# Now all workarounds are included into CMAKE_OPTIONS and MAKE_OPTIONS
}

##
## Install all required components before building RPMs
##
function install_dependencies()
{
	banner "Install dependencies"

	install_general_dependencies
	install_rpm_dependencies
	install_mysql_libs
	install_build_process_dependencies

	install_workarounds
}

##
##
##
function build_dependencies()
{
	banner "Build dependencies"
	
	if [[ $EUID -ne 0 ]]; then
		echo "You must be a root user" 2>&1
		exit 1
	fi

	if [ ! -d dependencies ]; then
		mkdir dependencies
	fi

	rm -rf dependencies/*

	cd dependencies

	banner "Install development packages"

	# Build process support requirements
	yum -y install rpm-build redhat-rpm-config gcc-c++ \
		subversion python-devel git wget m4 createrepo

	# CH dependencies

	# libicu-devel -  ICU (support for collations and charset conversion functions
	# libtool-ltdl-devel - cooperate with dynamic libs
	yum -y zlib-devel openssl-devel libicu-devel libtool-ltdl-devel unixODBC-devel readline-devel

	banner "Install MySQL client library"

	if ! rpm --query mysql57-community-release; then
		yum -y --nogpgcheck install http://dev.mysql.com/get/mysql57-community-release-el${DISTR_MAJOR}-9.noarch.rpm
	fi

	yum -y install mysql-community-devel
	if [ ! -e /usr/lib64/libmysqlclient.a ]; then
		ln -s /usr/lib64/mysql/libmysqlclient.a /usr/lib64/libmysqlclient.a
	fi

	banner "Build cmake"

	wget https://cmake.org/files/v3.9/cmake-3.9.3.tar.gz
	tar xf cmake-3.9.3.tar.gz
	cd cmake-3.9.3
	./configure
	make -j $THREADS
	make install
	cd ..

	banner "Build GCC 7"

	wget http://mirror.linux-ia64.org/gnu/gcc/releases/gcc-7.2.0/gcc-7.2.0.tar.gz
	tar xf gcc-7.2.0.tar.gz
	cd gcc-7.2.0
	./contrib/download_prerequisites
	cd ..
	mkdir gcc-build
	cd gcc-build
	../gcc-7.2.0/configure --enable-languages=c,c++ --enable-linker-build-id --with-default-libstdcxx-abi=gcc4-compatible --disable-multilib
	make -j $THREADS
	make install
	hash gcc g++
	gcc --version
	ln -f -s /usr/local/bin/gcc /usr/local/bin/gcc-7
	ln -f -s /usr/local/bin/g++ /usr/local/bin/g++-7
	ln -f -s /usr/local/bin/gcc /usr/local/bin/cc
	ln -f -s /usr/local/bin/g++ /usr/local/bin/c++
	cd ..

	# Use GCC 7 for builds
	export CC=gcc-7
	export CXX=g++-7

	# Install Boost
	wget http://downloads.sourceforge.net/project/boost/boost/1.65.1/boost_1_65_1.tar.bz2
	tar xf boost_1_65_1.tar.bz2
	cd boost_1_65_1
	./bootstrap.sh
	./b2 --toolset=gcc-7 -j $THREADS
	PATH=$PATH ./b2 install --toolset=gcc-7 -j $THREADS
	cd ..

	# Clang requires Python27
	rpm -ivh http://dl.iuscommunity.org/pub/ius/stable/Redhat/6/x86_64/epel-release-6-5.noarch.rpm
	rpm -ivh http://dl.iuscommunity.org/pub/ius/stable/Redhat/6/x86_64/ius-release-1.0-14.ius.el6.noarch.rpm
	yum clean all
	yum install python27

	banner "Build Clang"

	mkdir llvm
	cd llvm
	svn co http://llvm.org/svn/llvm-project/llvm/tags/RELEASE_500/final llvm
	cd llvm/tools
	svn co http://llvm.org/svn/llvm-project/cfe/tags/RELEASE_500/final clang
	cd ../projects/
	svn co http://llvm.org/svn/llvm-project/compiler-rt/tags/RELEASE_500/final compiler-rt
	cd ../..
	mkdir build
	cd build/
	cmake -D CMAKE_BUILD_TYPE:STRING=Release ../llvm -DCMAKE_CXX_LINK_FLAGS="-Wl,-rpath,/usr/local/lib64 -L/usr/local/lib64"
	make -j $THREADS
	make install
	hash clang
	cd ../../..
}

##
## Prepare $RPMBUILD_ROOT_DIR/SOURCES/ClickHouse-$CH_VERSION-$CH_TAG.zip file
##
function prepare_sources()
{
	banner "Ensure SOURCES dir is in place"
	mkdirs

	echo "Clean sources dir"
	rm -rf "$SOURCES_DIR"/ClickHouse*

	echo "Cloning from github v${CH_VERSION}-${CH_TAG} into $SOURCES_DIR/ClickHouse-${CH_VERSION}-${CH_TAG}"

	cd "$SOURCES_DIR"

	# Go older way because older versions of git (CentOS 6.9, for example) do not understand new syntax of branches etc
	# Clone specified branch with all submodules into $SOURCES_DIR/ClickHouse-$CH_VERSION-$CH_TAG folder
	echo "Clone ClickHouse repo"
	git clone "https://github.com/yandex/ClickHouse" "ClickHouse-${CH_VERSION}-${CH_TAG}"

	cd "ClickHouse-${CH_VERSION}-${CH_TAG}"

	echo "Checkout specific tag v${CH_VERSION}-${CH_TAG}"
	git checkout "v${CH_VERSION}-${CH_TAG}"

	echo "Update submodules"
	git submodule update --init --recursive

	cd "$SOURCES_DIR"

	echo "Move files into .zip with minimal compression"
	zip -r0mq "ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "ClickHouse-${CH_VERSION}-${CH_TAG}"

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
		# jemalloc should build as long as the Linux kernel version is >= 2.6.38, otherwise it needs to be disabled.
		# MADV_HUGEPAGE compilation error encounters
		CMAKE_OPTIONS="${CMAKE_OPTIONS} -DENABLE_JEMALLOC=0"
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
%_smp_mflags  -j'"$THREADS" > ~/.rpmmacros

	banner "Setup path to compilers"
	if os_centos || os_ol; then
		export CMAKE=cmake3
		export CC=/opt/rh/devtoolset-7/root/usr/bin/gcc
		export CXX=/opt/rh/devtoolset-7/root/usr/bin/g++
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
	rpmbuild -v -bs "$SPECS_DIR/clickhouse.spec"
	
	banner "Build RPMs"
	rpmbuild -v -bb "$SPECS_DIR/clickhouse.spec"

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

	echo "Clean up after previous run"
	rm -f "$RPMS_DIR"/clickhouse*
	rm -f "$SRPMS_DIR"/clickhouse*
	rm -f "$SPECS_DIR"/clickhouse.spec

	banner "Create RPM packages"
	
	# Prepare $SOURCES_DIR/ClickHouse-$CH_VERSION-$CH_TAG.zip file
	prepare_sources

	# Build $SPECS_DIR/clickhouse.spec file
	build_spec_file
 
	# Compile sources and build RPMS
	build_RPMs
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
	echo "./build.sh version        - display default version to build"
	echo
	echo "./build.sh all            - most popular point of entry - the same as idep_all"
	echo
	echo "./build.sh idep_all       - install dependencies from RPMs, download CH sources and build RPMs"
	echo "./build.sh bdep_all       - build dependencies from sources, download CH sources and build RPMs"
	echo "                            !!! YOU MAY NEED TO UNDERSTAND INTERNALS !!!"
	echo
	echo "./build.sh install_deps   - just install dependencies (do not download sources, do not build RPMs)"
	echo "./build.sh build_deps     - just build dependencies (do not download sources, do not build RPMs)"
	echo "./build.sh src            - just download sources"
	echo "./build.sh spec           - just create SPEC file (do not download sources, do not build RPMs)"
	echo "./build.sh packages       - download sources, create SPEC file and build RPMs (do not install dependencies)"
	echo "./build.sh rpms           - just build RPMs from .zip sourcesi"
	echo "                            (do not download sources, do not create SPEC file, do not install dependencies)"
	echo "./build.sh rebuild_rpms   - just build RPMs from unpacked sources - most likely you have modified them"
	echo "                            (do not download sources, do not create SPEC file, do not install dependencies)"
	echo
	echo "./build.sh publish packagecloud <packagecloud USER ID> - publish packages on packagecloud as USER"
	echo "./build.sh delete packagecloud <packagecloud USER ID>  - delete packages on packagecloud as USER"
	echo
	echo "./build.sh publish ssh - publish packages via SSH"
	
	exit 0
}

function setup_local_build()
{
	export LOCAL_RPMBUILD="yes"

	# Base dir of CH's sources
	CH_SRC_ROOT_DIR=$(realpath "$MY_DIR"/..)

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

	# Ex.: v18.14.13-stable
	GIT_TAG=$(cd "$CH_SRC_BASEDIR" && git describe --tags && cd "$CWD_DIR")
	echo "Extracting from git: $GIT_TAG"

	if [ -z "GIT_TAG" ]; then
		echo "Are those ClickHouse sources tagged?"
		exit 1
	fi

	# stable or teting
	TAG=$(echo $GIT_TAG | awk 'BEGIN {FS="-"}{print $2}')
	if [ -z "TAG" ]; then
		# TAG has to be specified. Expecting "stable" or "testing"
		echo "Can not recognize CH tag $TAG"
		exit 1
	fi

	# v18.14.13
	VER=$(echo $GIT_TAG | awk 'BEGIN {FS="-"}{print $1}')

	if [ "v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}" == "${VER}" ]; then
		# Version looks good
		echo "Version parsed: v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}-${TAG}"
	else
		echo "Tag is not equal extracted version "
		echo "v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH} not equals ${VER}"
		exit 1
	fi

	CH_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
	CH_TAG="${TAG}"

	set_rpmbuild_dirs "${CH_SRC_ROOT_DIR}/build/rpmbuild"
	mkdirs

	# build archive of CH sources in SOURCES

	# how current dir is called
	# make clickhouse out of /home/user/src/clickhouse
	CH_SRC_ROOT_DIR_SHORT=${CH_SRC_ROOT_DIR##*/}

	# how link should be named - the same as .zip file shoudl be called
	CH_SRC_ROOT_DIR_LINK="ClickHouse-${CH_VERSION}-${CH_TAG}"

	# step one level up of current sources and make link to current sources dir
	cd ${CH_SRC_ROOT_DIR}/..
	ln -s ${CH_SRC_ROOT_DIR_SHORT} ${CH_SRC_ROOT_DIR_LINK}

	# archive current sources dir via symlink - thus archive would
	# contain ClickHouse-18.14.13-stable folder in ClickHouse-18.14.13-stable.zip file
	rm -f "${SOURCES_DIR}/ClickHouse-${CH_VERSION}-${CH_TAG}.zip"
	zip -r0q "${SOURCES_DIR}/ClickHouse-${CH_VERSION}-${CH_TAG}.zip" "${CH_SRC_ROOT_DIR_LINK}" -x "${CH_SRC_ROOT_DIR_LINK}/build/*"
}

function clean_local_build()
{
	# cd one level up
	cd ${CH_SRC_ROOT_DIR}/..
	# check whether it is a symlink and remove it
	[ -L ${CH_SRC_ROOT_DIR_LINK} ] && rm ${CH_SRC_ROOT_DIR_LINK}
}

export REBUILD_RPMS="no"

if [ -z "$1" ]; then
	usage
fi

COMMAND="$1"

set_rpmbuild_dirs $RPMBUILD_ROOT_DIR

if [ "$COMMAND" == "version" ]; then
	echo "v$CH_VERSION-$CH_TAG"

elif [ "$COMMAND" == "all" ]; then
	ensure_os_rpm_based
	set_print_commands
	install_dependencies
	build_packages

elif [ "$COMMAND" == "idep_all" ]; then
	ensure_os_rpm_based
	set_print_commands
	install_dependencies
	build_packages

elif [ "$COMMAND" == "bdep_all" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_dependencies
	build_packages

elif [ "$COMMAND" == "install_deps" ]; then
	ensure_os_rpm_based
	set_print_commands
	install_dependencies

elif [ "$COMMAND" == "build_deps" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_dependencies

elif [ "$COMMAND" == "src" ]; then
	set_print_commands
	prepare_sources

elif [ "$COMMAND" == "spec" ]; then
	set_print_commands
	build_spec_file

elif [ "$COMMAND" == "packages" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_packages

elif [ "$COMMAND" == "rpm" ] || [ "$COMMAND" == "rpms" ]; then
	ensure_os_rpm_based
	set_print_commands
	build_RPMs

elif [ "$COMMAND" == "rebuild_rpm" ] || [ "$COMMAND" == "rebuild_rpms" ]; then
	export REBUILD_RPMS="yes"
	ensure_os_rpm_based
	set_print_commands
	build_RPMs

elif [ "$COMMAND" == "publish" ]; then
	PUBLISH_TARGET="$2"

	ensure_os_rpm_based
	if [ "$PUBLISH_TARGET" == "packagecloud" ]; then
		# run publish script with all the rest of CLI params
		publish_packagecloud ${*:3}

	elif [ "$PUBLISH_TARGET" == "ssh" ]; then
		publish_ssh

	else
		echo "Unknown publish target"
		usage
	fi

elif [ "$COMMAND" == "delete" ]; then
	PUBLISH_TARGET="$2"
	if [ "$PUBLISH_TARGET" == "packagecloud" ]; then
		# run publish script with all the rest of CLI params
		publish_packagecloud_delete ${*:3}

	elif [ "$PUBLISH_TARGET" == "ssh" ]; then
		echo "Not supported yet"
	else
		echo "Unknown publish target"
		usage
	fi

elif [ "$COMMAND" == "sql" ]; then
	echo "SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1 settings enable_optimize_predicate_expression=0"
	echo "SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1"
	echo
	echo "clickhouse-client -q 'SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1 settings enable_optimize_predicate_expression=0'"
	echo "clickhouse-client -q 'SELECT foo.one AS one FROM (SELECT 1 AS one ) AS foo WHERE one = 1'"

elif [ "$COMMAND" == "test" ]; then
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

elif [ "$COMMAND" == "local" ]; then
	set_print_commands
	ensure_os_rpm_based
	setup_local_build
	build_spec_file
	build_RPMs
	clean_local_build

else
	# unknown command
	echo "Unknown command: $COMMAND"
	usage
fi

