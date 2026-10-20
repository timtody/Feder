#if DEBUG
import Darwin
import Foundation
#if os(iOS)
import os
#endif

/// The process's own resource counters, read at one moment (Debug builds only; PipelineTrace samples them, FED-195):
/// - `task_info(TASK_POWER_INFO_V2)`, public: CPU time (user + system), the part on performance cores, GPU time, and
///   the energy iOS attributes to Feder. Measured on an M5 Mac (4 cores × 2 s spinning, then 2 s of a Metal kernel):
///   CPU time right once converted from ticks, CPU energy plausible (18.8 J, 9.4 W), but GPU time and GPU energy 0:
///   the GPU's work isn't attributed to the process there. The iPhone may differ; the trace shows what it reports;
/// - `proc_pid_rusage` v6 (declared here: the iOS SDK has the struct in sys/resource.h but not libproc's function):
///   "billed" energy, which includes work daemons did on Feder's behalf, and the Neural Engine's memory for Feder.
/// Apple's speech recognition runs in a system process, so most of its work is outside these; Neural Engine *time* is
/// not exposed at all. All counters are cumulative since launch: a sample's rate is the difference to the one before.
nonisolated struct ResourceCounters: Sendable, Codable {
    var uptime: Double                  // seconds, monotonic (systemUptime)
    var footprint: UInt64               // bytes, phys_footprint: what iOS's memory limit counts
    var available: UInt64               // bytes left before that limit (os_proc_available_memory; 0 on the Mac)
    var cpuNanoseconds: UInt64          // user + system, all threads, all cores
    var performanceNanoseconds: UInt64  // the part on performance cores
    var gpuNanoseconds: UInt64          // task_gpu_utilisation
    var energyNanojoules: UInt64        // task_energy: what iOS attributes to this process
    var billedEnergyNanojoules: UInt64  // ri_billed_energy: including work billed to it by daemons (0 if unreadable)
    var neuralFootprint: UInt64         // bytes on the Neural Engine (ri_neural_footprint; 0 if unreadable)
    var thermal: Int                    // ProcessInfo.ThermalState.rawValue
    var battery: Float                  // 0…1, -1 unknown (UIDevice, read by the caller on iOS)

    /// Now. `battery` is the caller's (UIDevice is main-actor only).
    static func now(battery: Float = -1) -> ResourceCounters {
        var counters = ResourceCounters(uptime: ProcessInfo.processInfo.systemUptime, footprint: 0, available: 0,
                                        cpuNanoseconds: 0, performanceNanoseconds: 0, gpuNanoseconds: 0,
                                        energyNanojoules: 0, billedEnergyNanojoules: 0, neuralFootprint: 0,
                                        thermal: ProcessInfo.processInfo.thermalState.rawValue, battery: battery)
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        if withUnsafeMutablePointer(to: &vm, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }) == KERN_SUCCESS {
            counters.footprint = vm.phys_footprint
        }
        #if os(iOS)
        counters.available = UInt64(os_proc_available_memory())
        #endif
        var power = task_power_info_v2_data_t()
        var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
        if withUnsafeMutablePointer(to: &power, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &powerCount)
            }
        }) == KERN_SUCCESS {
            // CPU and P-core times are in mach ticks, not nanoseconds (measured on an M5: 0.19 "s" for 4 cores × 2 s
            // until converted; 125/3 ns per tick on Apple silicon).
            counters.cpuNanoseconds = Self.nanoseconds(power.cpu_energy.total_user + power.cpu_energy.total_system)
            counters.performanceNanoseconds = Self.nanoseconds(power.task_ptime)
            counters.gpuNanoseconds = power.gpu_energy.task_gpu_utilisation
            #if !targetEnvironment(simulator)
            counters.energyNanojoules = power.task_energy      // declared for ARM devices only, not the simulator's SDK
            #endif
        }
        var usage = rusage_info_v6()
        if withUnsafeMutablePointer(to: &usage, {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage_(getpid(), RUSAGE_INFO_V6, $0)
            }
        }) == 0 {
            counters.billedEnergyNanojoules = usage.ri_billed_energy
            counters.neuralFootprint = usage.ri_neural_footprint
            // The same count as task_energy (equal on the M5 test to the hundredth of a joule).
            if counters.energyNanojoules == 0 { counters.energyNanojoules = usage.ri_energy_nj }
        }
        return counters
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 { ticks / timebase.denom * timebase.numer }
}

/// libproc's proc_pid_rusage, which the iOS SDK's headers don't declare (the symbol is in libSystem on iOS as on the
/// Mac). Debug builds only.
@_silgen_name("proc_pid_rusage")
nonisolated private func proc_pid_rusage_(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>) -> Int32
#endif
