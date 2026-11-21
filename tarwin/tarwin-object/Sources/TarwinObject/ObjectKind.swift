// LibTessera §3.2, then Tarwin §9.2. 17–18 remain unallocated.
// fence is a Tarwin-private kind, not a DeviceKit wire type.
public enum TarwinKind {
  public static let none: UInt32 = 0
  public static let port: UInt32 = 1
  public static let event: UInt32 = 2
  public static let eventPair: UInt32 = 3
  public static let timer: UInt32 = 4
  public static let channel: UInt32 = 5
  public static let memory: UInt32 = 6
  public static let thread: UInt32 = 7
  public static let process: UInt32 = 8
  public static let job: UInt32 = 9
  public static let node: UInt32 = 10
  public static let file: UInt32 = 11
  public static let watch: UInt32 = 12
  public static let endpoint: UInt32 = 13
  public static let stream: UInt32 = 14
  public static let wakeLock: UInt32 = 15
  public static let presence: UInt32 = 16
  public static let interrupt: UInt32 = 19
  public static let mmioRange: UInt32 = 20
  public static let dmaBuffer: UInt32 = 21
  public static let iommuDomain: UInt32 = 22
  public static let deviceSlot: UInt32 = 23
  public static let virtualMachine: UInt32 = 24
  public static let virtualCpu: UInt32 = 25
  public static let probe: UInt32 = 26
  public static let resource: UInt32 = 27
  public static let service: UInt32 = 28
  public static let ring: UInt32 = 29
  public static let workInterval: UInt32 = 30
  public static let performanceSession: UInt32 = 31
  public static let fence: UInt32 = 32
}
