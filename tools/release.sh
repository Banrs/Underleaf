#!/bin/zsh
# usage: TEXLOCAL_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" TEXLOCAL_NOTARY_PROFILE=… tools/release.sh [tag]
set -e
R=${0:A:h:h}
IDENTITY=${TEXLOCAL_SIGN_IDENTITY:--} PROFILE=$TEXLOCAL_NOTARY_PROFILE TAG=$1
B=${TEXPRESSO_BUILD:-$R/tools/texpresso/source/build}
[[ -x $B/texpresso && -x $B/texpresso-xetex ]] || {
  echo "no TeXpresso in $B: run tools/texpresso/build.sh first, as a release always has Live Preview"; exit 1 }
[[ $IDENTITY == - || -n $PROFILE ]] || { echo "set TEXLOCAL_NOTARY_PROFILE to a notarytool keychain profile"; exit 1 }
[[ $IDENTITY == - || -z $(git -C $R status --porcelain) ]] || { echo "commit or stash your changes before a signed release"; exit 1 }
VERSION=$(awk -F' *= *' '$1 == "MARKETING_VERSION" { print $2 }' $R/apps/macos/Version.xcconfig)
[[ -z $TAG || ${TAG#v} == $VERSION ]] || { echo "tag $TAG doesn't match MARKETING_VERSION $VERSION in apps/macos/Version.xcconfig"; exit 1 }
BUILD=$(git -C $R rev-list --count HEAD)
D=/private/tmp/underleaf-archive-$(print -rn -- $R | shasum | cut -c1-10)
rm -rf $D; mkdir -p $D
ARCHIVE=$D/TeXLocal.xcarchive APP=$D/export/TeXLocal.app ZIP=$R/dist/TeXLocal-$VERSION-$BUILD.zip

signing=(CODE_SIGN_IDENTITY=$IDENTITY)
if [[ $IDENTITY != - ]]; then
  signing+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
  [[ $IDENTITY =~ '\(([A-Z0-9]{10})\)$' ]] && signing+=(DEVELOPMENT_TEAM=$match[1])
fi
echo "archiving TeXLocal $VERSION ($BUILD) signed with $IDENTITY in $D"
xcodebuild archive -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath $D/build -archivePath $ARCHIVE \
  TEXPRESSO_BUILD=$B CURRENT_PROJECT_VERSION=$BUILD $signing > $D/archive.log 2>&1 \
  || { grep -E "error:" $D/archive.log | sort -u | tail -20; echo "archive failed: $D/archive.log"; exit 1; }
rm -rf $D/build

mkdir -p ${APP:h}; ditto $ARCHIVE/Products/Applications/TeXLocal.app $APP
[[ -x $APP/Contents/Helpers/texpresso && -x $APP/Contents/Helpers/texpresso-xetex ]] || { echo "the archive has no TeXpresso helpers"; exit 1; }
codesign --verify --deep --strict $APP
codesign -d --entitlements - --xml $APP 2>/dev/null | grep -q get-task-allow && { echo "the app has the get-task-allow entitlement"; exit 1; }
for code in $APP/Contents/Frameworks/* $APP/Contents/Helpers/* $APP; do
  info=$(codesign -dv $code 2>&1)
  [[ $IDENTITY == - || $info == *flags=*runtime* ]] || { echo "${code#$D/export/} lacks the hardened runtime"; exit 1; }
  [[ $IDENTITY == - || $info == *"Timestamp="* ]] || { echo "${code#$D/export/} has no secure timestamp"; exit 1; }
done

if [[ $IDENTITY != - ]]; then
  ditto -c -k --keepParent $APP $D/notarize.zip
  result=$(xcrun notarytool submit $D/notarize.zip --keychain-profile $PROFILE --wait --output-format plist)
  [[ $(plutil -extract status raw - <<< $result) == Accepted ]] || {
    xcrun notarytool log $(plutil -extract id raw - <<< $result) --keychain-profile $PROFILE; echo "notarization failed"; exit 1 }
  xcrun stapler staple $APP
  spctl --assess --type execute --verbose $APP
else
  echo "ad hoc signature: skipping notarization and the Gatekeeper assessment"
fi

mkdir -p ${ZIP:h}; rm -f $ZIP
ditto -c -k --keepParent $APP $ZIP
echo "wrote $ZIP (archive in $ARCHIVE)"
