import Foundation

/// 更新探测的统一接口。
///
/// `CheckEngine` 只依赖这个协议，因此"只探了哪些应用"这件事在测试里可以被精确断言——
/// 用一个只记录调用、不发网络请求的假探针，就能证明局部检查没有悄悄扩散成全量。
public protocol UpdateProbing: Sendable {
    func probe(_ app: AppInfo) async -> UpdateResult
}

extension SparkleProbe: UpdateProbing {}
extension ElectronProbe: UpdateProbing {}
extension MASProbe: UpdateProbing {}
