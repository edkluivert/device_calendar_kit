// iOS side of device_calendar_kit: EventKit, exposed to Dart as C functions.
//
// Dart resolves the @_cdecl functions below from the app binary
// (lib/src/bindings.dart). Every reply goes back through one dispatcher
// slot registered with the framework, always on the main thread and never
// from inside the Dart call itself. JSON on the wire.

import EventKit
import Foundation
import UIKit

private func dnLog(_ msg: String) { print("[DeviceCalendarKit] \(msg)") }

// MARK: - Dispatcher slot

// Heap-allocated so its address never moves: the framework keeps a pointer
// to it and writes 0 into it when a hot restart begins.
private let dispatcherSlot: UnsafeMutablePointer<Int64> = {
    let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    p.pointee = 0
    return p
}()
private var slotRegistered = false

private typealias Dispatch = @convention(c) (Int64, Int32, UnsafePointer<CChar>) -> Void

/// Delivers `(token, type, payload)` to Dart on the next main-loop turn,
/// reading the slot fresh so a reply after a hot restart is dropped instead
/// of calling a deleted pointer.
private func fireToDart(token: Int64, type: Int32, payload: String) {
    DispatchQueue.main.async {
        let addr = dispatcherSlot.pointee
        guard addr != 0 else { return }
        payload.withCString { cStr in
            unsafeBitCast(addr, to: Dispatch.self)(token, type, cStr)
        }
    }
}

@_cdecl("DeviceCalendarKitSetDispatcher")
public func DeviceCalendarKitSetDispatcher(_ callbackPtr: Int64) {
    dispatcherSlot.pointee = callbackPtr
    if !slotRegistered {
        slotRegistered = true
        typealias RegFn = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                           "DNRegisterAsyncDispatcherSlot") {
            unsafeBitCast(sym, to: RegFn.self)(dispatcherSlot)
        } else {
            dnLog("DNRegisterAsyncDispatcherSlot not found; hot restart safety off")
        }
    }
}

/// Runs `method` and answers later under `token`. 0 when accepted, 2 for
/// an unknown method.
@_cdecl("DeviceCalendarKitInvoke")
public func DeviceCalendarKitInvoke(
    _ token: Int64,
    _ method: UnsafePointer<CChar>,
    _ argumentsJson: UnsafePointer<CChar>
) -> Int32 {
    let name = String(cString: method)
    let args = Reply.decode(String(cString: argumentsJson)) ?? [:]
    return DeviceCalendarKitPlugin.shared.handle(name, args, Reply(token: token)) ? 0 : 2
}

// MARK: - Reply

final class Reply {
    let token: Int64
    init(token: Int64) { self.token = token }

    func success(_ value: Any?) {
        fireToDart(token: token, type: 0, payload: Reply.encode(value))
    }

    func error(_ code: String, _ message: String?) {
        let payload: [String: Any] = ["code": code, "message": message ?? NSNull()]
        fireToDart(token: token, type: 1, payload: Reply.encode(payload))
    }

    static func encode(_ value: Any?) -> String {
        guard let value = value else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "null"
    }

    static func decode(_ json: String) -> [String: Any]? {
        guard !json.isEmpty, json != "null", let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return object as? [String: Any]
    }
}

// MARK: - Plugin

final class DeviceCalendarKitPlugin {
    static let shared = DeviceCalendarKitPlugin()

    // A store created before access was granted may keep seeing nothing, so
    // it is replaced after every prompt.
    private var store = EKEventStore()
    private let work = DispatchQueue(label: "device_calendar_kit", qos: .userInitiated)

    /// EventKit refuses ranges longer than four years, so longer requests
    /// are read in windows of this length.
    private let window: TimeInterval = 365 * 24 * 60 * 60

    func handle(_ method: String, _ args: [String: Any], _ reply: Reply) -> Bool {
        switch method {
        case "permissionStatus": reply.success(permissionName())
        case "requestPermission": requestPermission(reply)
        case "calendars": calendars(reply)
        case "events": events(args, reply)
        case "openSettings": openSettings(reply)
        default: return false
        }
        return true
    }

    // MARK: Permission

