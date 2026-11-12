#!/bin/bash

# 说明:
# 1. 本脚本是 Arm 侧迁移入口, 只负责 Arm 环境的数据迁移与清理策略装配
# 2. 迁移原语由 auto_transfer_common.sh 提供，U 盘生命周期和 ARM 主流程分别由对应 flow 编排
# 3. Arm 侧默认写入外置介质, 需要设备/挂载检查、20 GiB 安全余量, 并保留 log/rgb/pcd 三类策略

ARM_ENTRY_PATH=${BASH_SOURCE[0]}
ARM_ENTRY_PARENT=${ARM_ENTRY_PATH%/*}
[[ "$ARM_ENTRY_PARENT" == "$ARM_ENTRY_PATH" ]] && ARM_ENTRY_PARENT="."
SCRIPT_DIR=$(cd "$ARM_ENTRY_PARENT" && pwd)
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RUNTIME_NAME="${RUNTIME_NAME:-auto_transfer_arm}"
DEFAULT_TARGET_CLASS="removable"

# 说明:
# Arm 侧的目标根目录默认指向可移动存储介质
declare -A TARGET_ROOTS=(
    [removable]="${TARGET_ROOT_REMOVABLE:-/media/mi_ws}"
)

# Arm 侧要求目标介质至少预留 20 GiB, 防止迁移写满 U 盘导致运行异常
declare -A TARGET_RESERVED_GB=(
    [removable]=20
)

# 设备级默认 UUID：仓库中必须保持为空，使未配置设备按 fail-closed 方式退出
# 部署到绑定固定 U 盘的真实设备后，可在设备副本中填入 UUID；运行环境变量仍可覆盖它
DEFAULT_REMOVABLE_DEVICE_UUID=""
REMOVABLE_DEVICE_UUID="${REMOVABLE_DEVICE_UUID:-$DEFAULT_REMOVABLE_DEVICE_UUID}"
REMOVABLE_DEVICE_LABEL="${REMOVABLE_DEVICE_LABEL:-}"
REMOVABLE_FS_TYPE="${REMOVABLE_FS_TYPE:-ext4}"
REMOVABLE_MOUNT_OPTIONS="${REMOVABLE_MOUNT_OPTIONS:-rw,nodev,nosuid,noexec,noatime}"
REMOVABLE_DEVICE_WAIT_SECONDS="${REMOVABLE_DEVICE_WAIT_SECONDS:-30}"
if [[ -z "${REMOVABLE_CASE_INSENSITIVE:-}" ]]; then
    case "$REMOVABLE_FS_TYPE" in
        vfat|exfat|msdos|ntfs|fuseblk) REMOVABLE_CASE_INSENSITIVE=true ;;
        *) REMOVABLE_CASE_INSENSITIVE=false ;;
    esac
fi

declare -A TARGET_CASE_INSENSITIVE=(
    [removable]="$REMOVABLE_CASE_INSENSITIVE"
)

# 视觉小时归档采用安全默认值：只处理完整历史日期、每小时最多 120 个任务
# 默认 ZIP store（不压缩），保留逐成员 CRC 和按路径查询能力，避免对已压缩 WebP/二进制
# 现场稀疏数据容量复核后选择无压缩 tar，并用 1024 个 512-byte
# records 聚合为 512 KiB 写块；仍可通过环境变量显式覆盖以便诊断
ARM_VISUAL_TRANSFER_MODE="${ARM_VISUAL_TRANSFER_MODE:-hourly_archive}"
ARM_VISUAL_ARCHIVE_FORMAT="${ARM_VISUAL_ARCHIVE_FORMAT:-tar}"
ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR="${ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR:-1024}"
ARM_VISUAL_ARCHIVE_TIMEZONE="${ARM_VISUAL_ARCHIVE_TIMEZONE:-Asia/Shanghai}"
ARM_VISUAL_ARCHIVE_INCLUDE_CURRENT_DAY="${ARM_VISUAL_ARCHIVE_INCLUDE_CURRENT_DAY:-false}"
ARM_VISUAL_ARCHIVE_MAX_TASKS_PER_HOUR="${ARM_VISUAL_ARCHIVE_MAX_TASKS_PER_HOUR:-120}"
ARM_VISUAL_ARCHIVE_ZSTD_LEVEL="${ARM_VISUAL_ARCHIVE_ZSTD_LEVEL:-1}"
ARM_VISUAL_ARCHIVE_ZSTD_THREADS="${ARM_VISUAL_ARCHIVE_ZSTD_THREADS:-1}"

# 大日志仍使用 rsync 的不可覆盖和批量复核边界--whole-file 明确关闭
# delta 算法；preallocate 是否改善具体 U 盘控制器的持续写入需要现场 A/B，
# 因此默认关闭
ARM_LOG_RSYNC_PREALLOCATE="${ARM_LOG_RSYNC_PREALLOCATE:-false}"
declare -a RSYNC_TRANSFER_EXTRA_ARGS_RESULT=()

# 说明:
# Arm 侧只处理 arm 自身产出的日志与视觉数据目录
ARM_SOURCE_ROOT="${ARM_SOURCE_ROOT:-$WORKSPACE_ROOT/vpfi_data}"
ARM_LOG_SOURCE_DIR="$ARM_SOURCE_ROOT/logs/arm/"
ARM_CRASH_LOG_SOURCE_DIR="$ARM_SOURCE_ROOT/logs/crash/"
ARM_VISUAL_SOURCE_DIR="$ARM_SOURCE_ROOT/visual/arm/"
ARM_VISUAL_EXCEPTION_SOURCE_DIR="$ARM_SOURCE_ROOT/visual/exception/"

get_rsync_transfer_extra_args_for_source() {
    local source_dir=$1

    RSYNC_TRANSFER_EXTRA_ARGS_RESULT=(--whole-file)
    if [[ "$source_dir" == "$ARM_LOG_SOURCE_DIR" ||
          "$source_dir" == "$ARM_CRASH_LOG_SOURCE_DIR" ]]; then
        case "$ARM_LOG_RSYNC_PREALLOCATE" in
            true)
                RSYNC_TRANSFER_EXTRA_ARGS_RESULT+=(--preallocate)
                ;;
            false) ;;
            *)
                fail_now "ARM_LOG_RSYNC_PREALLOCATE must be true or false"
                ;;
        esac
    fi
}

declare -A SOURCE_RELATIVE_TARGETS=(
    ["$ARM_LOG_SOURCE_DIR"]="logs/arm"
    ["$ARM_CRASH_LOG_SOURCE_DIR"]="logs/crash"
    ["$ARM_VISUAL_SOURCE_DIR"]="visual/arm"
    ["$ARM_VISUAL_EXCEPTION_SOURCE_DIR"]="visual/exception"
)

# Keep the performance-critical order stable across source-root/profile changes.
# Visual archives are persisted and promoted immediately before rsync sources
# begin, so their durable timing is not charged to later log transfers.
declare -a SOURCE_DIR_ORDER=(
    "$ARM_VISUAL_SOURCE_DIR"
    "$ARM_CRASH_LOG_SOURCE_DIR"
    "$ARM_LOG_SOURCE_DIR"
    "$ARM_VISUAL_EXCEPTION_SOURCE_DIR"
)

# Arm 入口当前不需要对单个源目录覆写目标环境, 但保留该结构以兼容公共库接口
declare -A SOURCE_TARGET_CLASSES=()

VISUAL_DATE_WINDOW_DAYS=90
VISUAL_POST_TRANSFER_DELETE_DAYS=14
declare -A ARM_VISUAL_DATE_EPOCH_CACHE=()
ARM_VISUAL_TOP_LEVEL_RESULT=""
ARM_VISUAL_DATE_EPOCH_RESULT=""

arm_visual_get_top_level_component() {
    local relative_path=$1
    local trimmed_path=${relative_path#/}

    if [[ -z "$trimmed_path" ]]; then
        ARM_VISUAL_TOP_LEVEL_RESULT=""
        return 0
    fi

    ARM_VISUAL_TOP_LEVEL_RESULT=${trimmed_path%%/*}
}

arm_visual_is_date_directory_name() {
    local dir_name=$1
    [[ "$dir_name" =~ ^[0-9]{4}_[0-9]{4}$ ]]
}

arm_visual_date_directory_to_iso() {
    local dir_name=$1

    if ! arm_visual_is_date_directory_name "$dir_name"; then
        return 1
    fi

    printf '%s-%s-%s' "${dir_name:0:4}" "${dir_name:5:2}" "${dir_name:7:2}"
}

arm_visual_get_date_epoch() {
    local dir_name=$1
    local iso_date
    local dir_epoch
    local date_output
    local normalized_name

    if [[ -n "${ARM_VISUAL_DATE_EPOCH_CACHE[$dir_name]+x}" ]]; then
        ARM_VISUAL_DATE_EPOCH_RESULT=${ARM_VISUAL_DATE_EPOCH_CACHE[$dir_name]}
        [[ "$ARM_VISUAL_DATE_EPOCH_RESULT" != "invalid" ]]
        return
    fi

    if ! arm_visual_is_date_directory_name "$dir_name"; then
        ARM_VISUAL_DATE_EPOCH_CACHE["$dir_name"]="invalid"
        ARM_VISUAL_DATE_EPOCH_RESULT="invalid"
        return 1
    fi

    iso_date="${dir_name:0:4}-${dir_name:5:2}-${dir_name:7:2}"
    date_output=$(date -d "$iso_date" '+%s %Y_%m%d' 2>/dev/null) || {
        ARM_VISUAL_DATE_EPOCH_CACHE["$dir_name"]="invalid"
        ARM_VISUAL_DATE_EPOCH_RESULT="invalid"
        return 1
    }
    dir_epoch=${date_output%% *}
    normalized_name=${date_output#* }
    if [[ "$normalized_name" != "$dir_name" ]]; then
        ARM_VISUAL_DATE_EPOCH_CACHE["$dir_name"]="invalid"
        ARM_VISUAL_DATE_EPOCH_RESULT="invalid"
        return 1
    fi
    ARM_VISUAL_DATE_EPOCH_CACHE["$dir_name"]="$dir_epoch"
    ARM_VISUAL_DATE_EPOCH_RESULT=$dir_epoch
}

arm_visual_is_recent_date_directory_name() {
    local dir_name=$1
    local dir_epoch
    local cutoff_epoch

    arm_visual_get_date_epoch "$dir_name" || return 1
    dir_epoch=$ARM_VISUAL_DATE_EPOCH_RESULT
    get_cutoff_date_cached "$VISUAL_DATE_WINDOW_DAYS"
    cutoff_epoch=$CUTOFF_EPOCH_RESULT

    (( dir_epoch >= cutoff_epoch ))
}

arm_visual_is_older_than_days_directory_name() {
    local dir_name=$1
    local older_than_days=$2
    local dir_epoch
    local cutoff_epoch

    arm_visual_get_date_epoch "$dir_name" || return 1
    dir_epoch=$ARM_VISUAL_DATE_EPOCH_RESULT
    get_cutoff_date_cached "$older_than_days"
    cutoff_epoch=$CUTOFF_EPOCH_RESULT

    (( dir_epoch < cutoff_epoch ))
}

arm_visual_is_post_transfer_delete_date_directory_name() {
    local dir_name=$1

    if ! arm_visual_is_recent_date_directory_name "$dir_name"; then
        return 1
    fi

    arm_visual_is_older_than_days_directory_name "$dir_name" "$VISUAL_POST_TRANSFER_DELETE_DAYS"
}

arm_visual_is_recent_date_subtree() {
    local relative_path=$1
    local top_level

    arm_visual_get_top_level_component "$relative_path"
    top_level=$ARM_VISUAL_TOP_LEVEL_RESULT
    [[ -n "$top_level" ]] && arm_visual_is_recent_date_directory_name "$top_level"
}

arm_visual_is_expired_date_subtree() {
    local relative_path=$1
    local top_level

    arm_visual_get_top_level_component "$relative_path"
    top_level=$ARM_VISUAL_TOP_LEVEL_RESULT
    if [[ -z "$top_level" ]] || ! arm_visual_is_date_directory_name "$top_level"; then
        return 1
    fi

    ! arm_visual_is_recent_date_directory_name "$top_level"
}

arm_visual_is_post_transfer_delete_subtree() {
    local relative_path=$1
    local top_level

    arm_visual_get_top_level_component "$relative_path"
    top_level=$ARM_VISUAL_TOP_LEVEL_RESULT
    [[ -n "$top_level" ]] && arm_visual_is_post_transfer_delete_date_directory_name "$top_level"
}

arm_visual_is_transfer_whitelist_path() {
    local relative_path=$1
    local top_level

    arm_visual_get_top_level_component "$relative_path"
    top_level=$ARM_VISUAL_TOP_LEVEL_RESULT
    if [[ -z "$top_level" ]]; then
        return 1
    fi

    [[ "$relative_path" =~ ^${top_level}/[^/]+/ori/ ]] || [[ "$relative_path" =~ ^${top_level}/[^/]+/global/ori/ ]]
}

arm_visual_date_directory_has_remaining_whitelist_files() {
    local date_dir_path=$1
    local remaining_manifest

    remaining_manifest=$(mktemp "$STATE_DIR/remaining_whitelist.XXXXXX") ||
        fail_now "failed to allocate remaining whitelist manifest"
    if ! find "$date_dir_path" \
        \( -path "$date_dir_path/*/ori/*" -o -path "$date_dir_path/*/global/ori/*" \) \
        -type f -print -quit > "$remaining_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$remaining_manifest"
        log_error "Failed to inspect remaining visual whitelist files: [$date_dir_path]"
        return 0
    fi

    if [[ -s "$remaining_manifest" ]]; then
        rm -f -- "$remaining_manifest"
        return 0
    fi
    rm -f -- "$remaining_manifest"
    return 1
}

enumerate_transfer_files_for_source() {
    local source_dir=$1
    local date_dir_path
    local top_level_name
    local top_level_manifest
    local scan_failed=0

    if [[ "$source_dir" != "$ARM_VISUAL_SOURCE_DIR" ]]; then
        find "$source_dir" -type f -print0 2>> "$LOG_FILE"
        return
    fi

    top_level_manifest=$(mktemp "$STATE_DIR/visual_transfer_roots.XXXXXX") || return 1
    if ! find "$source_dir" -mindepth 1 -maxdepth 1 -type d -print0 \
        > "$top_level_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$top_level_manifest"
        return 1
    fi

    while IFS= read -r -d $'\0' date_dir_path; do
        top_level_name=${date_dir_path##*/}
        if ! arm_visual_is_date_directory_name "$top_level_name"; then
            continue
        fi

        if ! arm_visual_is_recent_date_directory_name "$top_level_name"; then
            continue
        fi

        find "$date_dir_path" \
            \( -path "$date_dir_path/*/ori/*" -o -path "$date_dir_path/*/global/ori/*" \) \
            -type f -print0 2>> "$LOG_FILE" || scan_failed=1
    done < "$top_level_manifest"
    rm -f -- "$top_level_manifest"
    (( scan_failed == 0 ))
}

