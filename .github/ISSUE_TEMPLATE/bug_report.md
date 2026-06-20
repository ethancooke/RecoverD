---
name: Bug report
about: Something in RecoverD is broken or behaves incorrectly
title: ""
labels: bug
assignees: ""
---

**What happened**
A clear, specific description of the bug.

**What you expected**
What you expected to happen instead.

**Steps to reproduce**
1. ...
2. ...
3. ...

**Scan details**
- Scan mode: [ ] Quick [ ] Deep / Carving
- Carve toggles (deep only): [ ] Try harder [ ] Include camera RAW
- Source: [ ] real device (`/dev/rdisk*`) [ ] `.dmg` / raw image file
- Source file system (if known): exFAT / FAT12-16-32 / other
- File type(s) involved (if about a specific recovered/previewed file):

**Environment**
- macOS version:
- Mac model (must be Apple Silicon):
- Build: [ ] `swift run` (debug) [ ] release build [ ] packaged `.app`
- RecoverD version / commit:

**Logs / screenshots**
Any console output or screenshots. Do **not** attach recovered file contents or disk images.

> Security note: if this is a security vulnerability (e.g. data written to the host outside an
> explicit export), do **not** file it here — use the Security tab → "Report a vulnerability".
> See [SECURITY.md](../../SECURITY.md).
