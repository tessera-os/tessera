# macOS MosaicDisplay output

Create a `MacDisplayOutput` for each output ID with the selected Metal device
and a retained implementation of `MacDisplayTransport`. Attach its `makeView()`
to the Tessera.app window. The view starts its display link and reports
pixel dimensions, backing scale, refresh rate, and generation changes. Call
`stop()` when closing the output. An app hosting the `CAMetalLayer` itself
instead supplies the mode and calls `start()` and `stop()`.

The app forwards mode and display-link timing to the driver. On receiving a
driver-owned composition frame it calls `receive` with the imported IOSurface
and frame identity. The view only reports presentation for the matching
drawable callback with a finite, positive `presentedTime`; the driver copy
and the window blit are not presentation. Host transport (including XPC
authorization and IOSurface transfer) is provided by Tessera.app.

Run `swift test` on macOS 26 or later in a logged-in window session with a
Metal device, or `swift run mac-display-demo` for the standalone Mosaic
sample. The demo uses local quota and fence adapters; it does not run Tarwin.
