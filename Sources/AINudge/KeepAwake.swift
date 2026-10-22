import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep, like Caffeine or Theine. It can't stop sleep when the lid is
/// closed on battery; nothing short of an external display can.
@MainActor
final class KeepAwake {
    enum Until: Equatable {
        case forever
        case date(Date)
    }

    private(set) var until: Until?
    private var assertion: IOPMAssertionID = 0

    var isOn: Bool { until != nil }

    func start(_ until: Until, letDisplaySleep: Bool) {
        stop()
        let type = letDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "AI Nudge: keep awake" as CFString, &assertion)
        if ok == kIOReturnSuccess { self.until = until }
    }

    func stop() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        until = nil
    }

    /// Ends it when the time is up or the battery is low; says why if it did.
    func check(stopOnLowBattery: Bool) -> String? {
        guard let until else { return nil }
        if case .date(let end) = until, end <= Date() {
            stop()
            return "keep awake: time's up"
        }
        if stopOnLowBattery, KeepAwake.batteryLow() {
            stop()
            return "keep awake: stopped, battery is below 10%"
        }
        return nil
    }

    /// On battery power at 10% or less.
    static func batteryLow() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let level = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            if level <= 10 { return true }
        }
        return false
    }
}
