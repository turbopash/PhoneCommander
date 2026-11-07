#!/bin/zsh
# Готовый zip для Releases: библиотеки собираются из исходников под macOS 13
# и вкладываются в приложение, поэтому Homebrew у пользователя не нужен.
# Для сборки нужны Command Line Tools и `brew install pkgconf`.
set -e
cd "${0:A:h}"
export MACOSX_DEPLOYMENT_TARGET=13.0
ROOT=$PWD
DEPS=/Users/Shared/phonecommander-deps  # нейтральный путь: он остаётся внутри собранных библиотек
SRC=$DEPS/src
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig
mkdir -p "$SRC"
GH=https://github.com/libimobiledevice

fetch() { # url sha256 -> распакованная папка в $SRC
  local f=$SRC/${1:t}
  [ -f "$f" ] || curl -fsSL "$1" -o "$f"
  echo "$2  $f" | shasum -a 256 -c - >/dev/null
  tar -xf "$f" -C "$SRC"
}
autotools() { # имя-версия опции...
  local n=$1; shift
  [ -f "$DEPS/.done-$n" ] && return
  ( cd "$SRC/$n" && ./configure --prefix="$DEPS" --disable-static --disable-silent-rules "$@" >/dev/null \
    && make -j8 >/dev/null && make install >/dev/null )
  touch "$DEPS/.done-$n"
}

fetch https://github.com/openssl/openssl/releases/download/openssl-4.1.0/openssl-4.1.0.tar.gz 50c17baf54cb008f6ce42d50deb4b28050a1aad711636cabd4b241c7e90cc2fd
fetch $GH/libplist/releases/download/2.8.0/libplist-2.8.0.tar.bz2 b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a
fetch $GH/libimobiledevice-glue/releases/download/1.3.3/libimobiledevice-glue-1.3.3.tar.bz2 920ce01382a32695f49b23292b4979a03f0afd16c58e8755d8b7f41804acc1a9
fetch $GH/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2 5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce
fetch $GH/libtatsu/releases/download/1.1.0/libtatsu-1.1.0.tar.bz2 96c8abd97552a4a0c487c701aba9a65d590c338dd331058ffb38304290b696c7
fetch $GH/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2 23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d

if [ ! -f "$DEPS/.done-openssl" ]; then
  ( cd "$SRC/openssl-4.1.0" && ./Configure darwin64-arm64-cc shared no-tests no-docs --prefix="$DEPS" --libdir=lib >/dev/null \
    && make -j8 >/dev/null && make install_sw >/dev/null )
  touch "$DEPS/.done-openssl"
fi
autotools libplist-2.8.0 --without-cython --without-tests
autotools libimobiledevice-glue-1.3.3
autotools libusbmuxd-2.1.1
autotools libtatsu-1.1.0 libcurl_CFLAGS="-I$(xcrun --show-sdk-path)/usr/include" libcurl_LIBS=-lcurl  # libcurl есть в macOS
autotools libimobiledevice-1.4.0 --without-cython

PC_PREFIX=$DEPS zsh build.sh
APP="build/Phone Commander.app"
BIN="$APP/Contents/MacOS/PhoneCommander"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

# Копируем всё, что тянется из .deps, и переводим ссылки на @rpath.
deps_of() { otool -L "$1" | awk 'NR>1{print $1}' | grep "^$DEPS/" || true }
queue=("$BIN")
while (( $#queue )); do
  f=$queue[1]; shift queue
  for d in ${(f)"$(deps_of "$f")"}; do
    n=${d:t}
    if [ ! -f "$FW/$n" ]; then
      cp -L "$d" "$FW/$n"; chmod 755 "$FW/$n"
      install_name_tool -id "@rpath/$n" "$FW/$n" 2>/dev/null
      queue+=("$FW/$n")
    fi
    install_name_tool -change "$d" "@rpath/$n" "$f" 2>/dev/null
  done
done
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN" 2>/dev/null

# Лицензии библиотек и откуда взять их исходники.
LIC="$APP/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$LIC"
for n in openssl-4.1.0 libplist-2.8.0 libimobiledevice-glue-1.3.3 libusbmuxd-2.1.1 libimobiledevice-1.4.0; do
  mkdir -p "$LIC/$n"
  for l in COPYING COPYING.LESSER LICENSE.txt; do
    [ -f "$SRC/$n/$l" ] && cp "$SRC/$n/$l" "$LIC/$n/"
  done
done
cat > "$LIC/README.txt" <<T
Phone Commander содержит эти библиотеки без изменений, в виде отдельных файлов в Contents/Frameworks.
Их можно заменить своими сборками. Адреса исходников и контрольные суммы: release.sh
в https://github.com/turbopash/PhoneCommander

libimobiledevice, libimobiledevice-glue, libplist, libusbmuxd: LGPL-2.1-or-later. https://libimobiledevice.org
OpenSSL: Apache-2.0. https://www.openssl.org
T

for f in "$FW"/*.dylib; do codesign --force -s - "$f"; done
codesign --force -s - "$APP"
mkdir -p dist
rm -f dist/PhoneCommander.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/PhoneCommander.zip
echo "Готово: $PWD/dist/PhoneCommander.zip"
