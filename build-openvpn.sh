#!/bin/bash
#  Builds openvpn for all three current iPhone targets: iPhoneSimulator-i386,
#  iPhoneOS-armv6, iPhoneOS-armv7.
#
#  Copyright 2012 Mike Tigas <mike@tig.as>
#
#  Based on work by Felix Schulze on 16.12.10.
#  Copyright 2010 Felix Schulze. All rights reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
###########################################################################
#  Choose your openvpn version and your currently-installed iOS SDK version:
#
VERSION="2.3.2"
SDKVERSION="7.0"
MINIOSVERSION="6.0"
VERIFYGPG=true

#
#
###########################################################################
#
# Don't change anything under this line!
#
###########################################################################

# No need to change this since xcode build will only compile in the
# necessary bits from the libraries we create
ARCHS="i386 x86_64 armv7 armv7s arm64"

DEVELOPER=`xcode-select -print-path`

cd "`dirname \"$0\"`"
REPOROOT=$(pwd)

# Where we'll end up storing things in the end
OUTPUTDIR="${REPOROOT}/dependencies"
mkdir -p ${OUTPUTDIR}/include
mkdir -p ${OUTPUTDIR}/lib


BUILDDIR="${REPOROOT}/build"

# where we will keep our sources and build from.
SRCDIR="${BUILDDIR}/src"
mkdir -p $SRCDIR
# where we will store intermediary builds
INTERDIR="${BUILDDIR}/built"
mkdir -p $INTERDIR

########################################

cd $SRCDIR

# Exit the script if an error happens
set -e

if [ ! -e "${SRCDIR}/openvpn-${VERSION}.tar.gz" ]; then
	echo "Downloading openvpn-${VERSION}.tar.gz"
    curl -LO http://swupdate.openvpn.org/community/releases/openvpn-${VERSION}.tar.gz
else
	echo "Using openvpn-${VERSION}.tar.gz"
fi

# up to you to set up `gpg` and add keys to your keychain
if $VERIFYGPG; then
    if [ ! -e "${SRCDIR}/openvpn-${VERSION}.tar.gz.asc" ]; then
        curl -O http://swupdate.openvpn.org/community/releases/openvpn-${VERSION}.tar.gz.asc
    fi
    echo "Using openssl-${VERSION}.tar.gz.asc"
    if out=$(gpg --status-fd 1 --verify "openvpn-${VERSION}.tar.gz.asc" "openvpn-${VERSION}.tar.gz" 2>/dev/null) &&
    echo "$out" | grep -qs "^\[GNUPG:\] VALIDSIG"; then
        echo "$out" | egrep "GOODSIG|VALIDSIG"
        echo "Verified GPG signature for source..."
    else
        echo "$out" >&2
        echo "COULD NOT VERIFY PACKAGE SIGNATURE..."
        exit 1
    fi
fi

tar zxf openvpn-${VERSION}.tar.gz -C $SRCDIR
cd "${SRCDIR}/openvpn-${VERSION}"

####
# Patch to remove the main() function from openvpn.c
patch -p3 < ../../../build-patches/openvpn-main.diff

# Patch to makefile build a static library
patch -p3 < ../../../build-patches/openvpn-makefile.diff

echo "Copying <net/route.h> from iPhoneSimulator"
mkdir -p ${OUTPUTDIR}/include/net
cp ${DEVELOPER}/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator${SDKVERSION}.sdk/usr/include/net/route.h ${OUTPUTDIR}/include/net/route.h

set +e # don't bail out of bash script if ccache doesn't exist
CCACHE=`which ccache`
if [ $? == "0" ]; then
    echo "Building with ccache: $CCACHE"
    CCACHE="${CCACHE} "
else
    echo "Building without ccache"
    CCACHE=""
fi
set -e # back to regular "bail out on error" mode