    private func permissionName() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "granted" // before iOS 17: full access
        case .fullAccess: return "granted"
        case .writeOnly: return "writeOnly"
        @unknown default: return "denied"
        }
    }

    private var canRead: Bool { permissionName() == "granted" }

    private func requestPermission(_ reply: Reply) {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            reply.success(permissionName())
            return
        }
        // Without its usage description iOS ends the app on the prompt.
        let key: String
        if #available(iOS 17.0, *) {
            key = "NSCalendarsFullAccessUsageDescription"
        } else {
            key = "NSCalendarsUsageDescription"
        }
        guard Bundle.main.object(forInfoDictionaryKey: key) != nil else {
            reply.error("missing_usage_description",
                        "Add \(key) to ios/Runner/Info.plist; iOS ends the app without it.")
            return
        }
        let done: (Bool, Error?) -> Void = { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.store = EKEventStore()
                if let error = error, self.permissionName() == "notDetermined" {
                    reply.error("error", error.localizedDescription)
                } else {
                    reply.success(self.permissionName())
                }
            }
        }
        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    private func openSettings(_ reply: Reply) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            reply.success(false)
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in reply.success(opened) }
        }
    }

    // MARK: Calendars

    private func calendars(_ reply: Reply) {
        guard canRead else { return denied(reply) }
        let store = self.store
        work.async {
            let list = store.calendars(for: .event)
                .sorted {
                    ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title)
                }
                .map(self.calendarMap)
            reply.success(list)
        }
    }

    private func calendarMap(_ calendar: EKCalendar) -> [String: Any] {
        var map: [String: Any] = [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "accountName": calendar.source?.title ?? "",
            "accountType": sourceTypeName(calendar),
            "readOnly": !calendar.allowsContentModifications,
            "birthdays": calendar.type == .birthday,
        ]
        if let color = argb(calendar.cgColor) { map["color"] = color }
        return map
    }

    private func sourceTypeName(_ calendar: EKCalendar) -> String {
        switch calendar.source?.sourceType {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        default: return "unknown"
        }
    }

    private func argb(_ color: CGColor?) -> Int64? {
        guard let color = color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ v: CGFloat) -> Int64 { Int64((min(max(v, 0), 1) * 255).rounded()) }
        return (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    // MARK: Events

    private func events(_ args: [String: Any], _ reply: Reply) {
        guard canRead else { return denied(reply) }
        guard let startMs = (args["start"] as? NSNumber)?.doubleValue,
              let endMs = (args["end"] as? NSNumber)?.doubleValue, endMs > startMs
        else {
            reply.error("error", "events needs a start before its end.")
            return
        }
        let ids = args["calendarIds"] as? [String]
        let store = self.store
        work.async {
            var calendars: [EKCalendar]? = nil
            if let ids = ids {
                let wanted = Set(ids)
                calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
                // nil would mean every calendar.
                if calendars!.isEmpty {
                    reply.success([Any]())
                    return
                }
            }
            let end = Date(timeIntervalSince1970: endMs / 1000)
            var from = Date(timeIntervalSince1970: startMs / 1000)
            var seen = Set<String>()
            var list: [[String: Any]] = []
            while from < end {
                let to = min(from.addingTimeInterval(self.window), end)
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
                for event in store.events(matching: predicate) {
                    let id = event.eventIdentifier ?? event.calendarItemIdentifier
                    // An event across a window edge comes back from both windows.
                    let key = "\(id)|\(event.startDate.timeIntervalSince1970)"
                    if seen.insert(key).inserted {
                        list.append(self.eventMap(event, id: id))
                    }
                }
                from = to
            }
            reply.success(list)
        }
    }

    private func eventMap(_ event: EKEvent, id: String) -> [String: Any] {
        var map: [String: Any] = [
            "eventId": id,
            "calendarId": event.calendar?.calendarIdentifier ?? "",
            "title": event.title ?? "",
            "allDay": event.isAllDay,
        ]
        if event.isAllDay {
            let calendar = Calendar.current
            let first = calendar.startOfDay(for: event.startDate)
            // EventKit ends an all-day event at 23:59:59 of its last day;
            // the wire format wants the exclusive midnight after it.
            var after = calendar.startOfDay(for: event.endDate)
            if after <= first || after != event.endDate {
                after = calendar.date(byAdding: .day, value: 1, to: after) ?? after
            }
            map["startDate"] = dayText(first)
            map["endDate"] = dayText(after)
        } else {
            map["start"] = Int64(event.startDate.timeIntervalSince1970 * 1000)
            map["end"] = Int64(event.endDate.timeIntervalSince1970 * 1000)
        }
        if let location = event.location, !location.isEmpty { map["location"] = location }
        if let notes = event.notes, !notes.isEmpty { map["notes"] = notes }
        if let rule = event.recurrenceRules?.first {
            map["recurrence"] = ["frequency": frequencyName(rule.frequency), "interval": rule.interval]
        } else if event.calendar?.type == .birthday {
            // Birthday events repeat yearly but carry no rule.
            map["recurrence"] = ["frequency": "yearly", "interval": 1]
        }
        return map
    }

    private func frequencyName(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "daily"
        }
    }

    private func dayText(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func denied(_ reply: Reply) {
        reply.error("permission_denied",
                    "Reading the calendar needs full access; permission is \(permissionName()).")
    }
}
