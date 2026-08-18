import Foundation
import Darwin

final class SystemSampler {
    private var previousBusy: UInt64 = 0
    private var previousTotal: UInt64 = 0

    func sample() -> SystemSample {
        let memory = memoryBreakdown()
        return SystemSample(
            cpuPercent: cpuPercent(),
            memUsedBytes: memory.active + memory.wired + memory.compressed,
            memTotalBytes: ProcessInfo.processInfo.physicalMemory,
            sampledAt: Date(),
            memActiveBytes: memory.active,
            memWiredBytes: memory.wired,
            memCompressedBytes: memory.compressed)
    }

    private func cpuPercent() -> Double {
        var count = mach_msg_type_number_t(0)
        var cpuCount = natural_t(0)
        var info: processor_info_array_t?
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count)
        guard result == KERN_SUCCESS, let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer {
            previousBusy = busy
            previousTotal = total
        }
        let deltaTotal = total &- previousTotal
        guard previousTotal > 0, deltaTotal > 0 else { return 0 }
        return Double(busy &- previousBusy) / Double(deltaTotal) * 100
    }

    // アクティビティモニタの「使用済みメモリ」に相当する内訳: active + wired + compressed
    private func memoryBreakdown() -> (active: UInt64, wired: UInt64, compressed: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(stats.active_count) * pageSize,
                UInt64(stats.wire_count) * pageSize,
                UInt64(stats.compressor_page_count) * pageSize)
    }
}
