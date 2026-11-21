import Foundation
import Darwin
import TesseraHostKit
import TarwinTaskTransport

var bootstrap: mach_port_t = 0
guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS,
      case .success(let ports) = TaskCheckIn.send(bootstrap: bootstrap) else { exit(1) }
guard task_set_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, 0) == KERN_SUCCESS else { exit(1) }
_ = mach_port_deallocate(mach_task_self_, bootstrap)
let lock = NSLock()
var started = false
while true {
    let result = TaskCommandTransport.serveOne(on: ports.commandReceive) { command, _ in
        switch command {
        case .resumeThread(let id) where id == 1:
            lock.lock(); let launch = !started; started = true; lock.unlock()
            if launch {
                DispatchQueue.global().async {
                    do {
                        _ = try GateWire.call(on: ports.gateSend, number: DemoCall.console)
                        for scalar in "Hello from a real child process!".unicodeScalars {
                            _ = try GateWire.call(on: ports.gateSend, number: DemoCall.display, value: UInt64(scalar.value))
                        }
                        while true {
                            let input = try GateWire.call(on: ports.gateSend, number: DemoCall.input)
                            if input.result.first != 0 {
                                _ = try GateWire.call(on: ports.gateSend, number: DemoCall.display, value: input.result.first)
                            }
                            Thread.sleep(forTimeInterval: 0.03)
                        }
                    } catch { exit(2) }
                }
            }
            return KERN_SUCCESS
        case .terminate: return KERN_SUCCESS
        default: return KERN_NOT_SUPPORTED
        }
    }
    if case .success(.terminate) = result { exit(0) }
}
