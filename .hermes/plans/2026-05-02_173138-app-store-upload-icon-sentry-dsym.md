# App Store Upload Fix Plan: App Icon Alpha + Sentry dSYM

## Goal
Resolve App Store Connect upload blockers for `financeplan.app`:
1. `90717 Invalid large app icon` because App Store believes large app icon has transparency/alpha.
2. `Upload Symbols Failed` because archive is missing dSYM for `Sentry.framework` UUID `0A890EFE-F82B-3434-84F8-0CAD36E154EB`.

## Current context / findings
- iOS repo inspected at:
  - `/Users/fernando_idwell/Projects/StockProject/StockPlanIOSApp/financeplan`
- Current git status already has only two modified app icon PNGs:
  - `financeplan/Assets.xcassets/AppIcon.appiconset/nordiq-light-mode.png`
  - `financeplan/Assets.xcassets/AppIcon.appiconset/nordiq-dark-mode.png`
- Current local image verification says both app icon files are valid RGB PNGs:
  - `1024x1024`
  - `8-bit/color RGB`
  - `sips hasAlpha: no`
- `AppIcon.appiconset/Contents.json` maps the large app icons to those two files:
  - light/default: `nordiq-light-mode.png`
  - dark: `nordiq-dark-mode.png`
  - tinted: reuses `nordiq-light-mode.png`
- Sentry is integrated through Swift Package Manager:
  - `financeplan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  - package: `sentry-cocoa`
  - version: `9.11.0`
  - revision: `a49e7c2148ac9e38bd35ef4f13bc9d6ea3ff0b81`
- Project build settings show Release configurations use:
  - `DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";`
- Likely cause for Sentry dSYM error: archive was created with cached/old SwiftPM artifact, package binary dSYM was not copied into archive, or the archive upload includes the Sentry binary UUID but not its matching `.dSYM`.

## Proposed approach
Fix in two tracks:
1. App icon: force Xcode/Asset Catalog to consume clean non-alpha RGB images, then clean all relevant build caches before archiving.
2. Sentry dSYM: verify archive contents and either regenerate a clean archive after resetting SwiftPM/build caches or manually include/upload matching Sentry dSYM if available.

## Step-by-step plan

### 1. App icon alpha error
1. Confirm the two modified PNG files remain non-alpha:
   - `sips -g hasAlpha -g pixelWidth -g pixelHeight financeplan/Assets.xcassets/AppIcon.appiconset/nordiq-light-mode.png`
   - `sips -g hasAlpha -g pixelWidth -g pixelHeight financeplan/Assets.xcassets/AppIcon.appiconset/nordiq-dark-mode.png`
2. In Xcode, open Asset Catalog:
   - `financeplan/Assets.xcassets/AppIcon.appiconset`
3. Remove/re-add the two icon slots if Xcode still seems to cache old assets:
   - default/light -> `nordiq-light-mode.png`
   - dark -> `nordiq-dark-mode.png`
   - tinted -> use non-alpha `nordiq-light-mode.png` or a dedicated non-alpha tinted icon if required
4. If App Store still rejects after current RGB conversion, use Preview manual export as final source of truth:
   - Open each PNG in Preview
   - File -> Export...
   - Format: PNG
   - Uncheck `Alpha`
   - Replace original file
5. Clean Xcode caches before archive:
   - Xcode -> Product -> Clean Build Folder
   - Optional if stubborn: delete DerivedData for this project
   - Xcode -> File -> Packages -> Reset Package Caches
6. Re-archive, not just re-upload old archive.

### 2. Sentry dSYM error
1. Create a fresh archive after cache cleanup.
2. Locate the new archive:
   - Xcode Organizer -> right-click archive -> Show in Finder
   - right-click `.xcarchive` -> Show Package Contents
3. Check whether Sentry binary exists:
   - `Products/Applications/financeplan.app/Frameworks/Sentry.framework/Sentry`
4. Check whether matching Sentry dSYM exists:
   - `dSYMs/Sentry.framework.dSYM/Contents/Resources/DWARF/Sentry`
5. Verify UUIDs match Apple's error:
   - `dwarfdump --uuid Products/Applications/financeplan.app/Frameworks/Sentry.framework/Sentry`
   - `dwarfdump --uuid dSYMs/Sentry.framework.dSYM/Contents/Resources/DWARF/Sentry`
   - Expected UUID from Apple error: `0A890EFE-F82B-3434-84F8-0CAD36E154EB`
6. If the framework UUID exists but dSYM missing:
   - Reset SwiftPM package caches in Xcode
   - Delete DerivedData
   - Re-resolve packages
   - Re-archive
7. If still missing, search local SwiftPM/Xcode caches for `Sentry.framework.dSYM` matching the UUID:
   - `find ~/Library/Developer/Xcode/DerivedData -name 'Sentry.framework.dSYM'`
   - run `dwarfdump --uuid` on candidates
8. If matching dSYM is found:
   - include it in the archive `dSYMs/` folder before upload, or upload symbols separately to Sentry if the App Store upload warning is non-blocking.
9. If no matching dSYM is available:
   - update `sentry-cocoa` to the latest 9.x patch or re-pin 9.11.0 cleanly
   - re-resolve packages
   - re-archive
   - verify archive includes Sentry dSYM before upload

## Files likely to change
Likely already changed:
- `/Users/fernando_idwell/Projects/StockProject/StockPlanIOSApp/financeplan/financeplan/Assets.xcassets/AppIcon.appiconset/nordiq-light-mode.png`
- `/Users/fernando_idwell/Projects/StockProject/StockPlanIOSApp/financeplan/financeplan/Assets.xcassets/AppIcon.appiconset/nordiq-dark-mode.png`

Only if Sentry package update/re-pin is needed:
- `/Users/fernando_idwell/Projects/StockProject/StockPlanIOSApp/financeplan/financeplan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Possibly `/Users/fernando_idwell/Projects/StockProject/StockPlanIOSApp/financeplan/financeplan.xcodeproj/project.pbxproj` if package settings change through Xcode

## Tests / validation
- Local icon validation:
  - `file` reports `PNG image data, 1024 x 1024, 8-bit/color RGB`
  - `sips -g hasAlpha` reports `hasAlpha: no`
- Archive validation before upload:
  - archive contains app icon asset compiled from current files
  - archive contains `dSYMs/Sentry.framework.dSYM`
  - `dwarfdump --uuid` on Sentry framework and Sentry dSYM match
- App Store validation:
  - upload no longer returns code `90717`
  - no missing dSYM warning for UUID `0A890EFE-F82B-3434-84F8-0CAD36E154EB`

## Risks / tradeoffs
- App Store may be validating an old archive if you re-upload without re-archiving. Always make a fresh archive after icon changes.
- `sips hasAlpha: no` is good, but Xcode asset catalog cache can still include old compiled icon data. Clean build folder/DerivedData matters.
- Missing Sentry dSYM may be a warning rather than a hard blocker, but fix is recommended for crash symbolication.
- Manual insertion of dSYM into `.xcarchive` is acceptable only if UUID matches exactly; wrong dSYM is useless.

## Open questions
- Is the current upload using a fresh archive created after the PNG conversion, or an older archive?
- Does the newly-created `.xcarchive` contain `dSYMs/Sentry.framework.dSYM`?
- Is App Store blocking the upload on Sentry dSYM, or just warning after upload?
