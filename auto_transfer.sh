#!/bin/bash

# 说明:
# 1. 该脚本保留为兼容入口, 用于兼容历史上直接调用 auto_transfer.sh 的场景. 
# 2. 真正的迁移逻辑已经拆分为 Arm/IPC 入口、对应 flow、可移动介质 flow 与公共库
# 3. AUTO_TRANSFER_PROFILE 用于显式指定迁移目标类型:
#      - arm : 转发到 auto_transfer_arm.sh
#      - ipc : 转发到 auto_transfer_ipc.sh
# 4. DEFAULT_TARGET_CLASS 用于提供默认目标类型:
#      - 仅当 AUTO_TRANSFER_PROFILE 未设置时生效
#      - DEFAULT_TARGET_CLASS=ipc 时默认转发到 IPC 入口
#      - 其他情况默认转发到 Arm 入口
#
# 使用示例:
#   # 显式使用 Arm 迁移流程
#   AUTO_TRANSFER_PROFILE=arm ./auto_transfer.sh
#
#   # 显式使用 IPC 迁移流程
#   AUTO_TRANSFER_PROFILE=ipc ./auto_transfer.sh
#
#   # 未指定 AUTO_TRANSFER_PROFILE, 根据默认目标类型自动选择
#   DEFAULT_TARGET_CLASS=ipc ./auto_transfer.sh
#
#   # 未指定任何环境变量, 默认使用 Arm 迁移流程
#   ./auto_transfer.sh

ENTRY_PATH=${BASH_SOURCE[0]}
ENTRY_PARENT=${ENTRY_PATH%/*}
[[ "$ENTRY_PARENT" == "$ENTRY_PATH" ]] && ENTRY_PARENT="."
SCRIPT_DIR=$(cd "$ENTRY_PARENT" && pwd)

# 显式指定迁移目标类型.
# 支持值:
#   arm : 使用 Arm 迁移流程
#   ipc : 使用 IPC 迁移流程
AUTO_TRANSFER_PROFILE="${AUTO_TRANSFER_PROFILE:-}"

if [[ -z "$AUTO_TRANSFER_PROFILE" ]]; then
    if [[ "${DEFAULT_TARGET_CLASS:-}" == "ipc" ]]; then
        AUTO_TRANSFER_PROFILE="ipc"
    else
        AUTO_TRANSFER_PROFILE="arm"
    fi
fi

case "$AUTO_TRANSFER_PROFILE" in
    arm)
        exec bash "$SCRIPT_DIR/auto_transfer_arm.sh" "$@"
        ;;
    ipc)
        exec bash "$SCRIPT_DIR/auto_transfer_ipc.sh" "$@"
        ;;
    *)
        echo "[ERROR] Unsupported AUTO_TRANSFER_PROFILE: $AUTO_TRANSFER_PROFILE" >&2
        echo "[ERROR] Expected one of: arm, ipc" >&2
        exit 1
        ;;
esac