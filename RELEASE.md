# Releasing Hearsay

## 1. Bump version

Update `Hearsay/Info.plist`:
- `CFBundleShortVersionString` — user-facing version (e.g., `1.0.4`)
- `CFBundleVersion` — increment build number

## 2. Build (Universal Binary)

```bash
xcodegen generate
xcodebuild -project Hearsay.xcodeproj -scheme Hearsay -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  clean build
mkdir -p dist
cp -R ~/Library/Developer/Xcode/DerivedData/Hearsay-*/Build/Products/Release/Hearsay.app dist/

# Verify universal binary
file dist/Hearsay.app/Contents/MacOS/Hearsay
# Should show: Mach-O universal binary with 2 architectures: [x86_64] [arm64]
```

## 3. Bundle qwen_asr binary

```bash
cp ~/work/misc/qwen-asr/qwen_asr dist/Hearsay.app/Contents/MacOS/
```

## 4. Sign

```bash
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application" \
  dist/Hearsay.app
```

## 5. Create DMG & Notarize

```bash
hdiutil create -volname "Hearsay" -srcfolder dist/Hearsay.app -ov -format UDZO dist/Hearsay-VERSION.dmg

xcrun notarytool submit dist/Hearsay-VERSION.dmg \
  --keychain-profile "notarytool" \
  --wait
```

If it fails, check the log:
```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile "notarytool"
```

## 6. Staple

```bash
xcrun stapler staple dist/Hearsay-VERSION.dmg
```

## 7. Commit & Tag

```bash
git add Hearsay/Info.plist
git commit -m "Bump version to VERSION"
git tag -a vVERSION -m "Release vVERSION"
git push origin main
git push origin vVERSION
```

## 8. GitHub release

```bash
gh release create vVERSION dist/Hearsay-VERSION.dmg \
  --title "Hearsay vVERSION" \
  --notes "Release notes"
```

## 9. Update Homebrew tap

```bash
# Get SHA
shasum -a 256 dist/Hearsay-VERSION.dmg

# Update ~/work/projects/homebrew-tap/Casks/hearsay.rb with new version and SHA

cd ~/work/projects/homebrew-tap
git add Casks/hearsay.rb
git commit -m "Update hearsay to VERSION"
git push
```
