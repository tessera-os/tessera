# tvgpu guest driver

The guest encodes checked [MosaicDisplay v1](../../tarwin-gpu/MosaicDisplay.md) commands for Metal surfaces. One serial lane per grant holds a frame through GPU completion and compositor release. TvGpuGuest needs no Apple SDK. TVISA delivery binaries still require verification; this profile does not translate shaders or implement arbitrary Metal pipelines.

MosaicMetal runs in a hosted Metal driver. It issues real clear and blit commands and composes ready surfaces into a private BGRA8 output. Surface tests compare every output pixel on an actual Metal device, including overlaps and clipping. Input is resolved against the latched layout, not an in-progress frame. Run `swift test` on macOS; no Metal device means skipped GPU evidence, not a pass. `TARWIN_MOSAIC_CAPTURE` can name a PPM file for the composed texture readback.

Platform bindings still supply charged nonaliasing allocations, retained context grants, completion signaling, physical display generation/latch and scanout retirement. No whole-API compatibility, physical scanout or latency result is claimed.
