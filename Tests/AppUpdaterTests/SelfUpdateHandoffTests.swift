import XCTest
@testable import AppUpdaterKit

/// 自更新的换包交接。
///
/// 这一组是本次改动里风险最集中的地方：换包发生在应用**已经退出之后**，
/// 出问题时没有人能弹窗，也没有第二次机会。所以断言写得比别处细——
/// 尤其是几条"顺序不能颠倒"的性质。
final class SelfUpdateHandoffTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func makeHandoff(
        app: String = "AppUpdater",
        token: String = "38144E15"
    ) -> SelfUpdateHandoff {
        SelfUpdateHandoff(
            target: URL(fileURLWithPath: "/Applications/\(app).app", isDirectory: true),
            token: token,
            root: root
        )
    }

    private func script(_ handoff: SelfUpdateHandoff, from: String? = "0.2.1", to: String = "0.3.0") -> String {
        handoff.script(
            executableName: "AppUpdater",
            from: from,
            to: to,
            backupPath: URL(fileURLWithPath: "/Users/x/Library/Application Support/AppUpdater/Backups/com.local.appupdater/20260914-120000-0.2.1")
        )
    }

    /// 只留真正会被执行的行。
    ///
    /// 脚本里的注释刻意写得比较啰嗦，而且经常**引用它自己否定的那种写法**
    /// （比如解释"为什么不用 `pgrep -x`"）。于是任何"脚本里不许出现 X"的断言
    /// 只要直接扫全文，就会被注释误伤——断言的是反例变成了证据。
    /// 要断言"不这么做"，就得先看代码本身。
    private func codeOnly(_ handoff: SelfUpdateHandoff) -> String {
        script(handoff)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    // MARK: - 路径约定：必须能被既有的中断恢复逻辑认出

    /// 中间态文件名的形状不是随便定的：它同时是 `Installer.classifyArtifact` 认得的那种。
    /// 助手万一被强杀，应用下次启动时的残留清理（甚至抢救）能直接接管，
    /// 不需要为自更新再写第二套恢复逻辑。
    func testHandoffArtifactsAreRecognizedByStartupRecovery() {
        let handoff = makeHandoff()

        XCTAssertEqual(handoff.staged.lastPathComponent, ".AppUpdater.38144E15.new.app")
        XCTAssertEqual(handoff.displaced.lastPathComponent, ".AppUpdater.38144E15.old.app")

        let staged = Installer.classifyArtifact(handoff.staged.lastPathComponent)
        XCTAssertEqual(staged?.stem, "AppUpdater")
        XCTAssertEqual(staged?.kind, .incoming)

        let displaced = Installer.classifyArtifact(handoff.displaced.lastPathComponent)
        XCTAssertEqual(displaced?.stem, "AppUpdater")
        XCTAssertEqual(displaced?.kind, .displaced)
    }

    /// 应用名里含点的情形：stem 必须从**倒数第二个**点分段还原，不能用 dropLast 硬切。
    func testHandoffStemHandlesDotsInTheAppName() {
        let handoff = makeHandoff(app: "Foo.bar")
        XCTAssertEqual(handoff.staged.lastPathComponent, ".Foo.bar.38144E15.new.app")
        XCTAssertEqual(Installer.classifyArtifact(handoff.staged.lastPathComponent)?.stem, "Foo.bar")
    }

    /// 三个路径必须在同一个目录里——跨卷 rename 会退化成拷贝，原子性就没了。
    func testStagedAndDisplacedSitNextToTheTarget() {
        let handoff = makeHandoff()
        let directory = handoff.target.deletingLastPathComponent()
        XCTAssertEqual(handoff.staged.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(handoff.displaced.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    }

    // MARK: - 脚本内容

    func testScriptSubstitutesEveryPlaceholder() {
        let text = script(makeHandoff())
        for placeholder in ["#PID#", "#TARGET#", "#STAGED#", "#DISPLACED#", "#STATUS#",
                            "#LOG#", "#EXECUTABLE#", "#FROM#", "#TO#", "#BACKUP#",
                            "#RAWFROM#", "#RAWTO#"] {
            XCTAssertFalse(text.contains(placeholder), "占位符 \(placeholder) 没有被替换")
        }
    }

    func testScriptTargetsThisProcessAndBothPaths() {
        let handoff = makeHandoff()
        let text = script(handoff)
        XCTAssertTrue(text.contains("PID=\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertTrue(text.contains("'/Applications/AppUpdater.app'"))
        XCTAssertTrue(text.contains("'/Applications/.AppUpdater.38144E15.new.app'"))
        XCTAssertTrue(text.contains("'/Applications/.AppUpdater.38144E15.old.app'"))
    }

    /// 路径里有空格（`~/Library/Application Support/...`）必须被引住，否则 sh 会把它劈成两段。
    func testScriptQuotesPathsWithSpaces() {
        let handoff = makeHandoff()
        let text = script(handoff)
        XCTAssertTrue(text.contains("STATUS='\(root.path)/self-update-status.txt'"))

        let launched = handoff.script(
            executableName: "AppUpdater",
            from: "0.2.1",
            to: "0.3.0",
            backupPath: URL(fileURLWithPath: "/tmp/has space/backup.app")
        )
        XCTAssertTrue(launched.contains("BACKUP='/tmp/has space/backup.app'"))
    }

    func testScriptWaitsForTheAppToExitBeforeTouchingAnything() {
        let text = script(makeHandoff())
        guard let waitIndex = text.range(of: "while still_running")?.lowerBound,
              let firstMove = text.range(of: "mv \"${TARGET}\" \"${DISPLACED}\"")?.lowerBound else {
            return XCTFail("脚本里应当既有等待循环又有第一次改名")
        }
        XCTAssertLessThan(waitIndex, firstMove, "必须等应用退出之后才动包")
    }

    /// 僵尸进程对 `kill -0` 仍然有响应，但它已经死了。
    /// 只认 kill -0 的话，这种情况会白等满 60 秒然后放弃整次更新。
    func testWaitLoopDoesNotHangOnAZombieProcess() {
        let text = script(makeHandoff())
        XCTAssertTrue(text.contains("kill -0 \"${PID}\" 2>/dev/null || return 1"))
        XCTAssertTrue(text.contains("case \"${state}\" in Z*)"))
    }

    /// 等不到就放弃，不做"硬来"。超时的那条分支必须有明确的出口。
    func testScriptGivesUpWhenTheAppRefusesToQuit() {
        let text = script(makeHandoff())
        XCTAssertTrue(text.contains("\"${ticks}\" -gt 200"))
        XCTAssertTrue(text.contains("应用没有在 60 秒内退出"))
    }

    /// 应用退出后又冒出实例（用户手动重开、或另有一个 GUI 实例）时必须放弃：
    /// 那时换包会把那个实例脚下的包抽走。
    ///
    /// 判定必须按**这一个包**的路径来，不能按进程名——按名字会把"另一份副本在跑"
    /// 误伤成"应用已被重新打开"，而那在开发机上是常态。
    func testScriptAbortsWhenThisBundleIsStillInUse() {
        let text = script(makeHandoff())
        XCTAssertTrue(text.contains("lsof -- \"${TARGET}/Contents/MacOS/${EXECUTABLE}\""))
        XCTAssertTrue(text.contains("pgrep -f -- \"${TARGET}/Contents/MacOS/\""))
        XCTAssertTrue(text.contains("还有实例正在运行这一个 AppUpdater"))
    }

    /// 上一条只证明了"按路径判断"在位，还得挡住有人把它改回按进程名。
    ///
    /// 注释里写着 `pgrep -x AppUpdater` 这个反例（解释为什么不用它），所以这条
    /// **必须扫去掉注释之后的代码**——否则守住的东西正好被那句话自己顶翻。
    func testScriptNeverFallsBackToMatchingByProcessName() {
        let text = codeOnly(makeHandoff())
        XCTAssertFalse(text.contains("pgrep -x"), "按进程名判断会误伤另一份副本")
        XCTAssertFalse(text.contains("pgrep -f \"${EXECUTABLE}\""), "按名字而非路径匹配同样会误伤")
    }

    /// 两次改名都是原子的，中间任何一刻掉电都只会留下完整的旧包或完整的新包。
    func testScriptPerformsTheTwoRenamesInOrder() {
        let text = script(makeHandoff())
        guard let displace = text.range(of: "mv \"${TARGET}\" \"${DISPLACED}\"")?.lowerBound,
              let promote = text.range(of: "mv \"${STAGED}\" \"${TARGET}\"")?.lowerBound else {
            return XCTFail("两次改名都必须在脚本里")
        }
        XCTAssertLessThan(displace, promote)
    }

    /// 旧包在新包就位之后才允许被删——它是回滚的唯一依据。
    func testOldBundleIsOnlyDeletedAfterTheNewOneIsInPlace() {
        let text = script(makeHandoff())
        guard let promote = text.range(of: "mv \"${STAGED}\" \"${TARGET}\"")?.lowerBound,
              let cleanup = text.range(of: "rm -rf \"${DISPLACED}\"", options: .backwards)?.lowerBound else {
            return XCTFail("脚本里应当有新包就位与旧包清理两步")
        }
        XCTAssertLessThan(promote, cleanup, "先就位、后清理")
    }

    /// 结果先落盘、再启动应用。反过来的话，新实例会读到"进行中"——
    /// 而那一刻替换其实已经完成了。
    ///
    /// 注意两侧都取**最后一次出现**：回滚分支里也有一句 `open "${TARGET}"`，
    /// 取第一次出现会拿到那一段，断言就变成了在比两件不相干的事。
    func testSuccessIsRecordedBeforeTheAppIsLaunched() {
        let text = script(makeHandoff())
        guard let record = text.range(of: "status succeeded", options: .backwards)?.lowerBound,
              let launch = text.range(of: "open \"${TARGET}\"", options: .backwards)?.lowerBound else {
            return XCTFail("脚本里应当既有成功落盘又有启动应用")
        }
        XCTAssertLessThan(record, launch)
    }

    /// 新版包不完整时要回滚，绝不给用户留下一个打不开的应用。
    func testScriptRollsBackWhenTheNewBundleIsIncomplete() {
        let text = script(makeHandoff())
        XCTAssertTrue(text.contains("[ ! -x \"${TARGET}/Contents/MacOS/${EXECUTABLE}\" ]"))
        XCTAssertTrue(text.contains("已回滚到 ${FROM}"))
    }

    func testScriptStripsQuarantine() {
        XCTAssertTrue(script(makeHandoff()).contains("xattr -dr com.apple.quarantine"))
    }

    /// 语法错的脚本会安静地什么都不做，然后用户面对一个"点了没反应"的应用。
    /// 把 `sh -n` 挂进测试，改坏语法一定会被发现。
    func testScriptIsSyntacticallyValidShell() async throws {
        let handoff = makeHandoff()
        let file = root.appendingPathComponent("check.sh")
        try script(handoff).write(to: file, atomically: true, encoding: .utf8)

        let result = await ProcessRunner.run(executable: "/bin/sh", arguments: ["-n", file.path])
        XCTAssertTrue(result.succeeded, "sh -n 报错：\(result.stderr)")
    }

    /// 真的跑一遍助手：证明它确实会换包、会复核、会如实回写状态。
    ///
    /// 三条设计上的讲究：
    /// 1. **目标落在临时目录**，不碰 `/Applications`。真机上的包是用户的，
    ///    测试没有资格去动它——哪怕最后会恢复。
    /// 2. **PID 用一个确定不存在的值**，等待循环立刻通过，测试不会真等 60 秒。
    /// 3. **可执行文件名故意不存在**，让"这个包在不在用"的结论不受本机运行态影响；
    ///    **`open` 走假的**，否则测试会在用户桌面上蹦出个对话框。
    func testScriptActuallySwapsTheBundleAndReportsSuccess() async throws {
        let (handoff, directory, openLog) = try makeRunnableHandoff()
        let target = try makeFakeApp(in: directory, name: "AppUpdater", executable: Self.probeExecutable, content: "old")
        let staged = handoff.staged
        try makeFakeApp(at: staged, executable: Self.probeExecutable, content: "new")

        let result = await run(handoff, fakeBinDirectory: try makeFakeOpen(in: directory, log: openLog))

        XCTAssertEqual(result.exitCode, 0, "换包应当成功：\(result.stdout)\(result.stderr)")
        XCTAssertEqual(try content(ofExecutableIn: target), "new", "目标位置应当已经是新包")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "预置包应当已经就位")

        // `.old.app` 必须被清掉：它带 `.` 前缀，留在 /Applications 里就是一块隐形的磁盘占用。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".") && $0.hasSuffix(".app") }
        XCTAssertTrue(leftovers.isEmpty, "不该留下中间态文件：\(leftovers)")

        let status = SelfUpdateHandoff.consumeStatus(root: root)
        XCTAssertEqual(status?.outcome, .succeeded)
        XCTAssertEqual(status?.toVersion, "9.9.10")
        XCTAssertTrue(status?.message.contains("已升级到 9.9.10") == true)

        let opened = (try? String(contentsOf: openLog, encoding: .utf8)) ?? ""
        XCTAssertEqual(opened.trimmingCharacters(in: .whitespacesAndNewlines), target.path,
                       "装完必须把应用重新打开")
    }

    /// 新包不完整时回滚，绝不给用户留下一个打不开的应用。
    func testScriptRollsBackWhenTheStagedBundleIsBroken() async throws {
        let (handoff, directory, openLog) = try makeRunnableHandoff()
        let target = try makeFakeApp(in: directory, name: "AppUpdater", executable: Self.probeExecutable, content: "old")

        // 预置的包里没有可执行文件——正是"结构不对的包"那种情形。
        try makeFakeApp(at: handoff.staged, executable: nil, content: "broken")

        let result = await run(handoff, fakeBinDirectory: try makeFakeOpen(in: directory, log: openLog))

        XCTAssertEqual(result.exitCode, 13, "应当走「新版本包不完整」这条路：\(result.stdout)\(result.stderr)")
        XCTAssertEqual(try content(ofExecutableIn: target), "old", "必须把旧包放回原位")

        let status = SelfUpdateHandoff.consumeStatus(root: root)
        XCTAssertEqual(status?.outcome, .failed)
        XCTAssertTrue(status?.message.contains("已回滚到") == true)
    }

    /// 目标不存在（用户自己把应用删了、或路径记错了）时不能假装成功。
    func testScriptReportsFailureWhenTheTargetIsGone() async throws {
        let (handoff, directory, openLog) = try makeRunnableHandoff()
        try makeFakeApp(at: handoff.staged, executable: Self.probeExecutable, content: "new")

        let result = await run(handoff, fakeBinDirectory: try makeFakeOpen(in: directory, log: openLog))

        XCTAssertEqual(result.exitCode, 11, "应当走「移走旧版本失败」这条路：\(result.stdout)\(result.stderr)")

        let status = SelfUpdateHandoff.consumeStatus(root: root)
        XCTAssertEqual(status?.outcome, .failed)
        XCTAssertEqual(status?.fromVersion, "9.9.9")
        XCTAssertEqual(status?.toVersion, "9.9.10")
        XCTAssertTrue(status?.message.contains("无法移走旧版本") == true)
    }

    /// 放弃更新时，预置好的那份新包必须一并清掉。
    ///
    /// 真机验证时就是这么发现的：更新被拒之后，应用旁边静静躺着一份
    /// `.AppUpdater.<token>.new.app`——一份完整的新版本拷贝，而这次更新压根没发生。
    ///
    /// 这里让测试进程自己**打开**目标的可执行文件，脚本里 `lsof` 那一路就会命中，
    /// 不需要真的去起一个 App。
    func testScriptDiscardsTheStagedCopyWhenItGivesUp() async throws {
        let (handoff, directory, openLog) = try makeRunnableHandoff()
        let target = try makeFakeApp(
            in: directory, name: "AppUpdater", executable: Self.probeExecutable, content: "old"
        )
        try makeFakeApp(at: handoff.staged, executable: Self.probeExecutable, content: "new")

        let binary = target.appendingPathComponent("Contents/MacOS/\(Self.probeExecutable)")
        let handle = try FileHandle(forReadingFrom: binary)
        defer { try? handle.close() }

        let result = await run(handoff, fakeBinDirectory: try makeFakeOpen(in: directory, log: openLog))

        XCTAssertEqual(result.exitCode, 14, "包还在用就必须放弃：\(result.stdout)\(result.stderr)")
        XCTAssertEqual(try content(ofExecutableIn: target), "old", "旧包不能被碰")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: handoff.staged.path),
            "放弃之后不该留下一份完整的新包拷贝"
        )

        let status = SelfUpdateHandoff.consumeStatus(root: root)
        XCTAssertEqual(status?.outcome, .failed)
        XCTAssertTrue(status?.message.contains("还有实例正在运行这一个 AppUpdater") == true)
    }

    /// 反过来：目标已经没了的时候，预置包**不能**删——它可能是这台机器上仅存的一份。
    /// 清理的判据是"目标完好"，不是"这次没成功"。
    func testStagedCopyIsKeptWhenTheTargetIsAlreadyGone() async throws {
        let (handoff, directory, openLog) = try makeRunnableHandoff()
        try makeFakeApp(at: handoff.staged, executable: Self.probeExecutable, content: "new")

        let result = await run(handoff, fakeBinDirectory: try makeFakeOpen(in: directory, log: openLog))

        XCTAssertEqual(result.exitCode, 11, "目标不在时应当如实报错：\(result.stdout)\(result.stderr)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: handoff.staged.path),
            "目标缺失时那份预置包可能是唯一的副本，删了就真没了"
        )
    }

    // MARK: - 日志保留

    /// 日志按**修改时间**保留最近一份。
    ///
    /// 文件名里那段是随机 token，按名字排等于随机留一份——真机上看到的就是这个：
    /// 刚跑完那次的日志排在旧日志后面，被当成"过期"清掉了，而它恰恰是唯一的现场。
    func testCleanUpKeepsTheNewestLogNotTheAlphabeticallyLastOne() throws {
        let older = root.appendingPathComponent("self-update-FFFFFFFF.log")
        let newer = root.appendingPathComponent("self-update-00000000.log")
        try "old".write(to: older, atomically: true, encoding: .utf8)
        try "new".write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: newer.path
        )

        SelfUpdateHandoff.cleanUpArtifacts(root: root, keepingLogs: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path), "较旧的日志该被清掉")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newer.path),
            "留下的是刚跑完那次；按文件名排序的话留下的会正好相反"
        )
    }

    /// 脚本是一次性的，跑完就该没了——留着只会攒出一堆能读出目标路径的碎片。
    func testCleanUpRemovesEveryScript() throws {
        let stale = root.appendingPathComponent("self-update-AAAAAAAA.sh")
        try "#!/bin/sh\n".write(to: stale, atomically: true, encoding: .utf8)

        SelfUpdateHandoff.cleanUpArtifacts(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// 脚本里到处是中文字符。macOS 的 sh 会把紧跟 `$VAR` 的全角括号当成变量名的一部分，
    /// 配 `set -u` 就是当场退出——脚本什么都没做，用户面对一个
    /// "点了更新、应用关了、再打开还是旧版本"的应用。这条守着"变量一律加花括号"这个约定。
    func testScriptBracesEveryVariableExpansion() {
        // 注释里当然可以写 `$NAME`；只扫真正会被执行的那些行。
        let code = codeOnly(makeHandoff())

        // 允许的形式：${NAME}、$1、$2、$((…))、$(…)。裸露的 $NAME 一律不接受。
        let bare = try? NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        let matches = bare?.matches(in: code, range: range) ?? []
        let offenders = matches.compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: code) else { return nil }
            return String(code[swiftRange])
        }
        XCTAssertTrue(offenders.isEmpty, "这些变量没有加花括号：\(offenders)")
    }

    // MARK: - 跑脚本用的小工具

    /// 跑脚本时用的可执行文件名。
    ///
    /// 不能是真的 `AppUpdater`：本机大概率正跑着一个 `AppUpdater`（开发机上有
    /// `dist/` 和 `/Applications` 两份并存是常事），哪怕脚本那道闸是按包路径判断的，
    /// 用假名字也能让"这个包在不在用"的结论干净利落，不受环境影响。
    /// 但它又必须和假包里的可执行文件同名——否则"包是否完整"那一步复核会拦下来。
    private static let probeExecutable = "AppUpdaterProbeX9"

    /// 一个落在临时目录里的交接对象：目标、预置包、日志、状态全在这儿，不碰系统。
    private func makeRunnableHandoff() throws -> (SelfUpdateHandoff, URL, URL) {
        let directory = root.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handoff = SelfUpdateHandoff(
            target: directory.appendingPathComponent("AppUpdater.app", isDirectory: true),
            token: "38144E15",
            root: root
        )
        return (handoff, directory, root.appendingPathComponent("opened.txt"))
    }

    /// 造一个假 `.app`。`executable` 传 nil 就是"结构不对的包"。
    @discardableResult
    private func makeFakeApp(
        in directory: URL,
        name: String,
        executable: String?,
        content: String
    ) throws -> URL {
        try makeFakeApp(at: directory.appendingPathComponent("\(name).app", isDirectory: true),
                        executable: executable,
                        content: content)
    }

    @discardableResult
    private func makeFakeApp(at app: URL, executable: String?, content: String) throws -> URL {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))

        if let executable {
            let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let binary = macos.appendingPathComponent(executable)
            try Data(content.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return app
    }

    private func content(ofExecutableIn app: URL) throws -> String? {
        let binary = app.appendingPathComponent("Contents/MacOS/\(Self.probeExecutable)")
        guard FileManager.default.fileExists(atPath: binary.path) else { return nil }
        return try String(contentsOf: binary, encoding: .utf8)
    }

    /// 假的 `open`：把收到的路径记下来。不放这个假的，测试会在用户桌面上弹对话框。
    private func makeFakeOpen(in directory: URL, log: URL) throws -> URL {
        let bin = directory.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: log, atomically: true, encoding: .utf8)

        let script = """
        #!/bin/sh
        echo "$1" >> '\(log.path)'
        exit 0
        """
        let file = bin.appendingPathComponent("open")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return bin
    }

    /// 用假 PATH 跑脚本。
    ///
    /// 借 `-c … exec` 把 PATH 注进去：`ProcessRunner` 只对**直接子进程**发信号，
    /// 用 `exec` 就地替换掉这个 sh，就不会多出一个收不到信号的孩子。
    private func run(_ handoff: SelfUpdateHandoff, fakeBinDirectory: URL) async -> ProcessRunner.Result {
        let file = root.appendingPathComponent("run-\(UUID().uuidString).sh")
        let text = handoff.script(
            executableName: Self.probeExecutable,
            from: "9.9.9",
            to: "9.9.10",
            backupPath: nil
        )
        // PID 用一个确定已不存在的值，免得测试真的去等 60 秒。
        .replacingOccurrences(of: "PID=\(ProcessInfo.processInfo.processIdentifier)", with: "PID=999999")
        try? text.write(to: file, atomically: true, encoding: .utf8)

        let path = "\(fakeBinDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"
        return await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "PATH='\(path)' exec /bin/sh '\(file.path)'"]
        )
    }

    // MARK: - 状态文件

    func testStatusFileRoundTrips() throws {
        let handoff = makeHandoff()
        try handoff.markHandedOff(
            from: "0.2.1",
            to: "0.3.0",
            backupPath: URL(fileURLWithPath: "/tmp/backup/AppUpdater.app")
        )

        let status = SelfUpdateHandoff.consumeStatus(root: root)
        XCTAssertEqual(status?.outcome, .inProgress)
        XCTAssertEqual(status?.fromVersion, "0.2.1")
        XCTAssertEqual(status?.toVersion, "0.3.0")
        XCTAssertEqual(status?.backupPath, "/tmp/backup/AppUpdater.app")
        XCTAssertNotNil(status?.at)
    }

    /// 状态只该被消费一次，否则每次启动都会重播一遍"上次更新成功了"。
    func testStatusIsConsumedExactlyOnce() throws {
        let handoff = makeHandoff()
        try handoff.markHandedOff(from: "0.2.1", to: "0.3.0", backupPath: nil)

        XCTAssertNotNil(SelfUpdateHandoff.consumeStatus(root: root))
        XCTAssertNil(SelfUpdateHandoff.consumeStatus(root: root))
    }

    func testConsumeReturnsNilWhenNothingWasWritten() {
        XCTAssertNil(SelfUpdateHandoff.consumeStatus(root: root))
    }

    /// 行格式而不是 JSON：值里的换行会把格式撑坏，必须先压成单行。
    func testSerializationFlattensNewlines() {
        let status = SelfUpdateStatus(
            outcome: .failed,
            fromVersion: "0.2.1",
            toVersion: "0.3.0",
            message: "第一行\n第二行",
            backupPath: nil
        )
        let parsed = SelfUpdateStatus.parse(status.serialized())
        XCTAssertEqual(parsed?.message, "第一行 第二行")
        XCTAssertEqual(parsed?.outcome, .failed)
    }

    func testParsingRejectsRecordsWithoutAnOutcome() {
        XCTAssertNil(SelfUpdateStatus.parse("toVersion=0.3.0\nmessage=坏了\n"))
        XCTAssertNil(SelfUpdateStatus.parse("outcome=succeeded\n"))
        XCTAssertNil(SelfUpdateStatus.parse("完全不是这个格式"))
    }

    /// 交接后清掉历史脚本，但保留最近一份日志——用户报"更新完就不对劲"时那是唯一现场。
    func testCleanUpKeepsTheLatestLogAndRemovesScripts() throws {
        for token in ["AAAAAAAA", "BBBBBBBB"] {
            try "#!/bin/sh\n".write(
                to: root.appendingPathComponent("self-update-\(token).sh"),
                atomically: true,
                encoding: .utf8
            )
            try "log \(token)".write(
                to: root.appendingPathComponent("self-update-\(token).log"),
                atomically: true,
                encoding: .utf8
            )
        }
        // 无关文件不该被碰。
        try "keep".write(to: root.appendingPathComponent("state-v2.json"), atomically: true, encoding: .utf8)

        SelfUpdateHandoff.cleanUpArtifacts(root: root, keepingLogs: 1)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(remaining, ["self-update-BBBBBBBB.log", "state-v2.json"])
    }

    func testHandoffStatusFileLivesUnderTheAppSupportDirectory() {
        let handoff = SelfUpdateHandoff(target: URL(fileURLWithPath: "/Applications/AppUpdater.app"))
        XCTAssertTrue(handoff.statusFile.path.contains("Library/Application Support/AppUpdater/"))
    }
}
