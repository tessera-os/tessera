import AudioToolbox
import CoreAudio
import MacAudioWire

final class HALUnit {
  let processor: AudioProcessor
  let endpoint: AudioEndpoint
  private(set) var unit: AudioUnit?
  private let scratch: UnsafeMutablePointer<Float>
  private let maximumFrames: UInt32 = 4096
  init(processor: AudioProcessor, endpoint: AudioEndpoint) {
    self.processor = processor; self.endpoint = endpoint
    scratch = .allocate(capacity: 8192); scratch.initialize(repeating: 0, count: 8192)
  }
  deinit { close(); scratch.deinitialize(count: 8192); scratch.deallocate() }
  static func defaultDevice(_ endpoint: AudioEndpoint) throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: endpoint == .playback ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard status == noErr else { throw AudioError.coreAudio(status) }
    guard device != kAudioObjectUnknown else { throw AudioError.noDevice }
    return device
  }
  private func check(_ status: OSStatus) throws {
    if status != noErr { throw AudioError.coreAudio(status) }
  }
  func start() throws {
    close()
    let device = try Self.defaultDevice(endpoint)
    var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { throw AudioError.noDevice }
    var instance: AudioUnit?
    try check(AudioComponentInstanceNew(component, &instance))
    guard let instance else { throw AudioError.noDevice }
    unit = instance
    do {
      var input: UInt32 = endpoint == .capture ? 1 : 0
      var output: UInt32 = endpoint == .playback ? 1 : 0
      try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &input, 4))
      try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &output, 4))
      var selected = device
      try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, 4))
      let config = processor.ring.configuration
      var format = AudioStreamBasicDescription(mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: config.channels * 4,
        mFramesPerPacket: 1, mBytesPerFrame: config.channels * 4, mChannelsPerFrame: config.channels,
        mBitsPerChannel: 32, mReserved: 0)
      try check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
        endpoint == .playback ? kAudioUnitScope_Input : kAudioUnitScope_Output,
        endpoint == .playback ? 0 : 1, &format, UInt32(MemoryLayout.size(ofValue: format))))
      var limit = maximumFrames
      try check(AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &limit, 4))
      var callback = AURenderCallbackStruct(inputProc: { context, flags, time, _, frames, data in
        let owner = Unmanaged<HALUnit>.fromOpaque(context).takeUnretainedValue()
        return owner.process(flags: flags, time: time, frames: frames, data: data)
      }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
      try check(AudioUnitSetProperty(instance,
        endpoint == .playback ? kAudioUnitProperty_SetRenderCallback : kAudioOutputUnitProperty_SetInputCallback,
        endpoint == .playback ? kAudioUnitScope_Input : kAudioUnitScope_Global, 0,
        &callback, UInt32(MemoryLayout.size(ofValue: callback))))
      try check(AudioUnitInitialize(instance))
      try check(AudioOutputUnitStart(instance))
    } catch { close(); throw error }
  }
  func close() {
    if let unit {
      AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
      self.unit = nil
    }
  }
  private func process(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    time: UnsafePointer<AudioTimeStamp>, frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard frames <= maximumFrames else { return kAudio_ParamError }
    let channels = Int(processor.ring.configuration.channels), count = Int(frames) * channels
    let timestamp = AudioWire.nowNs()
    if endpoint == .playback {
      guard let data, data.pointee.mNumberBuffers == 1, let memory = data.pointee.mBuffers.mData,
        Int(data.pointee.mBuffers.mDataByteSize) >= count * 4 else { return kAudio_ParamError }
      processor.render(into: UnsafeMutableBufferPointer(start: memory.assumingMemoryBound(to: Float.self), count: count),
        frames: Int(frames), timestampNs: timestamp)
      return noErr
    }
    guard let unit else { return kAudio_ParamError }
    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
      mDataByteSize: UInt32(count * 4), mData: scratch))
    let status = AudioUnitRender(unit, flags, time, 1, frames, &list)
    if status == noErr {
      processor.capture(UnsafeBufferPointer(start: scratch, count: count), frames: Int(frames), timestampNs: timestamp)
    }
    return status
  }
}
