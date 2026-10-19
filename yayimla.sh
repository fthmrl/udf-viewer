#!/bin/zsh
# Yeni sürüm yayımlar:  ./yayimla.sh <sürüm no> "madde 1" "madde 2" ...
# Yalnızca derleyip bu Mac'e kurmak için:  YALNIZ_KUR=1 ./yayimla.sh <sürüm no>
# Önce main.swift içindeki YENILIKLER'e aynı sürümün maddelerini, SÜRÜM NOTLARI.txt'ye notu ekleyin.
# Zip + surum.json OneDrive klasörüne ve GitHub'a (fthmrl/udf-viewer) yayımlanır, bu Mac'e kurulur.
set -e
N=$1; shift
K=${0:A:h}; R=${K:h}; A="UDF Viewer.app"; Z="UdfViewer-v$N.zip"
GH=~/.local/bin/gh; DEPO=fthmrl/udf-viewer; GIT=~/Projects/udf-viewer
T=$(mktemp -d); B=$T/yapi; E="$B/$A/Contents/PlugIns/UDFOnizleme.appex"
mkdir -p "$B/$A/Contents/MacOS" "$B/$A/Contents/Resources" "$E/Contents/MacOS"
cp "$K"/{main,udf,onizleme}.swift "$T/"   # OneDrive derleme sırasında dosyaya dokunabiliyor

# Hızlı Bakış eklentisi (sandbox'lı uygulama eklentisi; Xcode gerekmez)
swiftc -O -parse-as-library -application-extension -module-name UDFOnizleme "$T/udf.swift" "$T/onizleme.swift" \
  -target arm64-apple-macos12 -Xlinker -e -Xlinker _NSExtensionMain -o "$E/Contents/MacOS/UDFOnizleme"
cp "$K/Onizleme-Info.plist" "$E/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $N" -c "Set :CFBundleShortVersionString $N" "$E/Contents/Info.plist"
codesign --force -s - --entitlements "$K/Onizleme.entitlements" "$E"

# Uygulama
swiftc -O "$T/main.swift" -target arm64-apple-macos12 -o "$B/$A/Contents/MacOS/udfviewer"
cp "$K/Info.plist" "$B/$A/Contents/Info.plist"
cp "$K/AppIcon.icns" "$B/$A/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $N" -c "Set :CFBundleShortVersionString $N" "$B/$A/Contents/Info.plist"
codesign --force -s - "$B/$A"

kur() {
  rm -rf "/Applications/$A"; cp -R "$B/$A" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$A"
  pluginkit -a "/Applications/$A/Contents/PlugIns/UDFOnizleme.appex"
  pluginkit -e use -i com.fthmrl.udfviewer.onizleme
  qlmanage -r >/dev/null 2>&1 || true
}
if [[ -n $YALNIZ_KUR ]]; then kur; echo "v$N derlendi ve bu Mac'e kuruldu (yayımlanmadı)."; exit 0; fi

ditto -c -k --keepParent "$B/$A" "$T/$Z"
cp "$T/$Z" "$T/UdfViewer.zip"   # sabit ad: README'deki tek satırlık kurulum hep son sürümü indirir
python3 -c 'import json,sys; n=int(sys.argv[1]); print(json.dumps({"surum":n,"dosya":f"UdfViewer-v{n}.zip","notlar":sys.argv[2:]},ensure_ascii=False,indent=1))' "$N" "$@" > "$T/surum.json"

# GitHub: kaynak kodu gönder, sürümü zip + surum.json ile yayımla
if [[ ! -d $GIT/.git ]]; then
  mkdir -p $GIT; git -C $GIT init -q -b main
  git -C $GIT remote add origin https://github.com/$DEPO.git
fi
for f in main.swift udf.swift onizleme.swift icon.swift Info.plist Onizleme-Info.plist Onizleme.entitlements AppIcon.icns simge.png README.md LICENSE yayimla.sh; do cp "$K/$f" $GIT/; done
git -C $GIT add -A
git -C $GIT -c user.name=fthmrl -c user.email=fthmrl@users.noreply.github.com commit -q -m "v$N" || true
git -C $GIT -c credential.helper= -c credential.helper="!$GH auth git-credential" push -q -u origin main
NOTLAR=$(for m in "$@"; do echo "- $m"; done)
$GH release create "v$N" "$T/$Z" "$T/UdfViewer.zip" "$T/surum.json" -R $DEPO --title "v$N" --target main \
  --notes "$NOTLAR"$'\n\n'"**Kurulum:** \`$Z\` dosyasını indirin, açın, uygulamayı Programlar'a sürükleyip bir kez açın. Ayrıntılar README'de."

# OneDrive: surum.json en son yazılır, zip tamamlanmadan hiçbir Mac güncellemeyi görmesin
cp "$T/$Z" "$R/$Z"; cp "$T/surum.json" "$R/surum.json"
kur
echo "v$N yayımlandı (OneDrive + GitHub) ve kuruldu."
