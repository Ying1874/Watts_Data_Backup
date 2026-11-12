# Watts_Data_Backup

用于 ARM 与 IPC 的 Linux 数据迁移、备份和保留期清理脚本。

## 文件组成

| 文件 | 用途 |
| --- | --- |
| `auto_transfer.sh` | 兼容入口，通过 `AUTO_TRANSFER_PROFILE=arm` 或 `ipc` 选择模式 |
| `auto_transfer_arm.sh` | ARM 入口及配置 |
| `auto_transfer_arm_archive.sh` | ARM 图像归档 |
| `auto_transfer_arm_flow.sh` | ARM 流程编排 |
| `auto_transfer_removable_flow.sh` | 可移动介质挂载、同步及卸载 |
| `auto_transfer_ipc.sh` | IPC 入口及配置 |
| `auto_transfer_ipc_flow.sh` | IPC 流程编排 |
| `auto_transfer_ipc_time.sh` | IPC PLC 时间可信性校验 |
| `auto_transfer_ipc_metadata.py` | IPC 历史指纹及清理 mtime 读取器 |
| `auto_transfer_common.sh` | 公共复制、校验、索引、账本、锁及清理逻辑 |

以上文件部署时保持在同一目录。测试、临时报告、旧版本副本及运行数据不纳入仓库。

## 运行

使用 Linux、Bash 及 GNU 工具，正常执行需要 root。ARM 还需要相应归档/同步工具和可移动设备配置；IPC 的常驻元数据读取使用 Python 3.8+，不可用时回退原逐文件 stat 检查。

`WORKSPACE_ROOT` 指向包含 `vpfi_data` 的工作区。未设置时，默认使用脚本目录的上两级目录；部署位置变化时应显式指定。

例如，工作区为当前用户的 `~/mi_ws`，先预演 IPC 流程：

```bash
sudo env WORKSPACE_ROOT="$HOME/mi_ws" bash ./auto_transfer_ipc.sh --dry-run
```

确认配置后执行备份：

```bash
sudo env WORKSPACE_ROOT="$HOME/mi_ws" bash ./auto_transfer_ipc.sh
```

停止备份时，使用相同工作区和运行配置执行入口的 `--stop`。ARM 使用 `auto_transfer_arm.sh`，并配置 `REMOVABLE_DEVICE_UUID` 或 `REMOVABLE_DEVICE_LABEL`；默认设备 UUID 为空。

## IPC 默认行为

- 从 `vpfi_data` 的配置目录备份到 `vpfi_data_backup`。
- 普通源/目标数据按 180 天保留规则处理，冲突内容进入 `.conflicts`，冲突区默认保留 90 天。
- 空间预检要求 200 GiB 安全余量；这是预检阈值，不是运行期空间预留。
- 复制阶段历史指纹每次重新读取；读取器异常时回退原 stat 路径，保持原复制及 SHA-256 校验流程。
- 清理阶段按原清单顺序实时读取每个文件的 mtime，不预取或跨文件缓存，保留原删除资格及安全检查。
- 索引临时文件一次打开、连续写入，保留原格式、同步和原子替换流程。写入失败不提交半份索引。
- `IPC_HISTORY_READER_ENABLED=false` 可关闭复制和清理两阶段的常驻元数据读取。
- `IPC_RETENTION_READER_ENABLED=false` 可单独关闭清理阶段读取加速。
- `IPC_COPY_PROGRESS_SECONDS` 默认 `10`，设为 `0` 可关闭新增进度日志。主循环按间隔输出，单个阻塞命令期间不保证定时心跳。
- `IPC_RETENTION_PROGRESS_SECONDS` 默认 `10`，设为 `0` 可关闭清理进度日志；同样不提供阻塞命令期间的定时心跳。

备份期间，同一源文件应已写完并保持不变。当前版本未解决正式文件持续追加时的索引版本绑定和过期源清理竞态；180 天保留规则不能替代文件完成判断。
