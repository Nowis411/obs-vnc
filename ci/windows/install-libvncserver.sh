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

# Use vcpkg for Berkeley DB and Cyrus SASL (pre-installed on GitHub runners)
# Use non-static triplet for SASL to avoid krb5 build issues on static Windows
export VCPKG_ROOT=${VCPKG_ROOT:-/c/vcpkg}
export PATH="$VCPKG_ROOT:$PATH"

# Install Berkeley DB via vcpkg (static)
VCPKG_TRIPLET_STATIC="${CMakeOptA}-windows-static"
if [ "$CMakeOptA" = "Win32" ]; then
    VCPKG_TRIPLET_STATIC="x86-windows-static"
fi

vcpkg install berkeleydb:$VCPKG_TRIPLET_STATIC --recurse

# Install Cyrus SASL via vcpkg (non-static to avoid krb5 build issues)
VCPKG_TRIPLET_DYNAMIC="${CMakeOptA}-windows"
if [ "$CMakeOptA" = "Win32" ]; then
    VCPKG_TRIPLET_DYNAMIC="x86-windows"
fi

vcpkg install cyrus-sasl:$VCPKG_TRIPLET_DYNAMIC --recurse

# Copy SASL headers and libraries to expected locations
# vcpkg installs to installed/<triplet>/include and installed/<triplet>/lib
mkdir -p $LIBVNCPath/deps/sasl/include/sasl
cp -r $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DYNAMIC/include/sasl/*.h $LIBVNCPath/deps/sasl/include/sasl/ 2>/dev/null || \
cp -r $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DYNAMIC/include/*.h $LIBVNCPath/deps/sasl/include/sasl/ 2>/dev/null || true

mkdir -p $LIBVNCPath/deps/sasl/$build_config
# vcpkg non-static builds dynamic libraries (.dll and .lib import library)
# We need to copy the import library as libsasl.lib
cp $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DYNAMIC/lib/libsasl.lib $LIBVNCPath/deps/sasl/$build_config/libsasl.lib 2>/dev/null || \
cp $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DYNAMIC/lib/sasl.lib $LIBVNCPath/deps/sasl/$build_config/libsasl.lib 2>/dev/null || true

# Also copy the DLL for runtime
mkdir -p $LIBVNCPath/$build_config
cp $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DYNAMIC/bin/libsasl.dll $LIBVNCPath/$build_config/ 2>/dev/null || \
cp $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DYNAMIC/bin/sasl.dll $LIBVNCPath/$build_config/ 2>/dev/null || true

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