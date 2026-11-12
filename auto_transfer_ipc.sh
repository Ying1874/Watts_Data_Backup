#!/bin/bash

# 说明:
# 1. 本脚本是 IPC 侧迁移入口, 只负责 IPC 环境的数据迁移与清理策略装配
# 2. 真实的迁移流程、锁、账本、校验与清理由公共库 auto_transfer_common.sh 统一提供
# 3. IPC 侧默认写入本机磁盘备份目录, 需要 200 GB 安全余量, 仅处理 log 与 rgb 数据

IPC_ENTRY_PATH=${BASH_SOURCE[0]}
IPC_ENTRY_PARENT=${IPC_ENTRY_PATH%/*}
[[ "$IPC_ENTRY_PARENT" == "$IPC_ENTRY_PATH" ]] && IPC_ENTRY_PARENT="."
SCRIPT_DIR=$(cd "$IPC_ENTRY_PARENT" && pwd)
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RUNTIME_NAME="${RUNTIME_NAME:-auto_transfer_ipc}"
DEFAULT_TARGET_CLASS="ipc"

# 说明:
# IPC 侧的目标根目录默认写入当前工作区下的 vpfi_data_backup
declare -A TARGET_ROOTS=(
    [ipc]="${TARGET_ROOT_IPC:-$WORKSPACE_ROOT/vpfi_data_backup}"
)
IPC_CONFLICT_ROOT="${IPC_CONFLICT_ROOT:-${TARGET_ROOTS[ipc]}/.conflicts}"
IPC_CONFLICT_RETENTION_DAYS="${IPC_CONFLICT_RETENTION_DAYS:-90}"

# IPC 侧要求系统盘至少预留 200 GB, 防止备份挤占业务运行空间
declare -A TARGET_RESERVED_GB=(
    [ipc]=200
)

# 说明:
# IPC 侧只处理 cabinet 相关日志与 RGB 图像目录, 不再承担 Arm 点云迁移职责
declare -A SOURCE_RELATIVE_TARGETS=(
    ["$WORKSPACE_ROOT/vpfi_data/logs/cabinet/"]="logs/cabinet"
    ["$WORKSPACE_ROOT/vpfi_data/logs/crash/"]="logs/crash"
    ["$WORKSPACE_ROOT/vpfi_data/task/"]="task"
    ["$WORKSPACE_ROOT/vpfi_data/visual/cabinet/"]="visual/cabinet"
    ["$WORKSPACE_ROOT/vpfi_data/visual/exception/"]="visual/exception"
)

declare -a SOURCE_DIR_ORDER=(
    "$WORKSPACE_ROOT/vpfi_data/logs/cabinet/"
    "$WORKSPACE_ROOT/vpfi_data/logs/crash/"
    "$WORKSPACE_ROOT/vpfi_data/task/"
    "$WORKSPACE_ROOT/vpfi_data/visual/cabinet/"
    "$WORKSPACE_ROOT/vpfi_data/visual/exception/"
)

# IPC 入口当前不需要对单个源目录覆写目标环境, 但保留该结构以兼容公共库接口
declare -A SOURCE_TARGET_CLASSES=()

# 说明:
# IPC 侧只有日志与 RGB 图像, 两者统一保留 180 天
declare -A RETENTION_DAYS_BY_SCOPE=(
    [ipc:log]=180
    [ipc:rgb]=180
    [ipc:default]=180
    [global:default]=180
)

# 说明:
# IPC 首版不对白名单外目录做主动瘦身, 保持现有行为最稳定
should_prune_stale_directory_for_source() {
    return 1
}

source "$SCRIPT_DIR/auto_transfer_common.sh"
source "$SCRIPT_DIR/auto_transfer_ipc_time.sh"
source "$SCRIPT_DIR/auto_transfer_ipc_flow.sh"

# IPC 入口只负责把原始命令行参数转交给公共主流程
auto_transfer_ipc_main "$@"
