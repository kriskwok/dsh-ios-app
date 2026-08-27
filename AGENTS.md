# DSH iOS App

## Standing workflow (user preference)
After every code change, automatically build and install to the connected iPhone 13 Pro — do not ask for confirmation.

```bash
# 1. Build for device (DerivedData under /tmp/dsh-build for easy .app lookup)
xcodebuild -project DSHIOSApp.xcodeproj -scheme DSHIOSApp \
  -destination 'platform=iOS,id=81722BD9-2099-5AD8-9583-E8B60E0DC2F8' \
  -derivedDataPath /tmp/dsh-build -allowProvisioningUpdates -quiet build

# 2. Install to device
xcrun devicectl device install app \
  --device 81722BD9-2099-5AD8-9583-E8B60E0DC2F8 \
  /tmp/dsh-build/Build/Products/Debug-iphoneos/DSHIOSApp.app
```

- Code signing: Automatic, team `K9GJS8JXMH`, bundle id `app.dsh.mobile.client`.
- If the device is not connected, list with `xcrun devicectl list devices` and update the destination id.
