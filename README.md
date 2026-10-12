# Mac Utilities

A native macOS menu bar app scaffold for the network activity monitor described in [the PRD](hl-docs/mac-utilities-prd.md).

## Open and run

1. Open `MacUtilities.xcodeproj` in Xcode.
2. Select the `Mac Utilities` scheme and `My Mac` run destination.
3. Run the app. It appears in the menu bar as **Setup Needed**.

This is an initial UI scaffold. It does not measure or store network traffic yet. The Network Extension targets, app-group configuration, signing, and monitoring controls remain to be implemented and validated for the target MacBook. The generated bundle identifier (`com.example.Mac-Utilities`) is a placeholder for local development.
