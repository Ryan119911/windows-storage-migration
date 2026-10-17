# 缓存分类与本次复盘

## 缓存清理

先确认目录内容和所属应用，不以名称含 `cache`、`tmp` 或程序已卸载作为自动删除依据。聊天数据库、浏览器用户资料、自动恢复文件、项目、本地历史、网盘下载/同步目录均可能不可重建。

pip：用指定解释器执行 `-m pip cache dir` 和 `-m pip cache info`。用户要求清理后，用 `-m pip --cache-dir "<已核实目录>" cache purge`，不卸载环境或包。需要迁移未来缓存且已获相应授权时，单独设置明确的用户级 `PIP_CACHE_DIR`，记录旧值，复核用户级值并说明新终端才会继承。当前进程环境可能仍旧，不能据此误判持久设置失败。使用官方清理器清除它识别的 HTTP/wheel 缓存，不把剩余少量目录索引误判为清理失败。

Windows Temp：只列出可清理候选，按授权移除明确的失效临时数据，跳过在用文件。不要迁移整个 AppData 或清空未知应用的自动恢复目录。

卸载残留：核实产品及版本、目录内容、主程序确已卸载，以及是否要保留设置、插件或本地历史。按明确版本白名单清理，不删除整个共享厂商目录。若用户尚未决定保留策略，先给可审阅的清单。

安装包及自动更新缓存：先区分可重下载缓存、正在使用的程序版本与回滚版本。不能把“多个版本”直接当成无用。

## 真实应用中的教训（诊断线索，非全局允许列表）

| 现象 | 判断与下一步 |
|---|---|
| Windows PowerShell 5.1 报 276 字符路径不存在，但文件实际存在 | 使用独立的 PowerShell 7；同时测试哈希、复制、重命名和旧备份删除的长路径支持。 |
| 解释器位于将迁移的 Codex 运行时缓存 | 先在其他位置准备独立运行时，验证完整副本；不启动仍需移动的解释器来执行迁移。 |
| `/COPYALL`、`Set-Acl` 报 SeSecurityPrivilege | 只复制数据/属性/时间/DACL，避免所有者及审计权限；使用只含 Access 段的 .NET ACL 接口。 |
| 续传后 Extras 或条目数量不等 | 目标可能已有合法任务，也可能保留旧锁文件。逐项分类；默认保留目标独有条目，校验源是子集且原目标独有内容不变；禁止盲目 `/MIR`。 |
| WorkBuddy 的 D 盘目标已有任务目录和 Claw | 合并并保留这些目录，不隔离为“垃圾”；同名数据库无法靠文件级合并解决，须明确权威源并归档冲突版本。 |
| `sandbox-cli-gc`、桌面操作辅助进程、云盘后台残留 | 根据当前安装位置、日志或注册信息核实归属；主程序退出后才允许停止精确匹配且路径可信的 helper。历史 PID 和路径不能直接复用。 |
| `__cloud__.log` 清理时报 Access denied | 真实案例存在继承的 `DENY Delete/DeleteChild`。区分 ACL 与文件锁；只在已验证归档的旧副本中窄化修复，不修改活动 D 盘日志权限。 |
| Chrome、VS Code 或微信目录很大 | 先区分用户资料、插件、模型、日志和聊天文件。微信 `xwechat` 在本次主要是运行组件和日志，并不代表其他机器的聊天主目录。 |
| 夸克程序目录中有三套版本 | 包含启动器、安装器及更新依赖；优先官方安装/迁移选项。原路径兼容迁移需保留全部所需版本，另行验证更新和同步。 |
| MathWorks Service Host 占约数 GiB | 属于必要服务，影响授权及启动；先查当前官方支持与版本。2026-10-17 核实的官方页面不支持修改安装位置；本次用户选择不迁移。联接可复制文件不等于厂商支持或授权验证通过。 |

排除项按本次用户意愿持续生效；例如本次明确不动 CrossDevice 和 MathWorks。不要把这些个人选择固化成所有用户的永久禁止项，也不要在新任务中擅自取消现有排除项。

## 查询官方依据时

- pip: https://pip.pypa.io/en/stable/topics/caching/
- Windows junctions: https://learn.microsoft.com/en-us/windows/win32/fileio/hard-links-and-junctions
- Chrome 用户数据: https://chromium.googlesource.com/chromium/src/+/master/docs/user_data_dir.md
- VS Code 参数: https://code.visualstudio.com/docs/configure/command-line
- MathWorks Service Host 位置: https://www.mathworks.com/matlabcentral/answers/2128831-how-can-i-change-the-location-that-the-mathworks-service-host-installs-to

这些是核实时的入口，遇到新的版本或厂商特性问题需重新查证，不把日期限定的发现当成永久事实。
