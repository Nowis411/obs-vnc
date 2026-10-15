#! /bin/bash

set -ex

if test ! -d $LIBVNCPath; then
	echo obs-studio directory does not exist
	git clone https://github.com/LibVNC/libvncserver.git $LIBVNCPath
fi

cd $LIBVNCPath
OBSLatestTag=$(git describe --tags --exclude="*-rc*" --abbrev=0)
git checkout $OBSLatestTag

# below are copied from libvncserver/.appveyor.yml
mkdir -p $LIBVNCPath/deps
cd $LIBVNCPath/deps

case $CMakeOptA in
	Win32)
		curl -fsSL -o nasm.zip https://www.nasm.us/pub/nasm/releasebuilds/2.15.05/win32/nasm-2.15.05-win32.zip
		;;
	x64)
		curl -fsSL -o nasm.zip https://www.nasm.us/pub/nasm/releasebuilds/2.15.05/win64/nasm-2.15.05-win64.zip
		;;
esac
7z x nasm.zip
mv nasm-2.15.05 nasm
PATH="$PATH:$PWD/nasm"

curl -fsSL -o lzo.tar.gz http://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz
mkdir -p lzo/build
cd lzo
tar xzf ../lzo.tar.gz --strip-components=1
cd build
cmake -A $CMakeOptA ..
cmake --build . --config $build_config
cd $LIBVNCPath/deps

# curl -fsSL -o libjpeg.tar.gz https://github.com/libjpeg-turbo/libjpeg-turbo/archive/2.0.4.tar.gz
curl -fsSL -o libjpeg.tar.gz https://github.com/norihiro/obs-vnc/releases/download/0.1.0/libjpeg-2.0.4-norihiro.tar.gz
mkdir -p libjpeg
cd libjpeg
tar xzf ../libjpeg.tar.gz --strip-components=1
cmake -A $CMakeOptA .
cmake --build . --config $build_config
cd $LIBVNCPath/deps

curl -fsSL -o libpng.tar.gz https://downloads.sourceforge.net/project/libpng/libpng16/1.6.40/libpng-1.6.40.tar.gz
mkdir -p libpng
cd libpng
tar xzf ../libpng.tar.gz --strip-components=1
cmake . -A $CMakeOptA -DZLIB_INCLUDE_DIR=$OBSDeps/include -DZLIB_LIBRARY=$OBSDeps/lib/zlib.lib
cmake --build . --config $build_config
cd ..

# Use vcpkg for Berkeley DB (pre-installed on GitHub runners)
# This avoids the slow devenv.com /upgrade step for Berkeley DB
export VCPKG_ROOT=${VCPKG_ROOT:-/c/vcpkg}
export PATH="$VCPKG_ROOT:$PATH"

# Install Berkeley DB via vcpkg
# Use triplet matching our architecture
VCPKG_TRIPLET="${CMakeOptA}-windows-static"
if [ "$CMakeOptA" = "Win32" ]; then
    VCPKG_TRIPLET="x86-windows-static"
fi

vcpkg install berkeleydb:$VCPKG_TRIPLET --recurse

# Build Cyrus SASL from source using vcpkg-installed Berkeley DB
# Use msbuild directly on .vcxproj files for faster build
curl -fsSL -o cyrus-sasl-2.1.28.tar.gz https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-2.1.28/cyrus-sasl-2.1.28.tar.gz
tar xzf cyrus-sasl-2.1.28.tar.gz
# Find the extracted directory (may have different name)
SASL_DIR=$(find . -maxdepth 1 -type d -name 'cyrus-sasl-*' | head -1)
mv "$SASL_DIR" sasl
cd sasl

# Build using msbuild on the sasl2.vcxproj directly (faster than devenv.com)
# The SASL source has Visual Studio projects in win32/
cd win32
# Update the project files to use the vcpkg-installed Berkeley DB
# We'll build sasl2.vcxproj directly
MSBUILD="/c/Program Files/Microsoft Visual Studio/2022/Enterprise/MSBuild/Current/Bin/MSBuild.exe"
# Use Windows SDK 10.0 (available on GitHub runners) instead of 8.1
# SASL projects only have Debug/Release configurations, map RelWithDebInfo to Release
# Retarget from VS2015 (v140) to current VS2022 (v143)
SASL_CONFIG="$build_config"
if [ "$build_config" = "RelWithDebInfo" ]; then
    SASL_CONFIG="Release"
fi
"$MSBUILD" sasl2.vcxproj -p:Configuration=$SASL_CONFIG -p:Platform=$CMakeOptA \
  -p:WindowsTargetPlatformVersion=10.0 \
  -p:PlatformToolset=v143 \
  -p:DB_INCLUDE_DIR=$VCPKG_ROOT/installed/$VCPKG_TRIPLET/include \
  -p:DB_LIBRARY=$VCPKG_ROOT/installed/$VCPKG_TRIPLET/lib/libdb.lib \
  -p:OPENSSL_ROOT_DIR=/c/Program\ Files/OpenSSL

# Copy the built library and headers to expected locations
cd ..
mkdir -p include/sasl
cp -r include/*.h include/sasl/ 2>/dev/null || true
# The built library will be in win32/$SASL_CONFIG/
mkdir -p $build_config
cp win32/$SASL_CONFIG/sasl2.lib $build_config/libsasl.lib 2>/dev/null || \
cp win32/$SASL_CONFIG/sasl.lib $build_config/libsasl.lib 2>/dev/null || true

cd ..

# go back to source root
cd ..

echo Preparing and building libvncserver...
cmake \
	-A $CMakeOptA \
	-DWITH_OPENSSL=ON \
	-DOPENSSL_USE_STATIC_LIBS=ON \
	-DZLIB_INCLUDE_DIR=$OBSDeps/include -DZLIB_LIBRARY=$OBSDeps/lib/zlib.lib \
	-DLZO_INCLUDE_DIR=$LIBVNCPath/deps/lzo/include -DLZO_LIBRARIES=$LIBVNCPath/deps/lzo/build/$build_config/lzo2.lib \
	-DPNG_PNG_INCLUDE_DIR=$LIBVNCPath/deps/libpng \
	-DPNG_INCLUDE_DIR=$LIBVNCPath/deps/libpng \
	-DPNG_LIBRARY=$LIBVNCPath/deps/libpng/$build_config/libpng16_static.lib \
	-DJPEG_INCLUDE_DIR=$LIBVNCPath/deps/libjpeg -DJPEG_LIBRARY=./deps/libjpeg/$build_config/turbojpeg-static \
	-DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_SYSTEMD=OFF -DWITH_FFMPEG=OFF \
	-D LIBVNCSERVER_INSTALL=OFF \
	-D WITH_TIGHTVNC_FILETRANSFER=OFF \
	-D WITH_EXAMPLES=OFF \
	-D WITH_TESTS=OFF \
	-DWITH_SASL=ON \
	-DSASL_INCLUDE_DIR=$LIBVNCPath/deps/sasl/include \
	-DSASL_LIBRARY=$LIBVNCPath/deps/sasl/$build_config/libsasl.lib \
	-D CMAKE_BUILD_TYPE=$build_config \
	.
cmake --build . --config $build_config