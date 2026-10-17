---
name: windows-storage-migration
description: "Audit Windows disk usage, migrate selected application data to another local drive with original-path junctions, verify copies and recover interrupted runs, and clean explicitly identified disposable caches or uninstall leftovers. Use for C盘空间不足、应用数据迁移、迁移后旧副本清理、缓存清理及此类脚本排错; not a blanket system cleaner or an application version upgrader."
---

# Windows 空间迁移与缓存清理

把选定的数据搬到其他本地磁盘并保持原路径兼容，或清理已确认可丢弃的数据。保留已有目标数据、用户排除项和可恢复性；分别报告文件迁移、旧副本清理与应用功能验证状态。

## 盘点与决策

先核实当前源目录、目标、原路径是否已为联接、旧备份、应用运行状态、两盘空闲空间。已有历史结果仅作线索，重查当前状态，避免重复统计指向 D 盘的联接。安装 skill 不代表用户授权迁移任何新目录。

优先用可用的本地文件工具检查少量相关文件；目录大小统计用 `scripts/audit_storage.py`，它默认只读，跳过重解析点以及经父级联接重定向的扫描根，并报告读取失败。确需扫描已重定向根时显式加 `--scan-resolved-root`，按解析后的物理位置归属空间。只扫描任务相关目录，排除用户明确不动的项。报告是逻辑文件大小，不是已分配空间或保证可回收空间。

```powershell
python "<skill>/scripts/audit_storage.py" --root "<用户目录>" --exclude CrossDevice --output "<任务工作目录>/audit.json"
```

按实际内容分成：可迁移的用户数据；需考虑安装器/更新依赖的程序；可重建缓存；需要保留选择的卸载残留；暂不处理项。工具箱、授权、系统管理目录、云盘占位文件等先核实厂商支持和实际依赖，不以文件夹名称或体积直接判定可迁移/删除。

涉及缓存、具体应用及本次已见故障时，按需阅读 [cache-and-app-cases.md](references/cache-and-app-cases.md)。不把其中的路径、版本、PID 或个人排除项直接套到新机器。

## 准备迁移

读取 [plan-and-recovery.md](references/plan-and-recovery.md)，从 `assets/migration-plan.example.json` 生成具体计划，列明源/目标/恢复目录、主进程、经过路径核实的 helper、冲突策略和是否清理旧副本。

- 保留目标独有内容及其访问权限。默认同名不同内容即停止；只有明确采用源版本时，先归档目标冲突文件。绝不对有数据的目标盲目 `/MIR`、`/PURGE`、重置根 ACL 或按总数量相等验收合并。既有旧备份要逐项核实并绑定计划白名单，不因命名类似就自动删除。
- 关闭主应用，含托盘和同步/录制/终端任务。对 helper 必须同时匹配精确名称与可信二进制根目录；路径不可读、进程归属不明时不能强杀。解释器必须位于迁移树之外。
- 使用 PowerShell 7；旧版 PowerShell 5.1 的长路径问题也会影响哈希及最后清理，不只影响复制。复用现成独立运行时，不随 skill 分发庞大运行时。
- 有 SQLite 等活动数据库时，先确保写入停止并保留 DB/WAL 配套文件；必要时复制到独立临时目录做完整性检查，不打开活动原库做修复。临时目录需要与源同等的访问保护。

用户若只要命令/脚本，就准备并测试，不自行执行。若已经明确要求执行迁移和释放空间，则在该范围内完成，不额外要求重复确认。引擎默认计划模式；实际执行须显式 `-Apply`，不把 skill 的自动发现当作执行授权。

```powershell
& "<独立 pwsh.exe>" -NoProfile -File "<skill>/scripts/Invoke-StorageMigration.ps1" -PlanPath "<具体计划.json>"
```

准备或修改高影响脚本后，在隔离伪数据上运行 `scripts/test_migration_engine.py`；不能用真实用户数据试错。权限受限时如实说明验证边界，不能把跳过权限设置的 mock 当作真实 ACL 验证通过。

## 执行、恢复、清理

在已授权范围内加 `-Apply`。需要临时停止计划中 helper 时才加 `-StopBackground`；主进程不会被强行关闭，服务和启动项也不自动修改。

引擎逐文件 SHA-256 校验，复核源在复制期间未变化，再切换联接。先保存并验证旧源归档，再按计划清理旧副本。正常清理永远保留原路径联接。

遇到失败先定位阶段：复制/验证、重命名、联接、归档、清理。读日志和当前路径状态后恢复，避免从头强行覆盖。旧备份有拒绝删除规则时，只能对已验证归档的旧备份进行窄化权限修复；不改变活动数据的拒绝规则，不遍历链接目标删除，不扩大成全盘夺权。

缓存另按授权范围使用对应工具清理；例如 pip 的 cache purge 不等于卸载 Python 包。变更未来缓存路径要单独记录、验证，不能在“清理缓存”时顺便修改其他应用或环境设置。

## 交付

用当前状态回答：哪些目录已指向目标；哪些 C 盘旧备份已清、哪些残留及原因；缓存是否已清/后续存放何处；实际空闲空间增加多少。保护用户数据时留下的恢复归档要明确位置，不擅自删除。

哈希通过或退出码 0 只能证明该步骤的文件状态。应用登录、历史、扩展、MCP、同步、授权及更新需要实际运行验证，未测就标明未测。给一条与已验证运行时相符的命令；若替换用户旧入口，先备份原脚本并验证它确实调用修正版。
