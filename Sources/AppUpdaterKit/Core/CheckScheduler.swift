import Foundation

/// 定时检查的设置快照（纯数据，与持久化解耦，测试和调度判定都用它）。
public struct CheckSchedule: Equatable, Sendable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int

    public init(isEnabled: Bool, hour: Int, minute: Int) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
    }
}

/// 「现在该不该触发一次定时检查」的判定逻辑。
///
/// 纯函数、日历可注入：所有规则都能用合成日期断言，测试不需要真等时间。
/// 默认使用 `autoupdatingCurrent`：菜单栏进程长期不退出，用户跨时区后必须立刻按新本地时间算。
public struct CheckPlanner: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    /// 某一天计划检查的时刻。
    ///
    /// 极端情况（夏令时切换导致那一分钟不存在）会得到一个别的时刻或 `nil`，
    /// 调用方把 `nil` 当「今天没有可触发的时刻」处理即可，不值得为它猜一个值。
    public func scheduledDate(on date: Date, schedule: CheckSchedule) -> Date? {
        calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: date)
    }

    public func isSameDay(_ date: Date?, as other: Date) -> Bool {
        guard let date else { return false }
        return calendar.isDate(date, inSameDayAs: other)
    }

    /// 核心判定：`now` 时刻是否该触发一次定时检查。
    ///
    /// 先守「同一天内不重复」；再找 `now` 之前最近一个计划时刻：今天尚未到点时取昨天，
    /// 今天已到点时取今天。只要这个 occurrence 比上次满足计划的检查开始时刻/本次触发新，就该补查。
    /// 因此周一睡过 10:00、周二 08:00 才唤醒，也会立即补周一那次，不会拖到周二 10:00。
    public func isDue(
        schedule: CheckSchedule,
        lastSatisfied: Date?,
        lastTriggered: Date?,
        now: Date
    ) -> Bool {
        guard schedule.isEnabled else { return false }
        guard !isSameDay(lastSatisfied, as: now), !isSameDay(lastTriggered, as: now) else { return false }
        guard let occurrence = latestOccurrence(onOrBefore: now, schedule: schedule) else { return false }
        if let lastSatisfied, lastSatisfied >= occurrence { return false }
        if let lastTriggered, lastTriggered >= occurrence { return false }
        return true
    }

    /// `now` 之前（含当前）的最近一个计划时刻。
    private func latestOccurrence(onOrBefore now: Date, schedule: CheckSchedule) -> Date? {
        if let today = scheduledDate(on: now, schedule: schedule), today <= now {
            return today
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        return scheduledDate(on: yesterday, schedule: schedule)
    }

    /// 下一次计划时刻。`now` 在今天时刻之前返回今天，否则返回明天。
    public func nextOccurrence(after now: Date, schedule: CheckSchedule) -> Date? {
        if let today = scheduledDate(on: now, schedule: schedule), now < today {
            return today
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return scheduledDate(on: tomorrow, schedule: schedule)
    }
}
