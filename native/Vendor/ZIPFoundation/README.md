ZIPFoundation 0.9.20 source at commit `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`.
`Sources/` and `LICENSE` are copied unchanged. `Package.swift` selects the
Linux CZLib dependency by **target** platform so SwiftPM can cross-build iOS
from the Linux host. The upstream manifest selects by host `canImport`, which
would pass Linux `.so` paths to the iOS linker. The upstream privacy resource
is retained and bundled.