# 说明:
# Arm 侧的迁移规则已经和 IPC 开始分化:
# 1. /logs/arm 目录下只迁移日志文件
# 2. /visual/arm 下日期目录只有 90 天内的目录会参与迁移, 且只迁移任务目录中的
#    ori 和 global/ori 文件
# 3. /visual/exception 暂时保持全量迁移, 避免异常现场数据遗漏
should_transfer_file_for_source() {
    local source_dir=$1
    local file_path=$2
    local relative_path=$3

    if [[ "$source_dir" == "$ARM_LOG_SOURCE_DIR" || "$source_dir" == "$ARM_CRASH_LOG_SOURCE_DIR" ]]; then
        [[ "$file_path" == *.log ]]
        return
    fi

    if [[ "$source_dir" == "$ARM_VISUAL_SOURCE_DIR" ]]; then
        if arm_visual_is_recent_date_subtree "$relative_path" && arm_visual_is_transfer_whitelist_path "$relative_path"; then
            return 0
        fi

        return 1
    fi

    return 0
}

enumerate_visual_cleanup_directories_for_source() {
    local source_dir=$1
    local date_dir_path
    local top_level_name
    local top_level_manifest

    if [[ "$source_dir" != "$ARM_VISUAL_SOURCE_DIR" ]]; then
        find "$source_dir" -depth -type d -print0 2>> "$LOG_FILE"
        return
    fi

    top_level_manifest=$(mktemp "$STATE_DIR/visual_cleanup_roots.XXXXXX") || return 1
    if ! find "$source_dir" -mindepth 1 -maxdepth 1 -type d -print0 \
        > "$top_level_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$top_level_manifest"
        return 1
    fi

    while IFS= read -r -d $'\0' date_dir_path; do
        top_level_name=${date_dir_path##*/}
        if arm_visual_is_date_directory_name "$top_level_name"; then
            printf '%s\0' "$date_dir_path"
        fi
    done < "$top_level_manifest"
    rm -f -- "$top_level_manifest"
}

cleanup_old_directories_for_target() {
    local target_dir=$1
    local target_class=$2
    local visual_target_dir
    local retention_days
    local cutoff_epoch
    local date_dir_path
    local top_level_name
    local dir_epoch
    local target_directory_manifest
    local total_date_directory_count=0
    local candidate_date_directory_count=0

    visual_target_dir=$(get_target_dir_for_source "$ARM_VISUAL_SOURCE_DIR")
    if [[ "$target_dir" != "$visual_target_dir" ]]; then
        return 0
    fi

    retention_days=$(get_retention_days_for_file_class "rgb" "$target_class")
    get_cutoff_date_cached "$retention_days"
    cutoff_epoch=$CUTOFF_EPOCH_RESULT

    target_directory_manifest=$(mktemp "$STATE_DIR/target_visual_directories.XXXXXX") ||
        fail_now "failed to allocate target visual directory manifest"
    if ! find "$target_dir" -mindepth 1 -maxdepth 1 -type d -print0 \
        > "$target_directory_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$target_directory_manifest"
        fail_now "failed to enumerate target visual date directories: [$target_dir]"
    fi

    while IFS= read -r -d $'\0' date_dir_path; do
        top_level_name=${date_dir_path##*/}
        arm_visual_is_date_directory_name "$top_level_name" || continue
        total_date_directory_count=$((total_date_directory_count + 1))
        arm_visual_get_date_epoch "$top_level_name" || continue
        dir_epoch=$ARM_VISUAL_DATE_EPOCH_RESULT
        if (( dir_epoch < cutoff_epoch )); then
            candidate_date_directory_count=$((candidate_date_directory_count + 1))
        fi
    done < "$target_directory_manifest"
    enforce_retention_tree_candidate_limit \
        "$total_date_directory_count" "$candidate_date_directory_count" "visual target $target_dir"

    while IFS= read -r -d $'\0' date_dir_path; do
        top_level_name=${date_dir_path##*/}
        if ! arm_visual_is_date_directory_name "$top_level_name"; then
            continue
        fi

        arm_visual_get_date_epoch "$top_level_name" || continue
        dir_epoch=$ARM_VISUAL_DATE_EPOCH_RESULT
        if (( dir_epoch >= cutoff_epoch )); then
            continue
        fi

        if $DRY_RUN; then
            log_info "[DRY-RUN] Would delete old visual target date directory: [$date_dir_path]"
            continue
        fi

        if safe_remove_retention_tree "$target_dir" "$date_dir_path"; then
            append_ledger_record "target_tree_deleted" "" "$date_dir_path" "directory" "deleted top-level visual date directory by retention ${retention_days} days" ||
                fail_now "failed to buffer visual target tree deletion"
            log_warn "Deleted old visual target date directory: [$date_dir_path]"
        else
            rm -f -- "$target_directory_manifest"
            fail_now "failed to delete old visual target date directory: [$date_dir_path]"
        fi
    done < "$target_directory_manifest"
    rm -f -- "$target_directory_manifest"
}

enumerate_old_files_for_target() {
    local target_dir=$1
    local _target_class=$2
    local visual_target_dir

    visual_target_dir=$(get_target_dir_for_source "$ARM_VISUAL_SOURCE_DIR")
    if [[ "$target_dir" != "$visual_target_dir" ]]; then
        find "$target_dir" -type f -print0
        return 0
    fi

    return 0
}

# 说明:
# 1. visual/arm 清理现在只按顶层日期目录决策, 不再继续深扫子目录
# 2. 超过 90 天的日期目录由整棵目录删除逻辑处理
# 3. 超过 14 天且进入"迁移完成后整棵删除"窗口的近期日期目录, 在白名单文件清空后整棵删除
# 4. 14 天内的日期目录不再做 stale non-whitelist 删除, 只在白名单迁移后通过空目录清理收尾

should_delete_directory_tree_for_source() {
    local source_dir=$1
    local subdir=$2
    local relative_path=$3

    if [[ "$source_dir" != "$ARM_VISUAL_SOURCE_DIR" ]]; then
        return 1
    fi

    if arm_visual_is_expired_date_subtree "$relative_path"; then
        local top_level
        arm_visual_get_top_level_component "$relative_path"
        top_level=$ARM_VISUAL_TOP_LEVEL_RESULT
        [[ "$relative_path" == "$top_level" ]]
        return
    fi

    # 说明:
    # 1. 14 天以上、90 天以内的日期目录, 在白名单文件已全部完成迁移并从源端清空后,
    #    直接整棵删除
    # 2. 如果仍有白名单文件残留, 说明本轮迁移未完全完成或存在冲突/校验失败, 必须保留
    #    源目录, 不能冒险整棵删除
    if arm_visual_is_post_transfer_delete_subtree "$relative_path"; then
        local top_level
        arm_visual_get_top_level_component "$relative_path"
        top_level=$ARM_VISUAL_TOP_LEVEL_RESULT
        if [[ "$relative_path" == "$top_level" ]] && \
           ! arm_visual_date_directory_has_remaining_whitelist_files "$subdir"; then
            return 0
        fi
    fi

    return 1
}

# 说明:
# U 盘上的 Arm 日志、RGB 图像和点云历史保留 90 天；未识别文件继续使用
# 既有 30 天默认值Arm 本机源文件在整轮同步、卸载和 manifest 提交成功后删除，
# 不以 90 天作为本机副本保留周期
declare -A RETENTION_DAYS_BY_SCOPE=(
    [removable:log]=90
    [removable:rgb]=90
    [removable:point_cloud]=90
    [removable:default]=30
    [global:default]=30
)

source "$SCRIPT_DIR/auto_transfer_common.sh"
source "$SCRIPT_DIR/auto_transfer_arm_archive.sh"
source "$SCRIPT_DIR/auto_transfer_removable_flow.sh"
source "$SCRIPT_DIR/auto_transfer_arm_flow.sh"

# Arm 入口只负责把原始命令行参数转交给公共主流程被测试 source 时只装配策略，
# 不启动真实迁移
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    auto_transfer_arm_main "$@"
fi
