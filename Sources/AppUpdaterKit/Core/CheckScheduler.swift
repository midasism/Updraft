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
/// 三条规则缺一不可：
///   1. 开关关着永远不触发；
///   2. 当天的计划时刻还没到不触发（到了、或已经错过——合盖/关机睡过去了——都算该补）；
///   3. 今天已经查过（手动或定时，看 `lastChecked`）或调度器自己已经触发过（看
///      `lastTriggered`，防检查在跑期间重复开火）就不再触发。
public struct CheckPlanner: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
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
    /// 「错过时段的补查」不是一条单独的规则——时刻已过且今天没查过，本身就是该查，
    /// 唤醒后第一次轮询自然接住它（验收要求恢复后 5 分钟内，实际是立即）。
    public func isDue(
        schedule: CheckSchedule,
        lastChecked: Date?,
        lastTriggered: Date?,
        now: Date
    ) -> Bool {
        guard schedule.isEnabled else { return false }
        guard let dueAt = scheduledDate(on: now, schedule: schedule), now >= dueAt else { return false }
        return !isSameDay(lastChecked, as: now) && !isSameDay(lastTriggered, as: now)
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
