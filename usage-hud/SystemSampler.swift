import Foundation
import Darwin
import IOKit.ps

final class SystemSampler {
    private var previousBusy: UInt64 = 0
    private var previousTotal: UInt64 = 0
    private var previousNetwork: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    // ゆっくりしか動かない指標(バッテリー/ディスク)は 2 秒ごとに引き直さず、前回値を使い回す
    private var slowCache: SlowCache?
    private static let slowInterval: TimeInterval = 30

    /// バッテリーの無い Mac では battery が常に nil になるため、値の有無ではなく
    /// 「どの項目を実際に引いたか」でキャッシュのヒットを判定する
    private struct SlowCache {
        var battery: BatterySample?
        var disk: DiskSample?
        var sampled: Set<DisplayItem>
        var at: Date
    }

    /// 有効な項目だけを取る。無効な指標のカーネル統計呼び出しは一切行わない
    func sample(enabled: Set<DisplayItem>) -> SystemSample {
        var sample = SystemSample(cpuPercent: nil, memUsedBytes: nil, memTotalBytes: nil, sampledAt: Date())

        if enabled.contains(.cpu) {
            sample.cpuPercent = cpuPercent()
        } else {
            // 無効の間は差分の基準が古くなるので捨てる(再度有効にしたときは次回から実測値になる)
            previousBusy = 0
            previousTotal = 0
        }

        if enabled.contains(.memory) {
            let memory = memoryBreakdown()
            sample.memUsedBytes = memory.active + memory.wired + memory.compressed
            sample.memTotalBytes = ProcessInfo.processInfo.physicalMemory
            sample.memActiveBytes = memory.active
            sample.memWiredBytes = memory.wired
            sample.memCompressedBytes = memory.compressed
        }

        if enabled.contains(.network) {
            sample.network = networkSample()
        } else {
            previousNetwork = nil
        }

        let wanted = enabled.intersection([.battery, .disk])
        if wanted.isEmpty {
            slowCache = nil
        } else {
            let slow = slowValues(wanted)
            sample.battery = slow.battery
            sample.disk = slow.disk
        }
        return sample
    }

    private func slowValues(_ wanted: Set<DisplayItem>) -> (battery: BatterySample?, disk: DiskSample?) {
        // 直前の取得で無効だった項目はキャッシュに入っていないので、その場合だけ引き直す
        if let cache = slowCache,
           Date().timeIntervalSince(cache.at) < Self.slowInterval,
           wanted.isSubset(of: cache.sampled) {
            // キャッシュには今より広い範囲が入っていることがあるので、要求された項目だけ返す
            return (wanted.contains(.battery) ? cache.battery : nil,
                    wanted.contains(.disk) ? cache.disk : nil)
        }
        let battery = wanted.contains(.battery) ? batterySample() : nil
        let disk = wanted.contains(.disk) ? diskSample() : nil
        slowCache = SlowCache(battery: battery, disk: disk, sampled: wanted, at: Date())
        return (battery, disk)
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
        // グローバル変数の vm_kernel_page_size は並行アクセス安全でないため関数版で引く
        var kernelPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &kernelPageSize) == KERN_SUCCESS else {
            return (0, 0, 0)
        }
        let pageSize = UInt64(kernelPageSize)
        return (UInt64(stats.active_count) * pageSize,
                UInt64(stats.wire_count) * pageSize,
                UInt64(stats.compressor_page_count) * pageSize)
    }

    /// 内蔵バッテリーの状態。デスクトップ機など内蔵バッテリーが無い場合は nil
    private func batterySample() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }

            // 算出中は -1 が返る。そのまま出すと「-1 分」になるので落とす
            func minutes(_ key: String) -> Int? {
                guard let value = description[key] as? Int, value >= 0 else { return nil }
                return value
            }
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            return BatterySample(
                percent: Double(current) / Double(capacity) * 100,
                isCharging: isCharging,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesToEmpty: isCharging ? nil : minutes(kIOPSTimeToEmptyKey),
                minutesToFull: isCharging ? minutes(kIOPSTimeToFullChargeKey) : nil,
                health: description[kIOPSBatteryHealthKey] as? String)
        }
        return nil
    }

    /// 起動ボリュームの使用量。空き容量は Finder と同じ「重要な用途に使える容量」を採る
    private func diskSample() -> DiskSample? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey,
        ]),
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let free = UInt64(clamping: values.volumeAvailableCapacityForImportantUsage ?? 0)
        let totalBytes = UInt64(total)
        return DiskSample(
            usedBytes: totalBytes > free ? totalBytes - free : 0,
            totalBytes: totalBytes,
            freeBytes: free,
            volumeName: values.volumeName)
    }

    /// 物理インターフェースの累計バイト数の差分から速度を出す
    private func networkSample() -> NetworkSample? {
        guard let counters = networkCounters() else { return nil }
        let now = Date()
        defer { previousNetwork = (counters.inBytes, counters.outBytes, now) }
        guard let previous = previousNetwork else {
            return NetworkSample(inBytesPerSecond: 0, outBytesPerSecond: 0,
                                 totalInBytes: counters.inBytes, totalOutBytes: counters.outBytes)
        }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else {
            return NetworkSample(inBytesPerSecond: 0, outBytesPerSecond: 0,
                                 totalInBytes: counters.inBytes, totalOutBytes: counters.outBytes)
        }
        // インターフェースの上げ下げでカウンタが巻き戻ることがあるので、減っていたら 0 とみなす
        func rate(_ current: UInt64, _ old: UInt64) -> Double {
            current >= old ? Double(current - old) / elapsed : 0
        }
        return NetworkSample(
            inBytesPerSecond: rate(counters.inBytes, previous.inBytes),
            outBytesPerSecond: rate(counters.outBytes, previous.outBytes),
            totalInBytes: counters.inBytes,
            totalOutBytes: counters.outBytes)
    }

    private func networkCounters() -> (inBytes: UInt64, outBytes: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            // 統計はリンク層のエントリにだけ入る。物理インターフェース(Wi-Fi / Ethernet /
            // USB アダプタ)は en* で、VPN(utun*)・ブリッジ(bridge*)・AirDrop(awdl*/llw*)は
            // 実体の en* と同じ通信を重ねて数えてしまうため足さない
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let name = interface.ifa_name,
                  name[0] == 101 && name[1] == 110, // Optimize: avoid String allocations in 2s loop by checking "en" directly ('e' = 101, 'n' = 110)
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            inBytes += UInt64(data.pointee.ifi_ibytes)
            outBytes += UInt64(data.pointee.ifi_obytes)
        }
        return (inBytes, outBytes)
    }
}
