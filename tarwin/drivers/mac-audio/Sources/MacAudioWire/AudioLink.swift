import Darwin
import XPC

public enum AudioLinkError: Error, Equatable {
  case allocation(Int32)
  case invalidObject
}

private final class AudioMapping {
  let address: UnsafeMutableRawPointer
  let count: Int
  init(address: UnsafeMutableRawPointer, count: Int) { self.address = address; self.count = count }
  deinit { munmap(address, count) }
}

/// A ring plus the XPC envelope and mapping that back it. Retained ring views keep their mapping alive.
public final class AudioLink {
  public let endpoint: AudioEndpoint
  public let ring: AudioRing
  public let object: xpc_object_t

  public init(endpoint: AudioEndpoint, configuration: AudioConfiguration, capacity: Int) throws {
    guard let needed = AudioRing.requiredBytes(capacity: capacity, configuration: configuration) else {
      throw AudioError.configuration
    }
    let page = Int(getpagesize())
    let (rounded, overflow) = needed.addingReportingOverflow(page - 1)
    guard !overflow else { throw AudioError.configuration }
    let count = rounded / page * page
    guard let address = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0),
      address != MAP_FAILED else { throw AudioLinkError.allocation(errno) }
    let mapping = AudioMapping(address: address, count: count)
    let memory = xpc_shmem_create(address, count)
    AudioRing.initialize(region: address, capacity: capacity, configuration: configuration, byteCount: count)
    guard let ring = AudioRing(region: address, byteCount: count, retaining: mapping) else {
      throw AudioError.configuration
    }
    let object = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(object, "tw.shmem", memory)
    for (key, value) in [("tw.version", UInt64(1)), ("tw.endpoint", UInt64(endpoint.rawValue)),
      ("tw.rate", UInt64(configuration.sampleRate)), ("tw.channels", UInt64(configuration.channels)),
      ("tw.format", UInt64(configuration.format.rawValue)), ("tw.capacity", UInt64(capacity))] {
      xpc_dictionary_set_uint64(object, key, value)
    }
    self.endpoint = endpoint; self.ring = ring; self.object = object
  }

  public init(attaching object: xpc_object_t) throws {
    guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { throw AudioLinkError.invalidObject }
    func number(_ key: String) throws -> UInt32 {
      guard let value = xpc_dictionary_get_value(object, key), xpc_get_type(value) == XPC_TYPE_UINT64,
        let result = UInt32(exactly: xpc_uint64_get_value(value)) else { throw AudioLinkError.invalidObject }
      return result
    }
    guard try number("tw.version") == 1,
      let endpoint = AudioEndpoint(rawValue: try number("tw.endpoint")),
      let format = PCMFormat(rawValue: try number("tw.format")),
      let configuration = AudioConfiguration(sampleRate: try number("tw.rate"),
        channels: try number("tw.channels"), format: format),
      let memory = xpc_dictionary_get_value(object, "tw.shmem"), xpc_get_type(memory) == XPC_TYPE_SHMEM else {
      throw AudioLinkError.invalidObject
    }
    let capacity = Int(try number("tw.capacity"))
    guard AudioRing.requiredBytes(capacity: capacity, configuration: configuration) != nil else {
      throw AudioLinkError.invalidObject
    }
    var address: UnsafeMutableRawPointer?
    let count = xpc_shmem_map(memory, &address)
    guard count > 0, let address else { throw AudioLinkError.invalidObject }
    let mapping = AudioMapping(address: address, count: count)
    guard let ring = AudioRing(region: address, byteCount: count, retaining: mapping),
      ring.configuration == configuration, ring.capacity == capacity else { throw AudioLinkError.invalidObject }
    self.endpoint = endpoint; self.ring = ring; self.object = object
  }
}
