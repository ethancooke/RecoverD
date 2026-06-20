# Privacy

**RecoverD collects nothing.** It is an offline, local tool.

## The short version

All recovery happens locally on your Mac. RecoverD has no servers, no accounts, no telemetry, no
analytics, and no crash reporting, and it makes **no network connections**.

## What RecoverD reads, and where it goes

- **Device contents.** RecoverD reads raw blocks from the external device or image file you point
  it at. Those bytes, the recovered-file metadata, and any previews/thumbnails live **only in
  RAM**. They are never written to disk, sent off the device, or transmitted anywhere.
- **Explicit export is the only write.** The single way recovered file *contents* reach your disk
  is when you select files and choose **Recover to Disk**, picking the destination yourself. The
  source device is never imaged or copied.
- **Secure wipe.** When you clear results or quit, in-memory recovery data (including transient
  `SecureData` buffers) is securely wiped. Results are **not** retained across launches.

## Permissions RecoverD requests

- **Admin authorization (`authopen`).** Reading a real device (`/dev/rdisk*`) requires one admin
  prompt per session to obtain a read-only file descriptor. This is used solely to read the device
  you selected; scanning a `.dmg`/raw image file needs no privilege at all.
- **File access for export.** Writing recovered files uses the destination folder you choose. No
  other location is written.

## What RecoverD deliberately does not do

- No auto-mounting or auto-opening of recovered files.
- No caching of recovered content to a temp directory.
- No Spotlight indexing of recovered content.
- No execution of anything extracted from the source device.

If network-dependent functionality (e.g. an optional update check) is ever added, it will be
**opt-in** and clearly disclosed here first.
