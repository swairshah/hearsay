# Releasing Hearsay

## 1. Bump version

Update `Hearsay/Info.plist`:
- `CFBundleShortVersionString` — user-facing version (e.g., `1.0.4`)
- `CFBundleVersion` — increment build number

## 2. Build, Sign, Notarize, and Create DMG

Hearsay ships as a universal app. Parakeet support is provided by an Apple Silicon-only helper so Intel Macs can continue using the non-Parakeet models.

```bash
./scripts/release.sh
```

Expected output:

```bash
dist/Hearsay-VERSION.dmg
```

Verify the release artifact:

```bash
xcrun stapler validate dist/Hearsay-VERSION.dmg
```

The release script bundles the CLI at:

```bash
Hearsay.app/Contents/Resources/hearsay
```

If it fails, check the log:
```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile "notarytool"
```

## 3. Commit & Tag

```bash
git add Hearsay/Info.plist scripts/release.sh RELEASE.md
git commit -m "Bump version to VERSION"
git tag -a vVERSION -m "Release vVERSION"
git push origin main
git push origin vVERSION
```

## 4. GitHub release

```bash
gh release create vVERSION dist/Hearsay-VERSION.dmg \
  --title "Hearsay vVERSION" \
  --notes "Release notes"
```

## 5. Update Homebrew tap

```bash
# Get SHA
shasum -a 256 dist/Hearsay-VERSION.dmg

# Update ~/work/projects/homebrew-tap/Casks/hearsay.rb with new version and SHA.
# The cask should also expose the bundled CLI:
# binary "#{appdir}/Hearsay.app/Contents/Resources/hearsay", target: "hearsay"

cd ~/work/projects/homebrew-tap
git add Casks/hearsay.rb
git commit -m "Update hearsay to VERSION"
git push
```
