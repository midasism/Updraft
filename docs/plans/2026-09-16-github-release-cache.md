# 实施计划：GitHub API 响应缓存（ETag 条件请求 + 共享客户端）

日期：2026-09-16 ｜ 分支：`feat/github-release-cache` ｜ 前置：PR #14 / #15 已合并，main `2517c6a`

## 一、问题

`ElectronProbe` 与 `GitHubReleaseProbe` 各自打 `api.github.com/repos/<owner>/<repo>/releases/latest`，
一次全量约 **20 个请求**，共享未登录限额 60 次/小时/IP。定时全量一天一次远够用，
但重复检查（用户手点、CLI 反复跑、装好的 app 与 CLI 并存）会把限额打爆，触发后一批条目 failed。

## 二、方案选型

| 方案 | 结论 |
|---|---|
| A. TTL 结果缓存 | ✅ **唯一真正省限额的手段**（TTL 内根本不发请求） |
| B. ETag 条件请求 | ⚠️ **实测推翻文档假设**（见下）：304 同样计数，省带宽不省限额；保留作重验证手段 |
| C. **共享 GitHub 客户端** | ✅ 两个探针的 GitHub 请求收敛到一处，缓存与 ETag 天然共用 |

### 实测记录（2026-09-16 16:5x，决定性）

GitHub 文档称"条件请求返回 304 不计入 rate limit"，**未登录场景实测不成立**：

```
rate_limit 查询 ×3:  50 → 50 → 50   （确认查询本身不计数）
一次 200:            50 → 49        （计数，−1）
一次 304:            49 → 48        （计数，−1 ← 与文档相反）
```

结论：**要想不消耗限额，唯一的办法是 TTL 内不发请求**。ETag 保留，但角色降级为
"过期后的重验证"（省带宽 + 304 时确认未变并重启 TTL）。

## 三、设计（TTL 门 + ETag 重验证的混合）

1. **`HTTPFetching` 加一个带状态码的缝**（现有 `data(from:)` 不动）：

   ```swift
   public struct HTTPResponse: Sendable {
       public let data: Data
       public let statusCode: Int
       public let etag: String?          // 取自响应头 ETag（大小写不敏感查找）
   }
   public protocol HTTPFetching {
       func data(from url: URL) async throws -> Data
       func response(from url: URL, headers: [String: String]) async throws -> HTTPResponse
   }
   ```

   协议扩展给 `response` 一个默认实现（走 `data`，恒 200、无头）——不需要状态码的测试桩零改动；
   要测 304 的桩自己覆写。`HTTPClient` 用 `URLRequest` 真实现，**不抛非 2xx**（304 是正常分支，由调用方解释）。

2. **TTL 默认 1 小时**（与限额窗口同量级）：TTL 内直接用缓存，**一个请求都不发**；
   过期后带 `If-None-Match` 重验证——304 → 刷新 `savedAt`（TTL 重启），200 → 更新缓存。
   最坏情况下一小时的 GitHub 请求 ≈ 一轮全量（~20 个）< 60。

3. **缓存条目存"裁剪后的响应体"而不是原始体**：真实响应 30-60KB（大部分是 release body 与
   asset 明细），只留两个探针都用到的字段（`tag_name` / `html_url` / assets 的
   `name`/`size`/`browser_download_url`），条目缩到几 KB，且**两个探针的解析代码一行不用改**。

4. **`GitHubReleaseCacheStore`**：actor（探针并发跑，文件读写要串行），JSON 落盘
   `~/Library/Application Support/Updraft/github-cache-v1.json`（文件名带版本，坏了当无缓存，
   绝不让缓存问题升级成检查失败）。

5. **`GitHubAPIClient.get(_:)`**：

   ```
   有缓存且未过 TTL → 直接返回缓存 body（零请求）
   过期或无缓存 → 带 If-None-Match（若有 ETag）请求
     ├─ 200 → 裁剪 + 存(ETag, body, savedAt) → 返回 body
     ├─ 304 → 刷新 savedAt（body/etag 不变）→ 返回缓存 body
     └─ 其他 → 抛 HTTPError.statusCode（403/404 的文案映射留在探针里，与现状一致）
   ```

   304 但缓存里没 body（不可能，除非缓存文件被手改）→ 抛错如实报失败。
   响应里没有 `tag_name` 的（"该仓库没有正式 Release"）不缓存——那种响应本来就小。

6. **接线**：`GitHubReleaseProbe` 与 `ElectronProbe.probeGitHub` 都改走 `GitHubAPIClient`；
   两个探针各加一个带默认值的注入点（`.shared`），现有测试构造不受影响。
   Electron 的 generic 通道（`latest-mac.yml`）不走 GitHub，不碰。

7. **诚实性**：TTL 内的缓存命中可能漏掉 TTL 窗口内刚发布的新版本（最长 1 小时）。
   README 里写明；这对"避免重复拉取"的目标是合理取舍。

## 四、任务

| # | 任务 | 验收 |
|---|---|---|
| 1 | `HTTPResponse` + 协议缝 + `HTTPClient` 实现 | 现有探针/桩零改动编译通过 |
| 2 | `GitHubReleaseCacheStore`（actor + 文件） | 临时文件回路 / 坏文件当无缓存 |
| 3 | `GitHubAPIClient`（TTL 门 + 条件 GET + 裁剪） | TTL 命中零请求 / 过期 304 / 过期 200 / 错误透传 / 二次请求带 If-None-Match |
| 4 | 两个探针接线 | 现有测试全绿；新增"304 后结果与 200 一致" |
| 5 | 真机验证 | 连跑两次 `--check`：结果一致且第二次**限额剩余不降**（TTL 命中零请求） |
| 6 | README + 提交 | 已知限制改写：TTL 一小时内重复检查不重复拉取 |

## 五、风险

| 风险 | 对策 |
|---|---|
| TTL 内漏掉刚发布的新版本（最长 1 小时） | 已在设计里写明取舍；TTL 与限额窗口同量级，两个目标对齐 |
| 缓存文件损坏 | 解码失败当无缓存，绝不影响检查本身 |
| 并发读写文件 | store 用 actor 串行 |
| 304 被当成"免费刷新"滥用 | 304 只重启 TTL，body/etag 不变；数据在 GitHub 侧确实未变 |
| URLSession 对 304 的处理出幺蛾子 | 真机 `--check` 连跑两次验证；304 路径有专项测试 |
