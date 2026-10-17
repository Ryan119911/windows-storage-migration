# Windows 空间迁移与缓存清理

可复用的 Codex skill：盘点 Windows 磁盘占用，将选定的应用数据迁移到其他本地磁盘，以目录联接保留原路径，并清理已确认无用的缓存或卸载残留。

## 安装与调用

将仓库中的 `windows-storage-migration` 文件夹放入 Codex 的用户技能目录（通常为 `~/.codex/skills/`），然后在新会话中调用：

```text
$windows-storage-migration
先只读检查 C 盘占用，列出适合迁移到 D 盘的数据和可清理的缓存，准备迁移计划和脚本。
```

私有仓库需要使用有仓库访问权限的 GitHub 账号下载或克隆。

## 工作方式

- 先盘点源目录、目标、目录联接、进程和实际可用空间。
- 默认仅预览计划；迁移需要显式 `-Apply`。
- 逐文件 SHA-256 校验，并检查复制期间源文件是否变化。
- 保留目标独有文件及其访问权限；同名内容冲突默认停止。
- 在切换原路径前保留备份；清理前先归档并验证，可恢复中断状态。
- 支持长路径、目录联接、只读文件和受限访问权限等 Windows 场景。

迁移引擎需要独立的 **PowerShell 7**。只读盘点和隔离测试使用 **Python 3**，仅依赖标准库。运行时须位于待迁移目录之外。

## 文件与示例

- [技能入口](windows-storage-migration/SKILL.md)
- [迁移计划示例](windows-storage-migration/assets/migration-plan.example.json)
- [计划与故障恢复](windows-storage-migration/references/plan-and-recovery.md)
- [缓存和应用案例](windows-storage-migration/references/cache-and-app-cases.md)

按实际路径修改计划，再预览：

```powershell
pwsh -NoProfile -File ./windows-storage-migration/scripts/Invoke-StorageMigration.ps1 -PlanPath ./my-plan.json
```

确认计划后执行：

```powershell
pwsh -NoProfile -File ./windows-storage-migration/scripts/Invoke-StorageMigration.ps1 -PlanPath ./my-plan.json -Apply
```

## 验证与边界

已在 Windows / PowerShell 7 的隔离伪数据上通过 13 项集成场景，覆盖冲突保留、长路径、权限、回滚、中断恢复及进程保护。可运行：

```powershell
python ./windows-storage-migration/scripts/test_migration_engine.py --pwsh "<独立的 pwsh.exe>" --work-dir "<隔离测试目录>"
```

哈希校验只能证明文件状态，应用登录、历史记录、扩展、同步和授权需要另外打开应用验证。此技能不用于整盘清理、直接搬动系统目录或更新应用版本。仓库仅包含通用技能、示例和测试，不包含个人数据、实际迁移计划、运行日志或凭据。
