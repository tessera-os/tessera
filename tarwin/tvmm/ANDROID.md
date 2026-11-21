# Android window bridge

AndroidAgent and AndroidWire are regular Swift libraries; they do not link the VMM into Android. The trusted compositor/Binder adapter resolves the calling app and window from the OS, not from IDs supplied by an APK. One authenticated, ordered channel per (VM job, app, epoch) carries requests. Host control creates the channel from the bound endpoint, checks host grants and owns MosaicDisplay surfaces. A guest cannot send a host handle or choose another app by changing a field.

A version-1 record is little endian: version:u8, operation:u8, reserved:u16=0, payloadLength:u32 (max 65536), epoch:u64, sequence:u64, window:u64, grantToken:u64, payload. Frame and cap on the stream before allocating the payload. A synchronous exchange returns success/rejection bound to the request; a lost ACK terminates the channel. Restart requires fresh authenticated endpoints; close the old endpoint before admitting a replacement. Only host input messages flow in the opposite direction. Host-generated tokens must be unguessable and job-bound. Picker and camera backends operate on the resolved grant, not a guest pathname or device name.

SwiftPM tests exercise the agent and host together on macOS. AOSP integration, compositor and Binder hooks, authenticated transport, scoped host services, a bootable Android image and a physical run are still required.