for ARCH in ${ARCHS}
do
	if [ "${ARCH}" == "i386" ] || [ "${ARCH}" == "x86_64" ] ; then
        PLATFORM="iPhoneSimulator"
        EXTRA_CONFIG="--host ${ARCH}-apple-darwin"
        EXTRA_CFLAGS=""
        EXTRA_LDFLAGS=""
    else
        PLATFORM="iPhoneOS"
        EXTRA_CONFIG="--host arm-apple-darwin"
        EXTRA_CFLAGS=""
        EXTRA_LDFLAGS=""
    fi

	mkdir -p "${INTERDIR}/${PLATFORM}${SDKVERSION}-${ARCH}.sdk"

	./configure --disable-shared --enable-static --with-pic --disable-lzo --disable-plugin-auth-pam --disable-plugin-down-root ${EXTRA_CONFIG} \
    --prefix="${INTERDIR}/${PLATFORM}${SDKVERSION}-${ARCH}.sdk" \
    CC="${CCACHE}${DEVELOPER}/usr/bin/gcc" \
    LDFLAGS="$LDFLAGS -arch ${ARCH} -fPIE -miphoneos-version-min=6.0 ${EXTRA_LDFLAGS} -L${OUTPUTDIR}/lib" \
    CFLAGS="$CFLAGS -g -O0 -D__APPLE_USE_RFC_3542 -arch ${ARCH} -fPIE -miphoneos-version-min=6.0 ${EXTRA_CFLAGS} -I${OUTPUTDIR}/include -isysroot ${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer/SDKs/${PLATFORM}${SDKVERSION}.sdk" \

    # Build the application and install it to the fake SDK intermediary dir
    # we have set up. Make sure to clean up afterward because we will re-use
    # this source tree to cross-compile other targets.
	make -j2
	make install

    mkdir -p ${INTERDIR}/${PLATFORM}${SDKVERSION}-${ARCH}.sdk/lib/
    cp src/openvpn/libopenvpn.a ${INTERDIR}/${PLATFORM}${SDKVERSION}-${ARCH}.sdk/lib/libopenvpn.a

	make clean
done

########################################

echo "Build library..."

# These are the libs that comprise openvpn.
OUTPUT_LIBS="libopenvpn.a"
for OUTPUT_LIB in ${OUTPUT_LIBS}; do
    INPUT_LIBS=""
    for ARCH in ${ARCHS}; do
        if [ "${ARCH}" == "i386" ] || [ "${ARCH}" == "x86_64" ] ; then
            PLATFORM="iPhoneSimulator"
        else
            PLATFORM="iPhoneOS"
        fi
        INPUT_ARCH_LIB="${INTERDIR}/${PLATFORM}${SDKVERSION}-${ARCH}.sdk/lib/${OUTPUT_LIB}"
        if [ -e $INPUT_ARCH_LIB ]; then
            INPUT_LIBS="${INPUT_LIBS} ${INPUT_ARCH_LIB}"
        fi
    done
    # Combine the three architectures into a universal library.
    if [ -n "$INPUT_LIBS"  ]; then
        lipo -create $INPUT_LIBS \
        -output "${OUTPUTDIR}/lib/${OUTPUT_LIB}"
    else
        echo "$OUTPUT_LIB does not exist, skipping (are the dependencies installed?)"
    fi
done

for ARCH in ${ARCHS}; do
    if [ "${ARCH}" == "i386" ] || [ "${ARCH}" == "x86_64" ] ; then
        PLATFORM="iPhoneSimulator"
    else
        PLATFORM="iPhoneOS"
    fi
    cp -R ${INTERDIR}/${PLATFORM}${SDKVERSION}-${ARCH}.sdk/include/* ${OUTPUTDIR}/include/
    if [ $? == "0" ]; then
        # We only need to copy the headers over once. (So break out of forloop
        # once we get first success.)
        break
    fi
done


####################

echo "Building done."
echo "Cleaning up..."
rm -fr ${INTERDIR}
rm -fr "${SRCDIR}/openvpn-${VERSION}"
echo "Done."
