#!/bin/bash

# 说明:
# 1. 本文件承载 Arm 与 IPC 共用的迁移基础设施, 包括状态管理、锁、账本、
#    空间预检查、迁移主流程、冲突处理、日志轮转以及清理主流程
# 2. 该文件只提供公共函数, 不直接作为入口脚本执行; 具体环境配置由 arm/ipc
#    入口脚本通过变量与钩子函数注入
# 3. 本次改造坚持最小侵入原则: 保持入口脚本接口不变, 保持上层 C++ 只依赖
#    固定状态文件和固定日志路径, 但把底层实现升级为更安全、更高效的方案

# 如果入口脚本没有预先计算路径, 这里提供一层兜底, 保证公共库被单独 source 时
# 也能工作脚本内部所有相对路径都围绕 WORKSPACE_ROOT 展开, 避免运行目录变化
# 导致路径歧义
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _COMMON_SOURCE_PATH=${BASH_SOURCE[0]}
    _COMMON_SOURCE_PARENT=${_COMMON_SOURCE_PATH%/*}
    [[ "$_COMMON_SOURCE_PARENT" == "$_COMMON_SOURCE_PATH" ]] && _COMMON_SOURCE_PARENT="."
    SCRIPT_DIR=$(cd "$_COMMON_SOURCE_PARENT" && pwd)
fi
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RUNTIME_NAME="${RUNTIME_NAME:-auto_transfer}"

# ======================
# 运行期路径配置
# ======================
# 说明:
# 1. FIXED_LOG_FILE 是对外稳定暴露给上层程序的固定日志入口路径
# 2. ACTIVE_LOG_FILE 是本次运行真实写入的按次日志文件
# 3. 为了兼容既有配置, 对外仍保留 FIXED_LOG_FILE, 但它会在运行时被更新为
#    指向 ACTIVE_LOG_FILE 的 latest 入口
FIXED_LOG_FILE="${LOG_FILE:-$WORKSPACE_ROOT/vpfi_data/auto_transfer/${RUNTIME_NAME}.log}"
LOG_FILE="$FIXED_LOG_FILE"
ACTIVE_LOG_FILE=""
STATE_FILE="${STATE_FILE:-$WORKSPACE_ROOT/vpfi_data/auto_transfer/${RUNTIME_NAME}.state}"
STATE_DETAIL_FILE="${STATE_DETAIL_FILE:-$WORKSPACE_ROOT/vpfi_data/auto_transfer/${RUNTIME_NAME}.state_detail}"
PID_FILE="${PID_FILE:-$WORKSPACE_ROOT/vpfi_data/auto_transfer/${RUNTIME_NAME}.pid}"
STATE_DIR="${STATE_DIR:-$WORKSPACE_ROOT/vpfi_data/auto_transfer/${RUNTIME_NAME}_state}"
LOCK_FILE="${LOCK_FILE:-$STATE_DIR/${RUNTIME_NAME}.lock}"
LEDGER_FILE="${LEDGER_FILE:-$STATE_DIR/${RUNTIME_NAME}_ledger.tsv}"
IPC_VERIFIED_INDEX_FILE="${IPC_VERIFIED_INDEX_FILE:-$STATE_DIR/${RUNTIME_NAME}_verified_index.v1}"
IPC_RETENTION_DATE_FILE="${IPC_RETENTION_DATE_FILE:-$STATE_DIR/${RUNTIME_NAME}.last_retention_date}"

# TMP_SUFFIX 用于标记公共库自身生成的临时文件, 后续清理时只会处理该命名空间
# 下的陈旧残留, 避免误删其他业务文件
TMP_SUFFIX=".auto_transfer_tmp"
RUN_LOG_RETENTION_COUNT=30
LOG_PROTECT_DAYS=2
VISUAL_STALE_DIRECTORY_DAYS="${VISUAL_STALE_DIRECTORY_DAYS:-7}"
RSYNC_MODIFY_WINDOW=2
RSYNC_SCAN_PROGRESS_INTERVAL="${RSYNC_SCAN_PROGRESS_INTERVAL:-1000}"
RSYNC_VERIFY_PROGRESS_INTERVAL="${RSYNC_VERIFY_PROGRESS_INTERVAL:-200}"
VISUAL_CLEANUP_PROGRESS_INTERVAL="${VISUAL_CLEANUP_PROGRESS_INTERVAL:-200}"
IPC_PREFLIGHT_PROGRESS_INTERVAL="${IPC_PREFLIGHT_PROGRESS_INTERVAL:-200}"
RETENTION_MAX_TREE_DELETIONS="${RETENTION_MAX_TREE_DELETIONS:-50}"
RETENTION_MAX_TREE_DELETE_PERCENT="${RETENTION_MAX_TREE_DELETE_PERCENT:-80}"
RETENTION_MAX_FILE_DELETIONS="${RETENTION_MAX_FILE_DELETIONS:-100000}"
RETENTION_MAX_DELETE_BYTES="${RETENTION_MAX_DELETE_BYTES:-53687091200}"
TIME_MAX_BACKWARD_SECONDS="${TIME_MAX_BACKWARD_SECONDS:-86400}"
TIME_MAX_FORWARD_SECONDS="${TIME_MAX_FORWARD_SECONDS:-1209600}"
TIME_MIN_EPOCH="${TIME_MIN_EPOCH:-1704067200}"
TIME_MAX_EPOCH="${TIME_MAX_EPOCH:-4102444800}"
TIME_ALLOW_PLAUSIBLE_FIRST_RUN="${TIME_ALLOW_PLAUSIBLE_FIRST_RUN:-false}"
DRY_RUN=false
STOP_REQUEST_ONLY=false
STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-120}"
INTERRUPT_REQUESTED=false
INTERRUPT_DETAIL=""
ACTIVE_CHILD_PID=""
AUTO_TRANSFER_LOCK_HELD=false
IPC_PREFLIGHT_METADATA_GUARD_HELD=false
IPC_PREFLIGHT_METADATA_GUARD_FD=""
SHA256_RESULT=""
SUM_PENDING_COPY_BYTES_RESULT=0
FILE_FINGERPRINT_RESULT=""
FILES_EQUIVALENT_FAST_PATH=false
IPC_VERIFIED_INDEX_LOADED=false
IPC_VERIFIED_INDEX_DIRTY=false
IPC_RETENTION_PERFORMED=false
IPC_FORCE_FULL_AUDIT="${IPC_FORCE_FULL_AUDIT:-false}"
IPC_FORCE_RETENTION="${IPC_FORCE_RETENTION:-false}"
IPC_FAST_SKIP_TOTAL=0
# Copy fingerprints and cleanup mtimes use separate, read-only sessions.
IPC_HISTORY_ACTIVE=false
IPC_HISTORY_MODE=fingerprint
IPC_HISTORY_VALUE_RESULT=""
IPC_INDEX_TEMP_FILE=""
IPC_INDEX_TEMP_OWNER=""
IPC_HISTORY_DISABLED=false
IPC_HISTORY_WORKER_PID=""
IPC_HISTORY_OWNER_PID=""
IPC_HISTORY_STARTTIME=""
IPC_HISTORY_READ_FD=""
IPC_HISTORY_WRITE_FD=""
IPC_HISTORY_ORIGINAL_READ_FD=""
IPC_HISTORY_ORIGINAL_WRITE_FD=""
IPC_HISTORY_CHILD_STATE=""
IPC_HISTORY_TIMEOUT=5
IPC_HISTORY_TZ_SET=""
IPC_HISTORY_TZ=""
IPC_HISTORY_SEQUENCE=0
IPC_HISTORY_REQUESTS=0

# 冲突统计用于在整批迁移结束时统一上报失败这样既能保证单个冲突不会阻断
# 其他文件迁移, 也能确保整体结果仍被上层视为失败
CONFLICT_TOTAL=0
QUARANTINED_CONFLICT_TOTAL=0
declare -A CONFLICT_COUNTS_BY_SOURCE=()
declare -A BACKED_UP_SOURCE_INDEX=()
declare -A RETENTION_PROTECTED_PATHS=()
declare -A CUTOFF_DATE_CACHE=()
declare -A CUTOFF_EPOCH_CACHE=()
declare -A PREPARED_RSYNC_LISTS=()
declare -A PREPARED_RSYNC_BYTES=()
declare -A TARGET_READY_INDEX=()
declare -A TARGET_SPACE_PREFLIGHTED=()
declare -A DATE_VALIDATION_CACHE=()
declare -A IPC_VERIFIED_SOURCE_FINGERPRINTS=()
declare -A IPC_VERIFIED_TARGET_PATHS=()
declare -A IPC_VERIFIED_TARGET_FINGERPRINTS=()
declare -A IPC_VERIFIED_SHA256=()
declare -A IPC_VERIFIED_THIS_RUN=()
declare -A IPC_PREFLIGHT_SOURCE_MANIFESTS=()
declare -A IPC_PREFLIGHT_SOURCE_COUNTS=()
declare -a IPC_PREFLIGHT_METADATA_TEMP_FILES=()

# 运行起始时间用于判定哪些临时文件属于历史残留, 以及日志轮转和清理操作的
# 当前批次边界
RUN_START_EPOCH="$(date +%s)"
RUN_ID="${RUNTIME_NAME}_$(date +"%Y%m%d_%H%M%S")_$$"
RUN_REFERENCE_EPOCH=0
RUN_REFERENCE_DATE=""
RUN_TODAY=""
RUN_YESTERDAY=""
TIME_TRUSTED=false
TIME_TRUST_DETAIL="not_checked"
RETENTION_TREE_DELETE_COUNT=0
RETENTION_FILE_DELETE_COUNT=0
RETENTION_DELETE_BYTES=0
LEDGER_BUFFER_FILE=""
SOURCE_DELETE_PENDING_PATHS_FILE=""
SOURCE_DELETE_PENDING_RECORDS_FILE=""
SOURCE_DELETE_COMMITTED_PATHS_FILE=""
SOURCE_DELETE_COMMITTED_RECORDS_FILE=""
SOURCE_DELETE_MANIFEST_COMMITTED=false
LAST_TRUSTED_TIME_FILE="$STATE_DIR/${RUNTIME_NAME}.last_trusted_epoch"
REMOVABLE_MOUNT_OWNED=false
REMOVABLE_MOUNT_COMMITTED=false
REMOVABLE_ACTIVE_TARGET=""
REMOVABLE_ACTIVE_SOURCE=""
REMOVABLE_ACTIVE_UUID=""
REMOVABLE_ACTIVE_LABEL=""
REMOVABLE_ACTIVE_MAJMIN=""
MOUNT_INFO_ERROR_DETAIL="not_checked"
REMOVABLE_EXPECTED_SPEC=""
REMOVABLE_EXPECTED_DEVICE=""
REMOVABLE_IDENTITY_DESCRIPTION=""
MOUNT_TARGETS_RESULT=""
PHASE_TIMING_INITIALIZED=false
PHASE_RUN_START_SECONDS=0
CURRENT_PHASE_NAME=""
CURRENT_PHASE_START_SECONDS=0
MONOTONIC_SECONDS_RESULT=0
MONOTONIC_MILLISECONDS_RESULT=0
declare -a PHASE_TIMING_RECORDS=()


# ======================
# 日志与原子写入
# ======================
# 输出统一的毫秒级时间戳, 便于后续追踪脚本卡在哪一步、哪一批文件耗时异常
format_log_timestamp() {
    printf '%(%Y-%m-%d %H:%M:%S)T' -1
}

# 原子写文本文件:
# 1. 先在目标文件同目录创建临时文件, 保证后续 mv 仍在同一文件系统内完成
# 2. 写入完整内容后再 mv 覆盖正式文件, 避免中断时留下半写入文本
write_text_atomically() {
    local file_path=$1
    local file_content=$2
    local parent_dir
    local base_name
    local temp_file

    parent_dir=${file_path%/*}
    base_name=${file_path##*/}

    mkdir -p "$parent_dir" || return 1
    temp_file=$(mktemp "$parent_dir/.${base_name}.tmp.XXXXXX") || return 1

    if ! printf '%s' "$file_content" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! mv -f "$temp_file" "$file_path"; then
        rm -f "$temp_file"
        return 1
    fi

    return 0
}

# 原子写入单行文本文件:
# 1. 该函数专门用于 state/state_detail/pid 这类单行文件
# 2. 与通用 write_text_atomically 不同, 这里会稳定追加一个真实换行符, 避免把
#    字面量 "\n" 写入文件内容
write_line_atomically() {
    local file_path=$1
    local line_content=$2
    local parent_dir
    local base_name
    local temp_file

    parent_dir=${file_path%/*}
    base_name=${file_path##*/}

    mkdir -p "$parent_dir" || return 1
    temp_file=$(mktemp "$parent_dir/.${base_name}.tmp.XXXXXX") || return 1

    if ! printf '%s\n' "$line_content" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! mv -f "$temp_file" "$file_path"; then
        rm -f "$temp_file"
        return 1
    fi

    return 0
}

# 统一日志输出:
# 1. 终端输出保留给调用方和 systemd 观察
# 2. 真实落盘写入 ACTIVE_LOG_FILE, 不再向固定日志入口无限追加
log_message() {
    local level=$1
    shift
    local message="$*"
    local line

    line="[$(format_log_timestamp)] [${level}] ${message}"
    printf '%s\n' "$line"

    if [[ -n "$ACTIVE_LOG_FILE" ]]; then
        printf '%s\n' "$line" >> "$ACTIVE_LOG_FILE"
    fi
}

log_debug() { log_message "debug" "$*"; }
log_info() { log_message "info" "$*"; }
log_warn() { log_message "warn" "$*"; }
log_error() { log_message "error" "$*"; }

# 分阶段耗时优先读取 Linux /proc/uptime 的单调时钟；非 Linux 测试环境回退到 Bash SECONDS
# 每个阶段结束时立即输出一条日志；整轮结束、失败或中断时再输出一条汇总日志
get_monotonic_seconds() {
    local uptime_value=""

    if [[ -r /proc/uptime ]] && read -r uptime_value _ < /proc/uptime &&
       [[ "$uptime_value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        MONOTONIC_SECONDS_RESULT=${uptime_value%%.*}
    else
        MONOTONIC_SECONDS_RESULT=$SECONDS
    fi
}

get_monotonic_milliseconds() {
    local uptime_value=""
    local uptime_seconds
    local uptime_fraction
    local epoch_seconds
    local epoch_fraction

    if [[ -r /proc/uptime ]] && read -r uptime_value _ < /proc/uptime &&
       [[ "$uptime_value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        uptime_seconds=${uptime_value%%.*}
        uptime_fraction=${uptime_value#*.}
        [[ "$uptime_fraction" == "$uptime_value" ]] && uptime_fraction=0
        uptime_fraction="${uptime_fraction}000"
        MONOTONIC_MILLISECONDS_RESULT=$((10#$uptime_seconds * 1000 + 10#${uptime_fraction:0:3}))
    elif [[ "${EPOCHREALTIME:-}" =~ ^([0-9]+)[.]([0-9]+)$ ]]; then
        epoch_seconds=${BASH_REMATCH[1]}
        epoch_fraction="${BASH_REMATCH[2]}000"
        MONOTONIC_MILLISECONDS_RESULT=$((10#$epoch_seconds * 1000 + 10#${epoch_fraction:0:3}))
    else
        MONOTONIC_MILLISECONDS_RESULT=$((SECONDS * 1000))
    fi
}

format_milliseconds_as_seconds() {
    local milliseconds=$1

    awk -v milliseconds="$milliseconds" \
        'BEGIN {printf "%.3f", milliseconds / 1000}'
}

initialize_phase_timing() {
    get_monotonic_seconds
    PHASE_RUN_START_SECONDS=$MONOTONIC_SECONDS_RESULT
    CURRENT_PHASE_NAME=""
    CURRENT_PHASE_START_SECONDS=0
    PHASE_TIMING_RECORDS=()
    PHASE_TIMING_INITIALIZED=true
}

start_timed_phase() {
    local phase_name=$1

    if [[ -n "$CURRENT_PHASE_NAME" ]]; then
        finish_timed_phase "implicit_finish"
    fi

    get_monotonic_seconds
    CURRENT_PHASE_NAME=$phase_name
    CURRENT_PHASE_START_SECONDS=$MONOTONIC_SECONDS_RESULT
    log_info "Phase started: phase = [$CURRENT_PHASE_NAME]"
}

finish_timed_phase() {
    local phase_status=${1:-"ok"}
    local phase_duration

    if ! $PHASE_TIMING_INITIALIZED || [[ -z "$CURRENT_PHASE_NAME" ]]; then
        return 0
    fi

    get_monotonic_seconds
    phase_duration=$((MONOTONIC_SECONDS_RESULT - CURRENT_PHASE_START_SECONDS))
    PHASE_TIMING_RECORDS+=("${CURRENT_PHASE_NAME}:${phase_status}/${phase_duration}s")
    log_info "Phase timing: phase = [$CURRENT_PHASE_NAME], status = [$phase_status], duration_s = [$phase_duration]"
    CURRENT_PHASE_NAME=""
    CURRENT_PHASE_START_SECONDS=0
}

log_phase_timing_summary() {
    local run_status=${1:-"completed"}
    local total_duration
    local timing_summary=""
    local timing_record

    $PHASE_TIMING_INITIALIZED || return 0

    get_monotonic_seconds
    total_duration=$((MONOTONIC_SECONDS_RESULT - PHASE_RUN_START_SECONDS))
    for timing_record in "${PHASE_TIMING_RECORDS[@]}"; do
        [[ -n "$timing_summary" ]] && timing_summary+=" | "
        timing_summary+="$timing_record"
    done

    log_info "Timing summary: run_status = [$run_status], total_s = [$total_duration], phases = [$timing_summary]"
}

# 初始化按次运行日志并更新固定 latest 入口
# 这里固定日志入口使用符号链接指向最新 run log, 这样既兼容上层固定路径契约,
# 又避免单个日志文件无限追加
initialize_runtime_logging() {
    local log_parent
    local run_log_name

    log_parent=${FIXED_LOG_FILE%/*}
    mkdir -p "$log_parent" || fail_now "failed to create log directory: $log_parent"

    run_log_name="${RUN_ID}.log"
    ACTIVE_LOG_FILE="$log_parent/$run_log_name"
    : > "$ACTIVE_LOG_FILE" || fail_now "failed to create run log file: $ACTIVE_LOG_FILE"

    if ! ln -sfn "$run_log_name" "$FIXED_LOG_FILE"; then
        fail_now "failed to update latest log link: $FIXED_LOG_FILE"
    fi

    # 后续代码历史上大量直接重定向到 LOG_FILE为了减少侵入修改, 在日志初始化
    # 完成后把 LOG_FILE 指向本次真实写入文件
    LOG_FILE="$ACTIVE_LOG_FILE"
}

# 只保留最近 N 次运行日志固定 latest 入口不计入轮转名额
rotate_run_logs() {
    local log_parent
    local run_log_manifest
    local -a run_logs
    local index

    log_parent=${FIXED_LOG_FILE%/*}
    run_log_manifest=$(mktemp "$log_parent/.run_logs.XXXXXX") ||
        fail_now "failed to allocate run log rotation manifest"
    if ! find "$log_parent" -maxdepth 1 -type f \
        -name "${RUNTIME_NAME}_[0-9][0-9]*.log" -printf '%f\n' \
        > "$run_log_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$run_log_manifest"
        fail_now "failed to enumerate run logs for rotation"
    fi
    sort -o "$run_log_manifest" "$run_log_manifest" ||
        fail_now "failed to sort run logs for rotation"
    mapfile -t run_logs < "$run_log_manifest"
    rm -f -- "$run_log_manifest"

    if (( ${#run_logs[@]} <= RUN_LOG_RETENTION_COUNT )); then
        return 0
    fi
    if $DRY_RUN; then
        log_info "[DRY-RUN] Would rotate $(( ${#run_logs[@]} - RUN_LOG_RETENTION_COUNT )) old run logs."
        return 0
    fi

    for (( index = 0; index < ${#run_logs[@]} - RUN_LOG_RETENTION_COUNT; ++index )); do
        if ! rm -f -- "$log_parent/${run_logs[$index]}" ||
           [[ -e "$log_parent/${run_logs[$index]}" ]]; then
            fail_now "failed to remove expired run log: [$log_parent/${run_logs[$index]}]"
        fi
    done
}


# ======================
# 状态管理
# ======================
# 设置任务状态状态文件与详细状态文件都走原子写入, 避免脚本被中断时留下半行内容
set_state() {
    local state_code=$1 state_text=$2
    # Publish the code last. Two files are not a transaction; callers must
    # propagate failure rather than claiming the old state is current.
    if ! write_line_atomically "$STATE_DETAIL_FILE" "$state_text"; then
        log_error "Failed to persist state detail: [$STATE_DETAIL_FILE]" >&2 || true
        return 1
    fi
    if ! write_line_atomically "$STATE_FILE" "$state_code"; then
        log_error "Failed to persist state code: [$STATE_FILE]" >&2 || true
        return 1
    fi
    return 0
}

set_state_or_fail() {
    set_state "$@" || fail_now "failed to persist runtime state: code = [$1]"
}

# 统一错误退出函数
# 说明:
# 1. message 只负责描述日志
# 2. 最终 detail 仍统一落到 failed, 避免在突发错误路径上写出不一致的复杂状态
fail_now() {
    # 错误信息, 默认值为 unknown_error
    local message=${1:-"unknown_error"}
    log_error "$message"
    finish_timed_phase "failed"
    log_phase_timing_summary "failed"
    flush_ledger_buffer || true
    set_state "-1" "$message" || true
    exit 1
}

# 统一中断退出函数
# 说明:
# 1. 被管理层或信号中断时使用该路径，状态与失败语义分离
# 2. detail 允许调用方按场景写入，例如 interrupted_by_signal / user_stop_requested
fail_interrupted() {
    local detail=${1:-"interrupted_by_signal"}
    log_warn "script interrupted: ${detail}"
    finish_timed_phase "interrupted"
    log_phase_timing_summary "interrupted"
    flush_ledger_buffer || true
    set_state "3" "$detail" || true
    exit 130
}

request_runtime_interruption() {
    local signal_name=${1:-TERM}

    INTERRUPT_REQUESTED=true
    INTERRUPT_DETAIL="interrupted_by_${signal_name,,}"
    if [[ "$ACTIVE_CHILD_PID" =~ ^[0-9]+$ ]] &&
       kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; then
        kill -TERM "$ACTIVE_CHILD_PID" 2>/dev/null || true
    fi
}

check_interruption_requested() {
    if $INTERRUPT_REQUESTED; then
        fail_interrupted "${INTERRUPT_DETAIL:-interrupted_by_signal}"
    fi
}

# Run a foreground operation as an explicitly tracked child. Bash normally
# defers a trap while waiting for a synchronous child; tracking the child lets
# the stop interface terminate rsync/tar/zip promptly while the parent keeps
# ownership of cleanup, sync and normal unmount.
run_interruptible_command() {
    local command_status
    local child_pid
    local ipc_operation_started=$SECONDS
    if [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]]; then
        case "$1" in
            cp) IPC_COPY_STAGE=copy_file; IPC_COPY_CURRENT=${@: -2:1} ;;
            sha256sum) IPC_COPY_STAGE=verify_hash; IPC_COPY_CURRENT=${@: -1} ;;
        esac
        # Keep diagnostic output out of captured command stdout (SHA-256).
        log_ipc_copy_progress false >&2
    fi

    check_interruption_requested
    "$@" &
    child_pid=$!
    ACTIVE_CHILD_PID=$child_pid
    wait "$child_pid"
    command_status=$?
    if $INTERRUPT_REQUESTED && kill -0 "$child_pid" 2>/dev/null; then
        wait "$child_pid" 2>/dev/null || true
    fi
    ACTIVE_CHILD_PID=""
    check_interruption_requested
    if [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]] &&
       (( SECONDS - ipc_operation_started >= IPC_COPY_INTERVAL )); then
        log_info "IPC copy operation timing: command = [$1], duration_s = [$((SECONDS - ipc_operation_started))], exit_code = [$command_status], current = [$IPC_COPY_CURRENT]" >&2 || true
    fi
    return "$command_status"
}

run_interruptible_command_in_directory() {
    local working_directory=$1
    local original_directory=$PWD
    local command_status
    shift

    cd "$working_directory" || return 1
    run_interruptible_command "$@"
    command_status=$?
    cd "$original_directory" || fail_now "failed to restore working directory after interruptible command"
    return "$command_status"
}

request_running_instance_stop() {
    local requested_pid=""
    local expected_entry="${RUNTIME_NAME}.sh"
    local command_line=""
    local wait_seconds=${STOP_WAIT_SECONDS:-60}
    local waited=0

    if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]] || (( wait_seconds < 1 || wait_seconds > 300 )); then
        echo "[ERROR] STOP_WAIT_SECONDS must be an integer between 1 and 300" >&2
        return 2
    fi
    if [[ ! -f "$PID_FILE" ]]; then
        echo "[INFO] No running $RUNTIME_NAME instance was found."
        return 0
    fi
    IFS= read -r requested_pid < "$PID_FILE" || true
    if [[ ! "$requested_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$requested_pid" 2>/dev/null; then
        echo "[INFO] No live process matches the recorded $RUNTIME_NAME PID."
        return 0
    fi
    if [[ -r "/proc/$requested_pid/cmdline" ]]; then
        command_line=$(tr '\0' ' ' < "/proc/$requested_pid/cmdline")
        if [[ "$command_line" != *"$expected_entry"* ]]; then
            echo "[ERROR] Refused to signal PID $requested_pid because its command line does not contain [$expected_entry]." >&2
            return 1
        fi
    else
        echo "[ERROR] Refused to signal PID $requested_pid because /proc identity cannot be inspected." >&2
        return 1
    fi

    echo "[INFO] Requesting graceful stop for $RUNTIME_NAME PID $requested_pid."
    if ! kill -TERM "$requested_pid"; then
        echo "[ERROR] Failed to send TERM to PID $requested_pid." >&2
        return 1
    fi

    while kill -0 "$requested_pid" 2>/dev/null; do
        if (( waited >= wait_seconds )); then
            echo "[ERROR] $RUNTIME_NAME did not stop within ${wait_seconds}s; no KILL signal was sent." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "[INFO] $RUNTIME_NAME stopped gracefully after ${waited}s."
}


# ======================
# 初始化
# ======================
# 退出时清理运行期 PID 文件. 
# 锁文件对应的 flock 由进程退出自动释放, 因此这里只需要处理兼容旧逻辑的 PID_FILE. 
cleanup_runtime() {
    local recorded_pid=""

    stop_ipc_history_reader || true
    cleanup_ipc_index_temp_file || true
    flush_ledger_buffer || true
    cleanup_ipc_preflight_metadata_temp_files || true

    if declare -F cleanup_arm_visual_archive_runtime >/dev/null 2>&1; then
        cleanup_arm_visual_archive_runtime || true
    fi

    if declare -F release_removable_target >/dev/null 2>&1; then
        release_removable_target || true
    fi

    # PID 在介质同步和卸载完成后再清理，避免 --stop 和运维观察在退出清理
    # 尚未完成时误判实例已经完全停止
    if [[ -f "$PID_FILE" ]]; then
        IFS= read -r recorded_pid < "$PID_FILE" || true
        if [[ "$recorded_pid" == "$$" ]]; then
            rm -f -- "$PID_FILE"
        fi
    fi

    [[ -n "$LEDGER_BUFFER_FILE" ]] && rm -f -- "$LEDGER_BUFFER_FILE"
    [[ -n "$SOURCE_DELETE_PENDING_PATHS_FILE" ]] && rm -f -- "$SOURCE_DELETE_PENDING_PATHS_FILE"
    [[ -n "$SOURCE_DELETE_PENDING_RECORDS_FILE" ]] && rm -f -- "$SOURCE_DELETE_PENDING_RECORDS_FILE"

    local prepared_list
    for prepared_list in "${PREPARED_RSYNC_LISTS[@]}"; do
        [[ -n "$prepared_list" ]] && rm -f -- "$prepared_list"
    done
    for prepared_list in "${IPC_PREFLIGHT_SOURCE_MANIFESTS[@]}"; do
        [[ -n "$prepared_list" ]] && rm -f -- "$prepared_list"
    done
}

# 初始化运行时参数与信号处理. 
# 入口脚本只需要把原始命令行参数透传进来, 公共库会统一处理 dry-run 等基础开关. 
setup_auto_transfer_runtime() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=true
                ;;
            --stop)
                STOP_REQUEST_ONLY=true
                ;;
            *)
                echo "[ERROR] Unsupported argument: $arg" >&2
                exit 2
                ;;
        esac
    done

    if $STOP_REQUEST_ONLY; then
        request_running_instance_stop
        exit $?
    fi

    if $DRY_RUN; then
        echo "[INFO] Dry-run mode enabled. No files will be moved or deleted."
    elif (( EUID != 0 )); then
        echo "[ERROR] auto_transfer must run as root under the systemd service." >&2
        exit 1
    fi

    validate_source_directory_order

    # EXIT: 无论正常结束还是异常退出, 都会执行运行期清理. 
    # INT/TERM/HUP: 标记停止请求，并终止当前受控的长任务实际退出仍由主进程
    # 负责，以便执行 sync 和普通卸载，且不会提交未完成的删源 manifest
    trap cleanup_runtime EXIT
    trap 'request_runtime_interruption HUP' HUP
    trap 'request_runtime_interruption INT' INT
    trap 'request_runtime_interruption TERM' TERM
}

validate_source_directory_order() {
    local source_dir
    local -A seen_sources=()

    if ! declare -p SOURCE_DIR_ORDER >/dev/null 2>&1; then
        echo "[ERROR] SOURCE_DIR_ORDER must explicitly define source processing order." >&2
        exit 1
    fi
    if (( ${#SOURCE_DIR_ORDER[@]} != ${#SOURCE_RELATIVE_TARGETS[@]} )); then
        echo "[ERROR] SOURCE_DIR_ORDER must contain every configured source exactly once." >&2
        exit 1
    fi

    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        if [[ -z "$source_dir" ||
              -z "${SOURCE_RELATIVE_TARGETS[$source_dir]+x}" ||
              -n "${seen_sources[$source_dir]+x}" ]]; then
            echo "[ERROR] SOURCE_DIR_ORDER contains an empty, unknown or duplicate source: [$source_dir]" >&2
            exit 1
        fi
        seen_sources["$source_dir"]=1
    done
}


# ======================
# 工具函数
# ======================
# 根据保留天数计算截止日期. 
# 后续清理时会把文件日期或 mtime 与该日期做字符串比较. 
get_cutoff_date_cached() {
    local days=$1
    local cutoff_epoch

    if [[ -z "${CUTOFF_DATE_CACHE[$days]+x}" ]]; then
        cutoff_epoch=$((RUN_REFERENCE_EPOCH - days * 86400))
        CUTOFF_DATE_CACHE[$days]=$(date -d "@$cutoff_epoch" +"%Y-%m-%d")
        CUTOFF_EPOCH_CACHE[$days]=$(date -d "${CUTOFF_DATE_CACHE[$days]} 00:00:00" +%s)
    fi

    CUTOFF_DATE_RESULT=${CUTOFF_DATE_CACHE[$days]}
    CUTOFF_EPOCH_RESULT=${CUTOFF_EPOCH_CACHE[$days]}
}

# 初始化脚本运行所需的状态目录、日志文件和账本文件. 
# 这里属于脚本启动前置条件, 一旦失败直接终止, 因为后续所有恢复和审计都依赖这些文件. 
ensure_state_files() {
    mkdir -p "$STATE_DIR" || fail_now "failed to create state directory: $STATE_DIR"
    initialize_runtime_logging
    touch "$LEDGER_FILE" || fail_now "failed to initialize ledger file: $LEDGER_FILE"
    touch "$STATE_FILE" "$STATE_DETAIL_FILE" || fail_now "failed to initialize state files"
    LEDGER_BUFFER_FILE=$(mktemp "$STATE_DIR/ledger_buffer.XXXXXX") || fail_now "failed to allocate ledger buffer"
    SOURCE_DELETE_PENDING_PATHS_FILE=$(mktemp "$STATE_DIR/source_delete_pending_paths.XXXXXX") ||
        fail_now "failed to allocate pending source delete manifest"
    SOURCE_DELETE_PENDING_RECORDS_FILE=$(mktemp "$STATE_DIR/source_delete_pending_records.XXXXXX") ||
        fail_now "failed to allocate pending source delete records"
    SOURCE_DELETE_COMMITTED_PATHS_FILE="$STATE_DIR/${RUN_ID}.committed_source_paths0"
    SOURCE_DELETE_COMMITTED_RECORDS_FILE="$STATE_DIR/${RUN_ID}.committed_source_records0"
    rotate_run_logs

    if $DRY_RUN; then
        log_info "Dry-run mode enabled. No files will be moved or deleted."
    fi
}

acquire_lock() {
    # 说明:
    # flock 由内核负责释放锁; 即使脚本异常退出, 也不会遗留"假锁". 
    # 这里使用独占非阻塞锁, 确保任意时刻只能有一个迁移实例运行. 
    if ! command -v flock >/dev/null 2>&1; then
        echo "[ERROR] required command is missing before locking: flock" >&2
        exit 1
    fi

    mkdir -p "$STATE_DIR" || {
        echo "[ERROR] failed to create state directory before locking: $STATE_DIR" >&2
        exit 1
    }

    exec 9>"$LOCK_FILE" || {
        echo "[ERROR] failed to open lock file: $LOCK_FILE" >&2
        exit 1
    }
    if ! flock -n 9; then
        echo "[ERROR] another auto_transfer instance is already running" >&2
        exit 75
    fi
    AUTO_TRANSFER_LOCK_HELD=true
}

# 向账本追加一条记录. 
# 每条记录都携带时间、状态、源文件、目标文件和文件类别, 便于事后追踪迁移与清理动作. 
append_ledger_record() {
    local status=$1
    local source_path=$2
    local target_path=$3
    local file_class=$4
    local detail=$5

    local timestamp

    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1

    if [[ -z "$LEDGER_BUFFER_FILE" ]]; then
        return 1
    fi

    # 说明:
    # 单文件记录先写入本轮缓冲区, 在阶段边界批量追加到账本, 避免每个文件重复
    # 启动 date/cat 等外部进程
    printf '%s\t[%-15s]\t[%s]\t[%s]\t[%s]\t[%s]\n' \
        "$timestamp" \
        "$status" \
        "$source_path" \
        "$target_path" \
        "$file_class" \
        "$detail" >> "$LEDGER_BUFFER_FILE" || return 1
}

flush_ledger_buffer() {
    if [[ -z "$LEDGER_BUFFER_FILE" || ! -f "$LEDGER_BUFFER_FILE" || ! -s "$LEDGER_BUFFER_FILE" ]]; then
        return 0
    fi

    if ! cat "$LEDGER_BUFFER_FILE" >> "$LEDGER_FILE"; then
        return 1
    fi

    : > "$LEDGER_BUFFER_FILE"
}

# 获取某个源目录对应的目标环境类型. 
# 如果该目录没有单独覆盖配置, 则继承 DEFAULT_TARGET_CLASS. 
get_target_class_for_source() {
    local source_dir=$1
    echo "${SOURCE_TARGET_CLASSES[$source_dir]:-$DEFAULT_TARGET_CLASS}"
}

get_target_dir_for_source() {
    local source_dir=$1
    local target_class
    local target_root
    local relative_target

    target_class=$(get_target_class_for_source "$source_dir")
    target_root=${TARGET_ROOTS[$target_class]}
    relative_target=${SOURCE_RELATIVE_TARGETS[$source_dir]}

    if [[ -z "$target_root" || -z "$relative_target" ]]; then
        fail_now "missing target configuration for source directory: $source_dir"
    fi

    echo "$target_root/$relative_target"
}

validate_source_target_separation() {
    local source_dir=$1
    local target_dir=$2
    local resolved_source
    local resolved_target

    resolved_source=$(realpath -m "$source_dir") ||
        fail_now "failed to resolve source path: [$source_dir]"
    resolved_target=$(realpath -m "$target_dir") ||
        fail_now "failed to resolve target path: [$target_dir]"

    if [[ "$resolved_source" == "$resolved_target" ||
          "$resolved_source" == "$resolved_target/"* ||
          "$resolved_target" == "$resolved_source/"* ]]; then
        fail_now "source and target directories must not overlap: source = [$resolved_source], target = [$resolved_target]"
    fi
}

initialize_time_context() {
    local last_trusted_epoch=""
    local ntp_synchronized="no"
    local delta=0

    RUN_REFERENCE_EPOCH=$(date +%s) || fail_now "failed to read system time"
    RUN_REFERENCE_DATE=$(date -d "@$RUN_REFERENCE_EPOCH" +"%Y-%m-%d") || fail_now "failed to format system time"
    RUN_TODAY="$RUN_REFERENCE_DATE"
    RUN_YESTERDAY=$(date -d "@$((RUN_REFERENCE_EPOCH - 86400))" +"%Y-%m-%d") || fail_now "failed to calculate yesterday"

    if command -v timedatectl >/dev/null 2>&1; then
        ntp_synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "no")
    fi

    if [[ -f "$LAST_TRUSTED_TIME_FILE" ]]; then
        IFS= read -r last_trusted_epoch < "$LAST_TRUSTED_TIME_FILE" || true
    fi

    if (( RUN_REFERENCE_EPOCH < TIME_MIN_EPOCH || RUN_REFERENCE_EPOCH > TIME_MAX_EPOCH )); then
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL="system_time_outside_plausible_range"
    elif [[ "$ntp_synchronized" == "yes" ]]; then
        TIME_TRUSTED=true
        TIME_TRUST_DETAIL="ntp_synchronized"
    elif [[ "$last_trusted_epoch" =~ ^[0-9]+$ ]]; then
        delta=$((RUN_REFERENCE_EPOCH - last_trusted_epoch))
        if (( delta < -TIME_MAX_BACKWARD_SECONDS )); then
            TIME_TRUSTED=false
            TIME_TRUST_DETAIL="system_time_moved_backwards"
        elif (( delta > TIME_MAX_FORWARD_SECONDS )); then
            TIME_TRUSTED=false
            TIME_TRUST_DETAIL="system_time_jump_too_large"
        else
            TIME_TRUSTED=true
            TIME_TRUST_DETAIL="persistent_time_continuity"
        fi
    elif [[ "$TIME_ALLOW_PLAUSIBLE_FIRST_RUN" == "true" ]]; then
        TIME_TRUSTED=true
        TIME_TRUST_DETAIL="first_run_plausible_time_explicitly_allowed"
    else
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL="first_run_requires_ntp_or_explicit_time_approval"
    fi

    if $TIME_TRUSTED; then
        log_info "Retention time check passed: reference = [$RUN_REFERENCE_DATE], reason = [$TIME_TRUST_DETAIL]"
    else
        log_error "Retention cleanup is disabled because time is untrusted: reference = [$RUN_REFERENCE_DATE], reason = [$TIME_TRUST_DETAIL]"
    fi
}

persist_trusted_time() {
    if $DRY_RUN || ! $TIME_TRUSTED; then
        return 0
    fi

    write_line_atomically "$LAST_TRUSTED_TIME_FILE" "$RUN_REFERENCE_EPOCH" ||
        fail_now "failed to persist trusted time"
}

require_commands() {
    local command_name

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            fail_now "required command is missing: $command_name"
        fi
    done
}

get_exact_mount_info() {
    local target_root=$1
    local resolved_target
    local mount_target

    MOUNT_INFO_ERROR_DETAIL="not_checked"
    if ! resolved_target=$(realpath -m "$target_root"); then
        MOUNT_INFO_ERROR_DETAIL="failed to resolve configured target path"
        return 1
    fi
    if ! mount_target=$(findmnt -rn --mountpoint "$resolved_target" -o TARGET 2>/dev/null) ||
       [[ -z "$mount_target" ]]; then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [TARGET] is unavailable"
        return 1
    fi
    if ! mount_target=$(realpath -m "$mount_target"); then
        MOUNT_INFO_ERROR_DETAIL="failed to resolve findmnt field [TARGET]"
        return 1
    fi

    if [[ "$mount_target" != "$resolved_target" ]]; then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [TARGET] mismatch: expected = [$resolved_target], actual = [$mount_target]"
        return 1
    fi

    MOUNT_INFO_TARGET="$mount_target"
    if ! MOUNT_INFO_SOURCE=$(findmnt -rn --mountpoint "$resolved_target" -o SOURCE 2>/dev/null); then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [SOURCE] query failed"
        return 1
    fi
    if ! MOUNT_INFO_FSTYPE=$(findmnt -rn --mountpoint "$resolved_target" -o FSTYPE 2>/dev/null); then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [FSTYPE] query failed"
        return 1
    fi
    if ! MOUNT_INFO_OPTIONS=$(findmnt -rn --mountpoint "$resolved_target" -o OPTIONS 2>/dev/null); then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [OPTIONS] query failed"
        return 1
    fi
    if ! MOUNT_INFO_MAJMIN=$(findmnt -rn --mountpoint "$resolved_target" -o MAJ:MIN 2>/dev/null); then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [MAJ:MIN] query failed"
        return 1
    fi
    if ! MOUNT_INFO_UUID=$(findmnt -rn --mountpoint "$resolved_target" -o UUID 2>/dev/null); then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [UUID] query failed"
        return 1
    fi
    if ! MOUNT_INFO_LABEL=$(findmnt -rn --mountpoint "$resolved_target" -o LABEL 2>/dev/null); then
        MOUNT_INFO_ERROR_DETAIL="findmnt field [LABEL] query failed"
        return 1
    fi
    MOUNT_INFO_ERROR_DETAIL="ok"
}

get_device_uuid() {
    local device_path=$1
    blkid -p -s UUID -o value "$device_path" 2>/dev/null
}

get_device_label() {
    local device_path=$1
    blkid -p -s LABEL -o value "$device_path" 2>/dev/null
}

validate_removable_identity_configuration() {
    local expected_uuid=${REMOVABLE_DEVICE_UUID:-}
    local expected_label=${REMOVABLE_DEVICE_LABEL:-}

    if [[ -n "${REMOVABLE_DEVICE_PATH:-}" ]]; then
        log_error "REMOVABLE_DEVICE_PATH is not supported; configure REMOVABLE_DEVICE_UUID or REMOVABLE_DEVICE_LABEL"
        return 1
    fi
    if [[ -z "$expected_uuid" && -z "$expected_label" ]]; then
        log_error "REMOVABLE_DEVICE_UUID or REMOVABLE_DEVICE_LABEL must identify the expected USB filesystem"
        return 1
    fi
    if [[ -n "$expected_uuid" && ! "$expected_uuid" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
        log_error "REMOVABLE_DEVICE_UUID contains unsupported characters"
        return 1
    fi
    if [[ -n "$expected_label" &&
          ( "$expected_label" == *"/"* || "$expected_label" == *$'\n'* || "$expected_label" == *$'\r'* ) ]]; then
        log_error "REMOVABLE_DEVICE_LABEL contains unsupported path or newline characters"
        return 1
    fi

    if [[ -n "$expected_uuid" && -n "$expected_label" ]]; then
        REMOVABLE_IDENTITY_DESCRIPTION="UUID=$expected_uuid,LABEL=$expected_label"
    elif [[ -n "$expected_uuid" ]]; then
        REMOVABLE_IDENTITY_DESCRIPTION="UUID=$expected_uuid"
    else
        REMOVABLE_IDENTITY_DESCRIPTION="LABEL=$expected_label"
    fi
}

resolve_expected_removable_device() {
    local expected_uuid=${REMOVABLE_DEVICE_UUID:-}
    local expected_label=${REMOVABLE_DEVICE_LABEL:-}
    local uuid_spec=""
    local uuid_device=""
    local label_device=""
    local actual_uuid=""
    local actual_label=""

    REMOVABLE_EXPECTED_SPEC=""
    REMOVABLE_EXPECTED_DEVICE=""

    if [[ -n "$expected_uuid" ]]; then
        uuid_spec="/dev/disk/by-uuid/$expected_uuid"
        [[ -b "$uuid_spec" ]] || return 1
        uuid_device=$(readlink -f "$uuid_spec") || return 1
        [[ -b "$uuid_device" ]] || return 1
        actual_uuid=$(get_device_uuid "$uuid_device") || return 1
        [[ "$actual_uuid" == "$expected_uuid" ]] || return 1
        REMOVABLE_EXPECTED_SPEC="$uuid_spec"
        REMOVABLE_EXPECTED_DEVICE="$uuid_device"
    fi

    if [[ -n "$expected_label" ]]; then
        label_device=$(blkid -L "$expected_label" 2>/dev/null) || return 1
        label_device=$(readlink -f "$label_device") || return 1
        [[ -b "$label_device" ]] || return 1
        actual_label=$(get_device_label "$label_device") || return 1
        [[ "$actual_label" == "$expected_label" ]] || return 1

        if [[ -n "$REMOVABLE_EXPECTED_DEVICE" &&
              "$label_device" != "$REMOVABLE_EXPECTED_DEVICE" ]]; then
            return 1
        fi
        if [[ -z "$REMOVABLE_EXPECTED_DEVICE" ]]; then
            REMOVABLE_EXPECTED_SPEC="LABEL=$expected_label"
            REMOVABLE_EXPECTED_DEVICE="$label_device"
        fi
    fi

    [[ -n "$REMOVABLE_EXPECTED_SPEC" && -b "$REMOVABLE_EXPECTED_DEVICE" ]]
}

wait_for_expected_removable_device() {
    local wait_seconds=${REMOVABLE_DEVICE_WAIT_SECONDS:-30}
    local attempt

    if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]] || (( wait_seconds > 300 )); then
        log_error "REMOVABLE_DEVICE_WAIT_SECONDS must be an integer between 0 and 300"
        return 1
    fi

    log_info "Waiting up to ${wait_seconds}s for removable device: [$REMOVABLE_IDENTITY_DESCRIPTION]"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=1 >/dev/null 2>&1 || true
    fi

    for (( attempt = 0; attempt <= wait_seconds; ++attempt )); do
        check_interruption_requested
        if resolve_expected_removable_device; then
    log_info "Detected removable device: spec = [$REMOVABLE_EXPECTED_SPEC], resolved = [$REMOVABLE_EXPECTED_DEVICE]"
            return 0
        fi

        if (( attempt == wait_seconds )); then
            break
        fi
        sleep 1
        check_interruption_requested
    done

    log_error "Removable device was not visible before timeout: [$REMOVABLE_IDENTITY_DESCRIPTION]"
    return 1
}

verify_removable_mount_identity() {
    local target_root=$1
    local require_writable=${2:-true}
    local expected_uuid=${REMOVABLE_DEVICE_UUID:-}
    local expected_label=${REMOVABLE_DEVICE_LABEL:-}
    local expected_fstype=${REMOVABLE_FS_TYPE:-}
    local actual_uuid=""
    local actual_label=""
    local actual_device_resolved=""
    local required_option
    local -a required_mount_options=()

    if ! resolve_expected_removable_device; then
        log_error "Expected removable device is no longer visible: [$REMOVABLE_IDENTITY_DESCRIPTION]"
        return 1
    fi
    if ! get_exact_mount_info "$target_root"; then
        log_error "Failed to read exact removable mount information: target = [$target_root], detail = [$MOUNT_INFO_ERROR_DETAIL]"
        return 1
    fi

    if [[ "$require_writable" == "true" ]] &&
       { [[ ",$MOUNT_INFO_OPTIONS," == *,ro,* ]] ||
         [[ ",$MOUNT_INFO_OPTIONS," != *,rw,* ]]; }; then
        log_error "Removable target is read-only; migration is stopped without remount or fsck: target = [$target_root], options = [$MOUNT_INFO_OPTIONS]"
        return 1
    fi

    if [[ -n "$expected_fstype" && "$MOUNT_INFO_FSTYPE" != "$expected_fstype" ]]; then
        log_error "Unexpected removable filesystem: expected = [$expected_fstype], actual = [$MOUNT_INFO_FSTYPE]"
        return 1
    fi

    IFS=',' read -r -a required_mount_options <<< "${REMOVABLE_MOUNT_OPTIONS:-}"
    for required_option in "${required_mount_options[@]}"; do
        [[ -n "$required_option" ]] || continue
        if [[ ",$MOUNT_INFO_OPTIONS," != *",$required_option,"* ]]; then
            log_error "Removable mount is missing a configured option: required = [$required_option], actual = [$MOUNT_INFO_OPTIONS]"
            return 1
        fi
    done

    if ! actual_device_resolved=$(readlink -f "$MOUNT_INFO_SOURCE" 2>/dev/null); then
        log_error "Failed to resolve removable mount source: source = [$MOUNT_INFO_SOURCE]"
        return 1
    fi
    if [[ "$actual_device_resolved" != "$REMOVABLE_EXPECTED_DEVICE" ]]; then
        log_error "Unexpected removable source: expected = [$REMOVABLE_EXPECTED_DEVICE], actual = [$actual_device_resolved]"
        return 1
    fi

    actual_uuid=$MOUNT_INFO_UUID
    [[ -n "$actual_uuid" ]] || actual_uuid=$(get_device_uuid "$actual_device_resolved")
    if [[ -n "$expected_uuid" && "$actual_uuid" != "$expected_uuid" ]]; then
        log_error "Unexpected removable UUID: expected = [$expected_uuid], actual = [$actual_uuid]"
        return 1
    fi

    actual_label=$MOUNT_INFO_LABEL
    [[ -n "$actual_label" ]] || actual_label=$(get_device_label "$actual_device_resolved")
    if [[ -n "$expected_label" && "$actual_label" != "$expected_label" ]]; then
        log_error "Unexpected removable LABEL: expected = [$expected_label], actual = [$actual_label]"
        return 1
    fi

    if [[ -n "$REMOVABLE_ACTIVE_MAJMIN" && "$MOUNT_INFO_MAJMIN" != "$REMOVABLE_ACTIVE_MAJMIN" ]]; then
        log_error "Removable device identity changed during the run: expected = [$REMOVABLE_ACTIVE_MAJMIN], actual = [$MOUNT_INFO_MAJMIN]"
        return 1
    fi

    REMOVABLE_ACTIVE_TARGET="$MOUNT_INFO_TARGET"
    REMOVABLE_ACTIVE_SOURCE="$MOUNT_INFO_SOURCE"
    REMOVABLE_ACTIVE_UUID="$actual_uuid"
    REMOVABLE_ACTIVE_LABEL="$actual_label"
    REMOVABLE_ACTIVE_MAJMIN="$MOUNT_INFO_MAJMIN"
    log_debug "Removable mount verified: target = [$MOUNT_INFO_TARGET], source = [$MOUNT_INFO_SOURCE], uuid = [$actual_uuid], label = [$actual_label], fstype = [$MOUNT_INFO_FSTYPE], options = [$MOUNT_INFO_OPTIONS]"
}

get_mount_targets_for_device() {
    local device_path=$1

    MOUNT_TARGETS_RESULT=$(findmnt -rn --source "$device_path" -o TARGET 2>/dev/null || true)
}

probe_target_write_and_sync() {
    local target_root=$1
    local probe_file
    local committed_probe

    probe_file=$(mktemp "$target_root/.auto_transfer_probe.XXXXXX") || return 1
    committed_probe="${probe_file}.committed"

    if ! printf 'auto_transfer_probe:%s\n' "$RUN_ID" > "$probe_file"; then
        rm -f -- "$probe_file"
        return 1
    fi

    if ! sync "$probe_file"; then
        rm -f -- "$probe_file"
        return 1
    fi

    if ! mv -- "$probe_file" "$committed_probe"; then
        rm -f -- "$probe_file"
        return 1
    fi

    if ! sync "$committed_probe"; then
        rm -f -- "$committed_probe"
        return 1
    fi

    if ! rm -f -- "$committed_probe"; then
        return 1
    fi

    sync -f "$target_root"
}

check_target_ready() {
    local target_class=$1
    local target_root=$2

    if [[ -n "${TARGET_READY_INDEX[$target_class:$target_root]+x}" ]]; then
        if $DRY_RUN; then
            return 0
        fi
        if [[ "$target_class" != "removable" ]] ||
           verify_removable_mount_identity "$target_root"; then
            return 0
        fi
        fail_now "previously validated removable target changed during this run: [$target_root]"
    fi

    if [[ "$target_class" == "removable" ]]; then
        verify_removable_mount_identity "$target_root" ||
            fail_now "removable target is not the expected writable mount: [$target_root]"
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would prepare target root: [$target_root]"
        TARGET_READY_INDEX["$target_class:$target_root"]=1
        return 0
    fi

    if [[ "$target_class" != "removable" ]]; then
        if ! mkdir -p "$target_root" 2>> "$LOG_FILE"; then
            fail_now "failed to create target root: [$target_root]"
        fi
    fi

    if ! probe_target_write_and_sync "$target_root"; then
        fail_now "target root failed write/rename/sync probe: [$target_root]"
    fi
    TARGET_READY_INDEX["$target_class:$target_root"]=1
}

# 查询目标文件系统可用字节数. 
# 使用 df -PB1 强制按字节输出, 避免不同系统块大小导致估算不一致. 
get_available_bytes() {
    local target_path=$1
    df -PB1 "$target_path" 2>/dev/null | awk 'NR==2 {print $4}'
}

# 默认的目录同步筛选钩子. 
# 如果入口脚本没有覆盖该函数, 则认为所有目录都允许同步到目标侧. 
if ! declare -F should_sync_directory_for_source >/dev/null 2>&1; then
    should_sync_directory_for_source() {
        return 0
    }
fi

# 默认的文件迁移筛选钩子. 
# 如果入口脚本没有覆盖该函数, 则认为源目录下的所有文件都需要迁移. 
if ! declare -F should_transfer_file_for_source >/dev/null 2>&1; then
    should_transfer_file_for_source() {
        return 0
    }
fi

if ! declare -F should_prune_stale_directory_for_source >/dev/null 2>&1; then
    should_prune_stale_directory_for_source() {
        return 1
    }
fi

if ! declare -F should_delete_directory_tree_for_source >/dev/null 2>&1; then
    should_delete_directory_tree_for_source() {
        return 1
    }
fi

if ! declare -F enumerate_visual_cleanup_directories_for_source >/dev/null 2>&1; then
    enumerate_visual_cleanup_directories_for_source() {
        local source_dir=$1
        find "$source_dir" -depth -type d -print0 2>/dev/null
    }
fi

if ! declare -F cleanup_old_directories_for_target >/dev/null 2>&1; then
    cleanup_old_directories_for_target() {
        return 0
    }
fi

if ! declare -F enumerate_old_files_for_target >/dev/null 2>&1; then
    enumerate_old_files_for_target() {
        local target_dir=$1
        find "$target_dir" -type f -print0
    }
fi

get_reserved_bytes_for_class() {
    local target_class=$1
    local reserved_gb=${TARGET_RESERVED_GB[$target_class]:-0}
    echo $((reserved_gb * 1024 * 1024 * 1024))
}

get_file_size_bytes() {
    local file_path=$1
    stat -c %s "$file_path" 2>/dev/null
}

get_file_mtime_epoch() {
    local file_path=$1
    stat -c %Y "$file_path" 2>/dev/null
}

# IPC keeps source data after backup, so repeatedly hashing every historical
# source/target pair dominates subsequent runs.  This fingerprint is only a
# fast-path guard for a pair that has already passed SHA-256 verification.  It
# includes inode identity plus nanosecond mtime/ctime; any ordinary rewrite,
# replacement, chmod/chown or target recreation invalidates the cache and
# falls back to the original content hash comparison.
calculate_file_fingerprint_to_result() {
    local file_path=$1

    FILE_FINGERPRINT_RESULT=""
    if [[ ! -f "$file_path" || -L "$file_path" ]]; then
        return 1
    fi
    FILE_FINGERPRINT_RESULT=$(stat -Lc '%d:%i:%s:%y:%z' -- "$file_path" 2>/dev/null) || return 1
    [[ -n "$FILE_FINGERPRINT_RESULT" ]]
}

is_expected_ipc_source_target_pair() {
    local source_file=$1
    local target_file=$2
    local configured_source
    local relative_path
    local configured_class
    local expected_target

    for configured_source in "${SOURCE_DIR_ORDER[@]}"; do
        [[ "$source_file" == "$configured_source"* ]] || continue
        relative_path=${source_file#"$configured_source"}
        relative_path=${relative_path#/}
        [[ -n "$relative_path" ]] || return 1
        configured_class=${SOURCE_TARGET_CLASSES[$configured_source]:-$DEFAULT_TARGET_CLASS}
        [[ "$configured_class" == "ipc" ]] || return 1
        expected_target="${TARGET_ROOTS[ipc]}/${SOURCE_RELATIVE_TARGETS[$configured_source]}/$relative_path"
        [[ "$target_file" == "$expected_target" ]]
        return
    done
    return 1
}

clear_ipc_verified_index_memory() {
    IPC_VERIFIED_SOURCE_FINGERPRINTS=()
    IPC_VERIFIED_TARGET_PATHS=()
    IPC_VERIFIED_TARGET_FINGERPRINTS=()
    IPC_VERIFIED_SHA256=()
    IPC_VERIFIED_THIS_RUN=()
}

load_ipc_verified_index() {
    local header=""
    local source_file
    local target_file
    local source_fingerprint
    local target_fingerprint
    local verified_sha256
    local index_fd
    local invalid=false
    local loaded_count=0

    $IPC_VERIFIED_INDEX_LOADED && return 0
    IPC_VERIFIED_INDEX_LOADED=true
    clear_ipc_verified_index_memory

    [[ -f "$IPC_VERIFIED_INDEX_FILE" && ! -L "$IPC_VERIFIED_INDEX_FILE" ]] || return 0
    exec {index_fd}< "$IPC_VERIFIED_INDEX_FILE" || {
        log_warn "Cannot read IPC verified index; falling back to SHA-256 verification: [$IPC_VERIFIED_INDEX_FILE]"
        return 0
    }
    if ! IFS= read -r -d '' header <&$index_fd ||
       [[ "$header" != "auto_transfer_ipc_verified_index_v1" ]]; then
        invalid=true
    fi

    while ! $invalid && IFS= read -r -d '' source_file <&$index_fd; do
        if ! IFS= read -r -d '' target_file <&$index_fd ||
           ! IFS= read -r -d '' source_fingerprint <&$index_fd ||
           ! IFS= read -r -d '' target_fingerprint <&$index_fd ||
           ! IFS= read -r -d '' verified_sha256 <&$index_fd; then
            invalid=true
            break
        fi
        if [[ -z "$source_file" || -z "$target_file" ||
              -z "$source_fingerprint" || -z "$target_fingerprint" ]] ||
           ! is_expected_ipc_source_target_pair "$source_file" "$target_file"; then
            invalid=true
            break
        fi
        IPC_VERIFIED_SOURCE_FINGERPRINTS["$source_file"]=$source_fingerprint
        IPC_VERIFIED_TARGET_PATHS["$source_file"]=$target_file
        IPC_VERIFIED_TARGET_FINGERPRINTS["$source_file"]=$target_fingerprint
        IPC_VERIFIED_SHA256["$source_file"]=$verified_sha256
        loaded_count=$((loaded_count + 1))
    done
    exec {index_fd}<&-

    if $invalid; then
        clear_ipc_verified_index_memory
        log_warn "IPC verified index is invalid; ignoring it and using full SHA-256 verification."
        return 0
    fi
    log_info "Loaded IPC verified index: records = [$loaded_count]"
}

remove_ipc_verified_file() {
    local source_file=$1

    load_ipc_verified_index
    if [[ -n "${IPC_VERIFIED_SOURCE_FINGERPRINTS[$source_file]+x}" ]]; then
        unset 'IPC_VERIFIED_SOURCE_FINGERPRINTS[$source_file]'
        unset 'IPC_VERIFIED_TARGET_PATHS[$source_file]'
        unset 'IPC_VERIFIED_TARGET_FINGERPRINTS[$source_file]'
        unset 'IPC_VERIFIED_SHA256[$source_file]'
        unset 'IPC_VERIFIED_THIS_RUN[$source_file]'
        IPC_VERIFIED_INDEX_DIRTY=true
    fi
}

stage_ipc_verified_file() {
    local source_file=$1
    local target_file=$2
    local verified_sha256=${3:-}
    local source_fingerprint
    local target_fingerprint

    $DRY_RUN && return 0
    is_expected_ipc_source_target_pair "$source_file" "$target_file" || return 0
    load_ipc_verified_index
    calculate_file_fingerprint_to_result "$source_file" || return 0
    source_fingerprint=$FILE_FINGERPRINT_RESULT
    calculate_file_fingerprint_to_result "$target_file" || return 0
    target_fingerprint=$FILE_FINGERPRINT_RESULT

    IPC_VERIFIED_SOURCE_FINGERPRINTS["$source_file"]=$source_fingerprint
    IPC_VERIFIED_TARGET_PATHS["$source_file"]=$target_file
    IPC_VERIFIED_TARGET_FINGERPRINTS["$source_file"]=$target_fingerprint
    if [[ -n "$verified_sha256" ]]; then
        IPC_VERIFIED_SHA256["$source_file"]=$verified_sha256
    elif [[ -z "${IPC_VERIFIED_SHA256[$source_file]+x}" ]]; then
        IPC_VERIFIED_SHA256["$source_file"]=""
    fi
    IPC_VERIFIED_THIS_RUN["$source_file"]=1
    IPC_VERIFIED_INDEX_DIRTY=true
}


ipc_history_child_identity() {
    local record rest capture=${1:-false}
    local -a fields=()
    [[ -n "$IPC_HISTORY_WORKER_PID" && "$BASHPID" == "$IPC_HISTORY_OWNER_PID" ]] || return 1
    IFS= read -r record 2>/dev/null < "/proc/$IPC_HISTORY_WORKER_PID/stat" || return 1
    rest=${record##*) }
    read -r -a fields <<< "$rest"
    [[ "${fields[1]:-}" == "$IPC_HISTORY_OWNER_PID" &&
       "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    IPC_HISTORY_CHILD_STATE=${fields[0]}
    if [[ -z "$IPC_HISTORY_STARTTIME" ]]; then
        [[ "$capture" == capture ]] || return 1
        IPC_HISTORY_STARTTIME=${fields[19]}
    fi
    [[ "${fields[19]}" == "$IPC_HISTORY_STARTTIME" ]]
}

stop_ipc_history_reader() {
    local attempt
    [[ -z "$IPC_HISTORY_OWNER_PID" || "$BASHPID" == "$IPC_HISTORY_OWNER_PID" ]] || return 0
    IPC_HISTORY_ACTIVE=false
    if [[ -n "$IPC_HISTORY_ORIGINAL_WRITE_FD" ]]; then
        exec {IPC_HISTORY_ORIGINAL_WRITE_FD}>&- || true
        IPC_HISTORY_ORIGINAL_WRITE_FD=""
    fi
    if [[ -n "$IPC_HISTORY_ORIGINAL_READ_FD" ]]; then
        exec {IPC_HISTORY_ORIGINAL_READ_FD}<&- || true
        IPC_HISTORY_ORIGINAL_READ_FD=""
    fi
    if [[ -n "$IPC_HISTORY_WRITE_FD" ]]; then
        exec {IPC_HISTORY_WRITE_FD}>&- || true
        IPC_HISTORY_WRITE_FD=""
    fi
    if [[ -n "$IPC_HISTORY_READ_FD" ]]; then
        exec {IPC_HISTORY_READ_FD}<&- || true
        IPC_HISTORY_READ_FD=""
    fi
    [[ -n "$IPC_HISTORY_WORKER_PID" ]] || return 0
    if ipc_history_child_identity && [[ "$IPC_HISTORY_CHILD_STATE" != Z ]]; then
        kill -TERM "$IPC_HISTORY_WORKER_PID" 2>/dev/null || true
        for ((attempt=0; attempt<20; attempt++)); do
            if ! ipc_history_child_identity || [[ "$IPC_HISTORY_CHILD_STATE" == Z ]]; then break; fi
            sleep 0.01
        done
        if ipc_history_child_identity && [[ "$IPC_HISTORY_CHILD_STATE" != Z ]]; then
            kill -KILL "$IPC_HISTORY_WORKER_PID" 2>/dev/null || true
            for ((attempt=0; attempt<10; attempt++)); do
                if ! ipc_history_child_identity || [[ "$IPC_HISTORY_CHILD_STATE" == Z ]]; then break; fi
                sleep 0.01
            done
        fi
    fi
    if ipc_history_child_identity && [[ "$IPC_HISTORY_CHILD_STATE" != Z ]]; then
        log_warn "IPC metadata reader has not exited yet; no unbounded wait, original checks remain available." || true
        return 1
    fi
    # Do not wait on a different live child if a numeric PID has been reused.
    if ipc_history_child_identity || [[ ! -e "/proc/$IPC_HISTORY_WORKER_PID" ]]; then
        wait "$IPC_HISTORY_WORKER_PID" 2>/dev/null || true
    fi
    IPC_HISTORY_WORKER_PID=""
    IPC_HISTORY_STARTTIME=""
    return 0
}

disable_ipc_history_reader() {
    local reason=$1
    stop_ipc_history_reader || true
    if ! $IPC_HISTORY_DISABLED; then
        log_warn "IPC history reader disabled: reason = [$reason]; using original per-file stat." || true
    fi
    IPC_HISTORY_DISABLED=true
    IPC_COPY_READER_BACKEND=stat_fallback
}

ipc_history_read_field() {
    local destination=$1 limit=$2 field=""
    local LC_ALL=C
    [[ -n "$IPC_HISTORY_READ_FD" ]] || return 1
    if ! IFS= read -r -d '' -n "$limit" -t "$IPC_HISTORY_TIMEOUT" field \
        2>/dev/null <&"$IPC_HISTORY_READ_FD"; then
        return 1
    fi
    (( ${#field} < limit )) || return 1
    printf -v "$destination" '%s' "$field"
}

start_ipc_history_reader() {
    local mode=${1:-fingerprint} expected_version=ipc-history-v1
    local -a mode_args=()
    case "$mode" in
        fingerprint) ;;
        mtime) expected_version=ipc-mtime-v1; mode_args=(mtime) ;;
        *) return 1 ;;
    esac
    local helper=${IPC_HISTORY_READER_HELPER:-$SCRIPT_DIR/auto_transfer_ipc_metadata.py}
    local ready="" version="" ready_pid="" pipe_trap="" coproc_read="" coproc_write=""
    if $IPC_HISTORY_ACTIVE; then
        [[ "$IPC_HISTORY_MODE" == "$mode" ]]
        return
    fi
    $IPC_HISTORY_DISABLED && return 1
    [[ "${IPC_HISTORY_READER_ENABLED:-true}" == true ]] || return 1
    IPC_HISTORY_TIMEOUT=${IPC_HISTORY_READER_TIMEOUT_SECONDS:-5}
    if [[ ! "$IPC_HISTORY_TIMEOUT" =~ ^([1-9]|[12][0-9]|30)$ ]]; then
        disable_ipc_history_reader invalid_timeout; return 1
    fi
    if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$helper" || -L "$helper" || ! -r "$helper" ]]; then
        disable_ipc_history_reader python_or_helper_unavailable; return 1
    fi
    pipe_trap=$(trap -p PIPE)
    if [[ -n "$pipe_trap" ]]; then
        disable_ipc_history_reader existing_sigpipe_handler; return 1
    fi
    check_interruption_requested
    IPC_HISTORY_OWNER_PID=$BASHPID
    IPC_HISTORY_MODE=$mode
    IPC_HISTORY_TZ_SET=${TZ+x}
    IPC_HISTORY_TZ=${TZ-}
    IPC_HISTORY_STARTTIME=""
    coproc IPC_HISTORY_READER {
        # Release known backup locks before even loading the interpreter.
        exec 9>&-
        if [[ -n "$IPC_PREFLIGHT_METADATA_GUARD_FD" ]]; then
            exec {IPC_PREFLIGHT_METADATA_GUARD_FD}>&-
        fi
        exec python3 -I -u "$helper" "$IPC_HISTORY_OWNER_PID" "${mode_args[@]}"
    } 2>> "$LOG_FILE"
    IPC_HISTORY_WORKER_PID=${IPC_HISTORY_READER_PID:-}
    coproc_read=${IPC_HISTORY_READER[0]:-}
    coproc_write=${IPC_HISTORY_READER[1]:-}
    IPC_HISTORY_ORIGINAL_READ_FD=$coproc_read
    IPC_HISTORY_ORIGINAL_WRITE_FD=$coproc_write
    if [[ -z "$coproc_read" || -z "$coproc_write" ]] || ! ipc_history_child_identity capture; then
        disable_ipc_history_reader startup_failed; return 1
    fi
    if ! exec {IPC_HISTORY_READ_FD}<&"$coproc_read" ||
       ! exec {IPC_HISTORY_WRITE_FD}>&"$coproc_write"; then
        disable_ipc_history_reader pipe_setup_failed; return 1
    fi
    exec {coproc_read}<&-
    exec {coproc_write}>&-
    IPC_HISTORY_ORIGINAL_READ_FD=""
    IPC_HISTORY_ORIGINAL_WRITE_FD=""
    if ! ipc_history_read_field ready 16 ||
       ! ipc_history_read_field version 32 ||
       ! ipc_history_read_field ready_pid 32 ||
       [[ "$ready" != READY || "$version" != "$expected_version" || "$ready_pid" != "$IPC_HISTORY_WORKER_PID" ]]; then
        check_interruption_requested
        disable_ipc_history_reader handshake_failed; return 1
    fi
    IPC_HISTORY_ACTIVE=true
    log_info "IPC history reader started: pid = [$IPC_HISTORY_WORKER_PID], mode = [$mode], fresh per-request metadata, timeout_s = [$IPC_HISTORY_TIMEOUT]" || true
    return 0
}

query_ipc_metadata() {
    local mode=${2:-fingerprint}
    IPC_HISTORY_VALUE_RESULT=""
    [[ "$mode" == "$IPC_HISTORY_MODE" ]] || return 2
    local pathname=$1 response_id="" response_status="" response_fp="" write_ok=false
    local LC_ALL=C
    [[ "${TZ+x}" == "$IPC_HISTORY_TZ_SET" && "${TZ-}" == "$IPC_HISTORY_TZ" ]] || return 2
    # Keep one outstanding request below Linux PIPE_BUF, even if the worker
    # stops reading. Longer paths use the original stat implementation.
    (( ${#pathname} <= 4000 )) || return 2
    IPC_HISTORY_SEQUENCE=$((IPC_HISTORY_SEQUENCE + 1))
    # Ignore SIGPIPE only during this builtin write. No child is launched in
    # this window, and start refused pre-existing PIPE traps. Always restore.
    trap '' PIPE
    if printf '%s\0%s\0' "$IPC_HISTORY_SEQUENCE" "$pathname" \
        2>/dev/null >&"$IPC_HISTORY_WRITE_FD"; then write_ok=true; fi
    trap - PIPE
    check_interruption_requested
    $write_ok || return 2
    if ! ipc_history_read_field response_id 32 ||
       ! ipc_history_read_field response_status 16 ||
       ! ipc_history_read_field response_fp 512; then
        check_interruption_requested
        return 2
    fi
    check_interruption_requested
    [[ "$response_id" == "$IPC_HISTORY_SEQUENCE" ]] || return 2
    if [[ "$response_status" == MISS && -z "$response_fp" ]]; then
        IPC_HISTORY_VALUE_RESULT=""
        IPC_HISTORY_REQUESTS=$((IPC_HISTORY_REQUESTS + 1))
        return 1
    fi
    [[ "$response_status" == OK ]] || return 2
    if [[ "$mode" == mtime ]]; then
        # Canonical decimal time_t only: reject octal, arithmetic expressions
        # and values which would wrap Bash's signed integer comparison.
        [[ "$response_fp" =~ ^(-[1-9][0-9]{0,18}|0|[1-9][0-9]{0,18})$ ]] || return 2
        local magnitude=${response_fp#-} maximum=9223372036854775807
        [[ "$response_fp" != -* ]] || maximum=9223372036854775808
        if (( ${#magnitude} == 19 )) && [[ "$magnitude" > "$maximum" ]]; then return 2; fi
        IPC_HISTORY_VALUE_RESULT=$response_fp
        IPC_HISTORY_REQUESTS=$((IPC_HISTORY_REQUESTS + 1))
        return 0
    fi
    [[ "$response_fp" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{9}\ [+-][0-9]{4}:[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{9}\ [+-][0-9]{4}$ ]] || return 2
    IPC_HISTORY_VALUE_RESULT=$response_fp
    IPC_HISTORY_REQUESTS=$((IPC_HISTORY_REQUESTS + 1))
    return 0
}

calculate_history_fingerprint_to_result() {
    local result
    if [[ "${IPC_HISTORY_READER_SCOPE:-false}" == true ]] && $IPC_HISTORY_ACTIVE; then
        if query_ipc_metadata "$1" fingerprint; then
            FILE_FINGERPRINT_RESULT=$IPC_HISTORY_VALUE_RESULT
            return 0
        else result=$?; fi
        if (( result == 1 )); then FILE_FINGERPRINT_RESULT=""; return 1; fi
        disable_ipc_history_reader request_failed
    fi
    check_interruption_requested
    calculate_file_fingerprint_to_result "$1"
}

log_ipc_copy_progress() {
    local force=${1:-false} elapsed
    [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]] || return 0
    if [[ "$force" != true ]] && (( SECONDS - IPC_COPY_LAST_LOG < IPC_COPY_INTERVAL )); then return 0; fi
    IPC_COPY_LAST_LOG=$SECONDS
    elapsed=$((SECONDS - IPC_COPY_STARTED))
    log_info "IPC copy progress: stage = [$IPC_COPY_STAGE], source = [$source_dir], scanned = [$IPC_COPY_SCANNED/${IPC_COPY_TOTAL:-unknown}], unchanged = [${fast_skipped_count:-0}], copied = [$IPC_COPY_COPIED], matched = [$IPC_COPY_MATCHED], conflicts = [$((CONFLICT_TOTAL - IPC_COPY_CONFLICT_START))], dirs_checked = [$IPC_COPY_DIRS], dirs_created = [$IPC_COPY_DIRS_CREATED], reader = [$IPC_COPY_READER_BACKEND], reader_requests = [$((IPC_HISTORY_REQUESTS - IPC_COPY_REQUEST_START))], elapsed_s = [$elapsed], current = [$IPC_COPY_CURRENT]" || true
}
ipc_verified_index_matches() {
    local source_file=$1
    local target_file=$2
    local source_fingerprint
    local target_fingerprint

    [[ "$IPC_FORCE_FULL_AUDIT" != "true" ||
       -n "${IPC_VERIFIED_THIS_RUN[$source_file]+x}" ]] || return 1
    load_ipc_verified_index
    [[ "${IPC_VERIFIED_TARGET_PATHS[$source_file]:-}" == "$target_file" ]] || return 1

    calculate_history_fingerprint_to_result "$source_file" || return 1
    source_fingerprint=$FILE_FINGERPRINT_RESULT
    [[ "${IPC_VERIFIED_SOURCE_FINGERPRINTS[$source_file]:-}" == "$source_fingerprint" ]] || return 1
    calculate_history_fingerprint_to_result "$target_file" || return 1
    target_fingerprint=$FILE_FINGERPRINT_RESULT
    [[ "${IPC_VERIFIED_TARGET_FINGERPRINTS[$source_file]:-}" == "$target_fingerprint" ]] || return 1
    return 0
}

cleanup_ipc_index_temp_file() {
    [[ -n "$IPC_INDEX_TEMP_FILE" ]] || return 0
    [[ "$BASHPID" == "$IPC_INDEX_TEMP_OWNER" ]] || return 0
    rm -f -- "$IPC_INDEX_TEMP_FILE" || return 1
    IPC_INDEX_TEMP_FILE=""
}

commit_ipc_verified_index() {
    local index_parent temp_index source_file
    local write_status=0 record_count=0 started=$SECONDS

    $DRY_RUN && return 0
    $IPC_VERIFIED_INDEX_DIRTY || return 0
    # Do not overwrite tracking if a previous failed attempt could not clean up.
    cleanup_ipc_index_temp_file || return 1
    [[ -z "$IPC_INDEX_TEMP_FILE" ]] || return 1
    index_parent=${IPC_VERIFIED_INDEX_FILE%/*}
    mkdir -p "$index_parent" || return 1
    temp_index=$(mktemp "$index_parent/.ipc_verified_index.XXXXXX") || return 1
    IPC_INDEX_TEMP_FILE=$temp_index
    IPC_INDEX_TEMP_OWNER=$BASHPID
    log_info "IPC index persist starting: file = [$IPC_VERIFIED_INDEX_FILE]" || true
    # Only index bytes belong in this group. Explicitly check every printf:
    # callers use this function in an if, which disables Bash errexit here.
    {
        if ! printf '%s\0' "auto_transfer_ipc_verified_index_v1"; then
            write_status=1
        else
            for source_file in "${!IPC_VERIFIED_SOURCE_FINGERPRINTS[@]}"; do
                [[ "$INTERRUPT_REQUESTED" != true ]] || check_interruption_requested
                if ! printf '%s\0%s\0%s\0%s\0%s\0' \
                    "$source_file" \
                    "${IPC_VERIFIED_TARGET_PATHS[$source_file]}" \
                    "${IPC_VERIFIED_SOURCE_FINGERPRINTS[$source_file]}" \
                    "${IPC_VERIFIED_TARGET_FINGERPRINTS[$source_file]}" \
                    "${IPC_VERIFIED_SHA256[$source_file]:-}"; then
                    write_status=1
                    break
                fi
                ((record_count += 1))
            done
        fi
    } > "$temp_index" || write_status=1
    if (( write_status != 0 )); then
        cleanup_ipc_index_temp_file || true
        return 1
    fi
    if ! sync "$temp_index"; then
        cleanup_ipc_index_temp_file || true
        return 1
    fi
    check_interruption_requested
    if ! mv -f -- "$temp_index" "$IPC_VERIFIED_INDEX_FILE"; then
        cleanup_ipc_index_temp_file || true
        return 1
    fi
    IPC_INDEX_TEMP_FILE=""
    # A failure here is after rename: keep DIRTY and report failure, since the
    # new complete index is visible but filesystem durability is unconfirmed.
    sync -f "$index_parent" || return 1
    IPC_VERIFIED_INDEX_DIRTY=false
    log_info "IPC index persist complete: records = [$record_count], duration_s = [$((SECONDS - started))]" || true
    return 0
}

should_run_ipc_retention_today() {
    local last_retention_date=""

    if [[ "$IPC_FORCE_RETENTION" == "true" ]]; then
        return 0
    fi
    if [[ -f "$IPC_RETENTION_DATE_FILE" && ! -L "$IPC_RETENTION_DATE_FILE" ]]; then
        IFS= read -r last_retention_date < "$IPC_RETENTION_DATE_FILE" || true
    fi
    [[ -z "$RUN_REFERENCE_DATE" || "$last_retention_date" != "$RUN_REFERENCE_DATE" ]]
}

commit_ipc_retention_date() {
    $DRY_RUN && return 0
    $IPC_RETENTION_PERFORMED || return 0
    [[ -n "$RUN_REFERENCE_DATE" ]] || return 1
    write_line_atomically "$IPC_RETENTION_DATE_FILE" "$RUN_REFERENCE_DATE" || return 1
    sync "$IPC_RETENTION_DATE_FILE" || return 1
    sync -f "${IPC_RETENTION_DATE_FILE%/*}" || return 1
}

calculate_sha256() {
    local file_path=$1

    calculate_sha256_to_result "$file_path" || return 1
    printf '%s\n' "$SHA256_RESULT"
}

calculate_sha256_to_result() {
    local file_path=$1 hash_output hash_record="" read_status=0

    SHA256_RESULT=""
    hash_output=$(mktemp "$STATE_DIR/sha256.XXXXXX") || return 1
    # GNU --zero suppresses filename escaping; keep the original tracked-child
    # execution and file argument (background commands must not rely on stdin).
    if ! run_interruptible_command sha256sum --zero -- "$file_path" \
        > "$hash_output" 2>/dev/null; then
        rm -f -- "$hash_output"
        return 1
    fi
    IFS= read -r -d '' hash_record < "$hash_output" || read_status=$?
    rm -f -- "$hash_output"
    (( read_status == 0 )) || return 1
    [[ "${hash_record:64:2}" == '  ' && "${hash_record:66}" == "$file_path" ]] || return 1
    [[ "${hash_record:0:64}" =~ ^[0-9a-f]{64}$ ]] || return 1
    SHA256_RESULT=${hash_record:0:64}
}

prepare_copy_temp_path_to_result() {
    local target_file=$1 candidate name attempt
    local LC_ALL=C
    candidate="$target_file.${RUNTIME_NAME}.$$.$RANDOM${TMP_SUFFIX}"
    name=${candidate##*/}
    # Keep the existing PID/random temporary-file model and cp creation modes.
    # Only long names use a short basename. This does not add protection against
    # concurrent directory replacement (outside this change's scope).
    if (( ${#name} <= 255 )); then
        COPY_TEMP_PATH_RESULT=$candidate
        return 0
    fi
    for ((attempt=0;attempt<16;attempt++)); do
        name=".${RUNTIME_NAME}.$$.$RANDOM.$RANDOM${TMP_SUFFIX}"
        (( ${#name} <= 255 )) || return 1
        candidate="${target_file%/*}/$name"
        [[ ! -e "$candidate" && ! -L "$candidate" ]] || continue
        COPY_TEMP_PATH_RESULT=$candidate
        return 0
    done
    COPY_TEMP_PATH_RESULT=""
    return 1
}

quote_path_for_log() {
    printf '%q' "$1"
}

log_copy_failure_details() {
    local source_file=$1
    local temp_file=$2
    local target_file=$3
    local copy_error=$4
    local quoted_source
    local quoted_temp
    local quoted_target

    quoted_source=$(quote_path_for_log "$source_file")
    quoted_temp=$(quote_path_for_log "$temp_file")
    quoted_target=$(quote_path_for_log "$target_file")

    log_error "Copy command failed."
    log_error "  source(raw): [$source_file]"
    log_error "  source(escaped): [$quoted_source]"
    log_error "  temp(escaped): [$quoted_temp]"
    log_error "  target(escaped): [$quoted_target]"
    log_error "  cp stderr: ${copy_error:-unknown}"

    if [[ -e "$target_file" || -L "$target_file" ]]; then
        log_error "  final target already exists when copy failed."
    fi

    if [[ -e "$temp_file" || -L "$temp_file" ]]; then
        log_error "  temp target was partially created before failure."
    fi
}

should_preserve_copy_metadata_for_class() {
    local target_class=$1
    [[ "$target_class" != "removable" ]]
}

should_delete_source_after_transfer_for_class() {
    local target_class=$1
    [[ "$target_class" != "ipc" ]]
}

should_clean_source_files_for_class() {
    local target_class=$1
    [[ "$target_class" == "ipc" ]]
}

files_equivalent_for_class() {
    local source_file=$1
    local target_file=$2
    local target_class=$3
    local source_size
    local target_size

    FILES_EQUIVALENT_FAST_PATH=false

    if [[ ! -f "$target_file" || -L "$target_file" ]]; then
        return 1
    fi

    if [[ "$target_class" == "ipc" ]] &&
       is_expected_ipc_source_target_pair "$source_file" "$target_file" &&
       ipc_verified_index_matches "$source_file" "$target_file"; then
        FILES_EQUIVALENT_FAST_PATH=true
        return 0
    fi

    source_size=$(get_file_size_bytes "$source_file")
    target_size=$(get_file_size_bytes "$target_file")
    if [[ -z "$source_size" || -z "$target_size" || "$source_size" != "$target_size" ]]; then
        return 1
    fi

    local source_hash
    local target_hash
    calculate_sha256_to_result "$source_file" || return 1
    source_hash=$SHA256_RESULT
    calculate_sha256_to_result "$target_file" || return 1
    target_hash=$SHA256_RESULT
    if [[ -n "$source_hash" && "$source_hash" == "$target_hash" ]]; then
        if [[ "$target_class" == "ipc" ]]; then
            stage_ipc_verified_file "$source_file" "$target_file" "$source_hash"
        fi
        return 0
    fi
    return 1
}

# 保护 today + yesterday 的日志文件这里采用更保守的日历日策略, 以规避跨午夜
# 切换时系统服务还未来得及新建当日日志, 就把上一日日志迁走导致无法继续落盘
is_recent_protected_log_file() {
    local source_dir=$1
    local filename=$2
    local file_date

    if [[ "$source_dir" != *"/logs/"* ]]; then
        return 1
    fi

    extract_date_from_filename_to_result "$filename"
    file_date=$EXTRACTED_DATE_RESULT
    [[ -n "$file_date" && ( "$file_date" == "$RUN_TODAY" || "$file_date" == "$RUN_YESTERDAY" ) ]]
}

classify_file_to_result() {
    local file_path=$1

    if [[ "$file_path" == *"/logs/"* ]]; then
        FILE_CLASS_RESULT="log"
    elif [[ "$file_path" == *.webp ]]; then
        FILE_CLASS_RESULT="rgb"
    elif [[ "$file_path" == *.pcd ]]; then
        FILE_CLASS_RESULT="point_cloud"
    else
        FILE_CLASS_RESULT="default"
    fi
}

classify_file() {
    classify_file_to_result "$1"
    echo "$FILE_CLASS_RESULT"
}

get_retention_days_for_file() {
    local file_path=$1
    local target_class=$2
    local file_class

    file_class=$(classify_file "$file_path")
    get_retention_days_for_file_class "$file_class" "$target_class"
}

get_retention_days_for_file_class_to_result() {
    local file_class=$1
    local target_class=$2
    local scoped_key
    local scoped_default_key

    scoped_key="${target_class}:${file_class}"
    scoped_default_key="${target_class}:default"

    # 说明:
    # 清理时优先命中"部署环境 + 文件类别"的精确配置;
    # 如果当前环境没有该类别配置, 再回退到该环境的 default, 最后回退到全局 default. 
    RETENTION_DAYS_RESULT="${RETENTION_DAYS_BY_SCOPE[$scoped_key]:-${RETENTION_DAYS_BY_SCOPE[$scoped_default_key]:-${RETENTION_DAYS_BY_SCOPE[global:default]}}}"
}

get_retention_days_for_file_class() {
    get_retention_days_for_file_class_to_result "$1" "$2"
    echo "$RETENTION_DAYS_RESULT"
}

# 检查迁移前剩余空间是否足够. 
# 只有"可用空间 - 预留安全余量"仍大于本次写入需求时, 才允许继续执行. 
ensure_space_for_bytes() {
    local target_class=$1
    local target_root=$2
    local required_bytes=$3
    local available_bytes
    local reserved_bytes

    available_bytes=$(get_available_bytes "$target_root")
    reserved_bytes=$(get_reserved_bytes_for_class "$target_class")

    if [[ -z "$available_bytes" ]]; then
        fail_now "failed to query free space for target root: [$target_root]"
    fi

    if (( available_bytes - reserved_bytes < required_bytes )); then
        fail_now "insufficient free space on [$target_root], required = [${required_bytes}], available = [${available_bytes}], reserved = [${reserved_bytes}]"
    fi
}

quick_preflight_space_check() {
    local target_class=$1
    local target_root=$2
    local available_bytes
    local reserved_bytes

    available_bytes=$(get_available_bytes "$target_root")
    reserved_bytes=$(get_reserved_bytes_for_class "$target_class")

    if [[ -z "$available_bytes" ]]; then
        fail_now "failed to query free space for target root: [$target_root]"
    fi

    if (( available_bytes <= reserved_bytes )); then
        fail_now "insufficient free space on [$target_root], available = [${available_bytes}], reserved = [${reserved_bytes}]"
    fi
}

sum_nul_relative_file_list_bytes() {
    local source_dir=$1
    local list_file=$2
    local total_bytes
    local du_output

    if [[ ! -s "$list_file" ]]; then
        echo "0"
        return 0
    fi

    du_output=$(mktemp "$STATE_DIR/pending_bytes.XXXXXX") || return 1
    if ! (
        cd "$source_dir" &&
            du --apparent-size --block-size=1 --total --files0-from="$list_file" \
                > "$du_output" 2>> "$LOG_FILE"
    ); then
        rm -f -- "$du_output"
        return 1
    fi
    total_bytes=$(awk 'END {print $1}' "$du_output") || {
        rm -f -- "$du_output"
        return 1
    }
    rm -f -- "$du_output"

    [[ "$total_bytes" =~ ^[0-9]+$ ]] || return 1
    echo "$total_bytes"
}

# 统计某个源目录下全部待迁移文件的总字节数
# 说明:
# 1. IPC 侧仍保留原有"按本批待迁移文件总量做空间预检查"的策略
# 2. ARM uses its prepared rsync manifests for exact pending-byte accounting;
#    this generic scanner remains for IPC.
sum_source_bytes_for_directory() {
    local source_dir=$1
    local total_bytes=0
    local file_size
    local source_manifest

    source_manifest=$(mktemp "$STATE_DIR/source_size_scan.XXXXXX") ||
        fail_now "failed to allocate source size manifest"
    if ! find "$source_dir" -type f -print0 > "$source_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$source_manifest"
        fail_now "failed to enumerate source size candidates: [$source_dir]"
    fi

    while IFS= read -r -d $'\0' file; do
        local relative_path="${file#"$source_dir"}"

        relative_path=${relative_path#/}

        if ! should_transfer_file_for_source "$source_dir" "$file" "$relative_path"; then
            continue
        fi

        if is_recent_protected_log_file "$source_dir" "${file##*/}"; then
            continue
        fi

        file_size=$(get_file_size_bytes "$file")
        if [[ ! "$file_size" =~ ^[0-9]+$ ]]; then
            rm -f -- "$source_manifest"
            fail_now "failed to read source file size: [$file]"
        fi
        total_bytes=$((total_bytes + file_size))
    done < "$source_manifest"

    rm -f -- "$source_manifest"
    echo "$total_bytes"
}

# IPC 预检查只统计本轮确实需要写入的字节：
# 1. 目标不存在时计入源文件大小；
# 2. 目标已存在且 size + SHA-256 等价时不计入；
# 3. 目标冲突时仅在对应的内容寻址 .conflicts 隔离副本也缺失时计入
# 维护模式必须保证源目录停写，因此该计划在随后的复制阶段保持有效
# Remove only exact paths allocated by this process. Keep the list on failure
# so exit cleanup can retry; historical leftovers are handled under the lock.
cleanup_ipc_preflight_metadata_temp_files() {
    (( ${#IPC_PREFLIGHT_METADATA_TEMP_FILES[@]} > 0 )) || return 0
    if ! rm -f -- "${IPC_PREFLIGHT_METADATA_TEMP_FILES[@]}"; then
        log_warn "Failed to remove IPC preflight metadata temporary files; cleanup will be retried."
        return 1
    fi
    IPC_PREFLIGHT_METADATA_TEMP_FILES=()
}

# A state directory can be shared by separately named runtimes with different
# instance locks. Hold one directory-wide lock for this process's metadata
# lifetime, so another runtime cannot mistake active files for crash leftovers.
# Lock contention disables this optimization, not the original preflight.
acquire_ipc_preflight_metadata_guard() {
    $IPC_PREFLIGHT_METADATA_GUARD_HELD && return 0
    if ! exec {IPC_PREFLIGHT_METADATA_GUARD_FD}> "$STATE_DIR/.ipc_preflight_metadata.lock"; then
        return 1
    fi
    if ! flock -n "$IPC_PREFLIGHT_METADATA_GUARD_FD"; then
        exec {IPC_PREFLIGHT_METADATA_GUARD_FD}>&-
        IPC_PREFLIGHT_METADATA_GUARD_FD=""
        return 1
    fi
    IPC_PREFLIGHT_METADATA_GUARD_HELD=true
}

# Called only after acquiring the runtime lock, before starting any batch.
# Covers SIGKILL/power loss, for which EXIT cleanup cannot execute.
cleanup_ipc_preflight_orphan_metadata() {
    local metadata_file base_name removed_count=0
    $DRY_RUN && return 0
    $AUTO_TRANSFER_LOCK_HELD || return 1
    (( ${#IPC_PREFLIGHT_METADATA_TEMP_FILES[@]} == 0 )) || return 1
    acquire_ipc_preflight_metadata_guard || return 1
    for metadata_file in "$STATE_DIR"/ipc_stat_{input,output,error}.*; do
        [[ -f "$metadata_file" && ! -L "$metadata_file" ]] || continue
        base_name=${metadata_file##*/}
        [[ "$base_name" =~ ^ipc_stat_(input|output|error)\.[a-zA-Z0-9]{6}$ ]] || continue
        rm -f -- "$metadata_file" || return 1
        removed_count=$((removed_count + 1))
    done
    if (( removed_count > 0 )); then
        log_info "Removed orphan IPC preflight metadata files: count = [$removed_count]"
    fi
    return 0
}

# Preflight-only metadata hints, bounded to one batch. Never reused for copy,
# persistent verification or retention eligibility.
prepare_ipc_preflight_metadata_batch() {
    local source_dir=$1 target_dir=$2
    shift 2
    local file relative_path target_file input_file output_file error_file
    local metadata_status=0 path mode fingerprint size invalid=false
    IPC_PREFLIGHT_BATCH_FINGERPRINTS=()
    IPC_PREFLIGHT_BATCH_SIZES=()
    cleanup_ipc_preflight_metadata_temp_files || return 1
    # Empty hints make the caller use its original checks on contention or
    # inability to create the guard file. Do not allocate shared temp files.
    acquire_ipc_preflight_metadata_guard || return 0
    input_file=$(mktemp "$STATE_DIR/ipc_stat_input.XXXXXX") || return 1
    IPC_PREFLIGHT_METADATA_TEMP_FILES+=("$input_file")
    output_file=$(mktemp "$STATE_DIR/ipc_stat_output.XXXXXX") || {
        cleanup_ipc_preflight_metadata_temp_files || true; return 1;
    }
    IPC_PREFLIGHT_METADATA_TEMP_FILES+=("$output_file")
    error_file=$(mktemp "$STATE_DIR/ipc_stat_error.XXXXXX") || {
        cleanup_ipc_preflight_metadata_temp_files || true; return 1;
    }
    IPC_PREFLIGHT_METADATA_TEMP_FILES+=("$error_file")
    for file in "$@"; do
        relative_path=${file#"$source_dir"}
        relative_path=${relative_path#/}
        target_file="$target_dir/$relative_path"
        printf '%s\0' "$file" >> "$input_file" || {
            cleanup_ipc_preflight_metadata_temp_files || true; return 1;
        }
        if [[ -f "$target_file" && ! -L "$target_file" ]]; then
            printf '%s\0' "$target_file" >> "$input_file" || {
                cleanup_ipc_preflight_metadata_temp_files || true; return 1;
            }
        fi
    done
    # xargs bounds argv for long paths. lstat excludes symbolic links; GNU stat
    # emits exactly the existing fingerprint's nanosecond/timezone format.
    if run_interruptible_command xargs -0 -r -a "$input_file" stat \
        --printf='%n\0%f\0%d:%i:%s:%y:%z\0%s\0' -- \
        > "$output_file" 2> "$error_file"; then
        metadata_status=0
    else
        metadata_status=$?
    fi
    # 123 means an individual stat failed (e.g. disappearance). Complete records
    # remain useful; paths without a record take the original per-file path.
    if (( metadata_status == 0 || metadata_status == 123 )); then
        while IFS= read -r -d '' path; do
            if ! IFS= read -r -d '' mode ||
               ! IFS= read -r -d '' fingerprint ||
               ! IFS= read -r -d '' size; then
                invalid=true; break
            fi
            if [[ -z "$path" || ! "$mode" =~ ^[0-9a-fA-F]+$ ||
                  -z "$fingerprint" || ! "$size" =~ ^[0-9]+$ ]]; then
                invalid=true; break
            fi
            if (( (16#$mode & 0170000) == 0100000 )); then
                IPC_PREFLIGHT_BATCH_FINGERPRINTS["$path"]=$fingerprint
                IPC_PREFLIGHT_BATCH_SIZES["$path"]=$size
            fi
        done < "$output_file"
    else
        invalid=true
    fi
    cleanup_ipc_preflight_metadata_temp_files || true
    if $invalid; then
        IPC_PREFLIGHT_BATCH_FINGERPRINTS=()
        IPC_PREFLIGHT_BATCH_SIZES=()
        log_warn "IPC preflight batch metadata unavailable; using original per-file checks for this batch."
    fi
    return 0
}

ipc_preflight_batch_index_matches() {
    local source_file=$1 target_file=$2
    [[ "$IPC_FORCE_FULL_AUDIT" != "true" ||
       -n "${IPC_VERIFIED_THIS_RUN[$source_file]+x}" ]] || return 1
    [[ -n "${IPC_PREFLIGHT_BATCH_FINGERPRINTS[$source_file]:-}" &&
       -n "${IPC_PREFLIGHT_BATCH_FINGERPRINTS[$target_file]:-}" ]] || return 1
    is_expected_ipc_source_target_pair "$source_file" "$target_file" || return 1
    [[ "${IPC_VERIFIED_TARGET_PATHS[$source_file]:-}" == "$target_file" &&
       "${IPC_VERIFIED_SOURCE_FINGERPRINTS[$source_file]:-}" == "${IPC_PREFLIGHT_BATCH_FINGERPRINTS[$source_file]}" &&
       "${IPC_VERIFIED_TARGET_FINGERPRINTS[$source_file]:-}" == "${IPC_PREFLIGHT_BATCH_FINGERPRINTS[$target_file]}" ]] || return 1
    [[ -f "$source_file" && ! -L "$source_file" &&
       -f "$target_file" && ! -L "$target_file" ]]
}

sum_pending_copy_bytes_for_directory() {
    local source_dir=$1
    local target_dir=$2
    local target_class=$3
    local total_bytes=0
    local file_size
    local source_manifest
    local file
    local filename
    local relative_path
    local target_file
    local source_key
    local source_hash
    local quarantine_file
    local scanned_count=0
    local batch_size=${IPC_PREFLIGHT_METADATA_BATCH_SIZE:-256}
    local read_batch_size batch_index
    local -a batch_files=()
    local -A IPC_PREFLIGHT_BATCH_FINGERPRINTS=()
    local -A IPC_PREFLIGHT_BATCH_SIZES=()

    SUM_PENDING_COPY_BYTES_RESULT=0
    if [[ ! "$batch_size" =~ ^(0|[1-9][0-9]{0,3})$ ]] || (( batch_size > 4096 )); then
        fail_now "IPC_PREFLIGHT_METADATA_BATCH_SIZE must be an integer in 0..4096"
    fi
    read_batch_size=$batch_size
    (( read_batch_size > 0 )) || read_batch_size=256
    if [[ ! "$IPC_PREFLIGHT_PROGRESS_INTERVAL" =~ ^[0-9]+$ ]]; then
        fail_now "IPC_PREFLIGHT_PROGRESS_INTERVAL must be a non-negative integer"
    fi
    if [[ -n "${IPC_PREFLIGHT_SOURCE_MANIFESTS[$source_dir]:-}" ]]; then
        rm -f -- "${IPC_PREFLIGHT_SOURCE_MANIFESTS[$source_dir]}"
        unset 'IPC_PREFLIGHT_SOURCE_MANIFESTS[$source_dir]'
    fi
    source_manifest=$(mktemp "$STATE_DIR/ipc_pending_size_scan.XXXXXX") ||
        fail_now "failed to allocate IPC pending size manifest"
    log_info "IPC preflight scan start: source = [$source_dir], target = [$target_dir], progress_interval_files = [$IPC_PREFLIGHT_PROGRESS_INTERVAL]"
    if ! find "$source_dir" -type f -print0 > "$source_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$source_manifest"
        fail_now "failed to enumerate IPC pending size candidates: [$source_dir]"
    fi

    [[ "$target_class" != "ipc" ]] || load_ipc_verified_index
    while true; do
        batch_files=()
        for (( batch_index=0; batch_index<read_batch_size; batch_index++ )); do
            IFS= read -r -d '' file || break
            batch_files+=("$file")
        done
        (( ${#batch_files[@]} > 0 )) || break
        if [[ "$target_class" == "ipc" ]] && (( batch_size > 0 )); then
            prepare_ipc_preflight_metadata_batch "$source_dir" "$target_dir" "${batch_files[@]}" || {
                rm -f -- "$source_manifest"
                fail_now "failed to prepare IPC preflight batch metadata"
            }
        fi
        for file in "${batch_files[@]}"; do
            check_interruption_requested
            scanned_count=$((scanned_count + 1))
            if (( IPC_PREFLIGHT_PROGRESS_INTERVAL > 0 &&
                  scanned_count % IPC_PREFLIGHT_PROGRESS_INTERVAL == 0 )); then
                log_info "IPC preflight scan progress: source = [$source_dir], scanned_files = [$scanned_count], pending_bytes = [$total_bytes], current_file = [$file]"
            fi
            relative_path=${file#"$source_dir"}
            relative_path=${relative_path#/}
            filename=${file##*/}

            if ! should_transfer_file_for_source "$source_dir" "$file" "$relative_path"; then
                continue
            fi
            if is_recent_protected_log_file "$source_dir" "$filename"; then
                continue
            fi

            target_file="$target_dir/$relative_path"
            if [[ -e "$target_file" || -L "$target_file" ]]; then
                if [[ "$target_class" == "ipc" ]] &&
                   ipc_preflight_batch_index_matches "$file" "$target_file"; then
                    continue
                fi
                if files_equivalent_for_class "$file" "$target_file" "$target_class"; then
                    continue
                fi

                # IPC conflicts are written below .conflicts. If the exact
                # content-addressed quarantine copy already exists, this run only
                # verifies it and performs no additional data write.
                if [[ "$target_class" == "ipc" && -n "${IPC_CONFLICT_ROOT:-}" ]]; then
                    source_key=${SOURCE_RELATIVE_TARGETS[$source_dir]:-unknown_source}
                    if ! calculate_sha256_to_result "$file"; then
                        rm -f -- "$source_manifest"
                        fail_now "failed to hash IPC conflict during pending size scan: [$file]"
                    fi
                    source_hash=$SHA256_RESULT
                    quarantine_file="$IPC_CONFLICT_ROOT/$source_key/$source_hash/$relative_path"
                    if [[ -e "$quarantine_file" || -L "$quarantine_file" ]] &&
                       files_equivalent_for_class "$file" "$quarantine_file" "$target_class"; then
                        continue
                    fi
                fi
            fi

            file_size=${IPC_PREFLIGHT_BATCH_SIZES[$file]:-}
            if [[ -z "$file_size" ]]; then
                file_size=$(get_file_size_bytes "$file")
            fi
            if [[ ! "$file_size" =~ ^[0-9]+$ ]]; then
                rm -f -- "$source_manifest"
                fail_now "failed to read IPC pending source file size: [$file]"
            fi
            total_bytes=$((total_bytes + file_size))
        done
    done < "$source_manifest"
    IPC_PREFLIGHT_BATCH_FINGERPRINTS=()
    IPC_PREFLIGHT_BATCH_SIZES=()

    # Reuse the exact preflight snapshot in the copy phase.  IPC orchestration
    # already requires producers to be stopped, so a second full find would
    # add cost without discovering legitimate new work.
    IPC_PREFLIGHT_SOURCE_MANIFESTS["$source_dir"]=$source_manifest
    IPC_PREFLIGHT_SOURCE_COUNTS["$source_dir"]=$scanned_count
    SUM_PENDING_COPY_BYTES_RESULT=$total_bytes
    log_info "IPC preflight scan complete: source = [$source_dir], scanned_files = [$scanned_count], pending_bytes = [$total_bytes]"
}

cleanup_orphan_temp_files_under() {
    local scan_root=$1
    local orphan_manifest
    local temp_file
    local temp_mtime

    [[ -d "$scan_root" ]] || return 0
    orphan_manifest=$(mktemp "$STATE_DIR/orphan_files.XXXXXX") ||
        fail_now "failed to allocate orphan temp manifest"

    if ! find "$scan_root" -type f -name "*.${RUNTIME_NAME}.*${TMP_SUFFIX}" -print0 \
        > "$orphan_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$orphan_manifest"
        fail_now "failed to enumerate orphan temp files: [$scan_root]"
    fi

    while IFS= read -r -d $'\0' temp_file; do
        temp_mtime=$(get_file_mtime_epoch "$temp_file")
        if [[ "$temp_mtime" =~ ^[0-9]+$ && "$temp_mtime" -lt "$RUN_START_EPOCH" ]]; then
            if rm -f -- "$temp_file" 2>> "$LOG_FILE" &&
               [[ ! -e "$temp_file" && ! -L "$temp_file" ]]; then
                log_warn "Removed orphan temp file: [$temp_file]"
            else
                rm -f -- "$orphan_manifest"
                fail_now "failed to remove orphan temp file: [$temp_file]"
            fi
        fi
    done < "$orphan_manifest"
    rm -f -- "$orphan_manifest"
}

cleanup_orphan_temp_files() {
    local source_dir
    local target_dir

    $DRY_RUN && return 0

    if [[ "${DEFAULT_TARGET_CLASS:-}" == "ipc" ]]; then
        cleanup_ipc_preflight_orphan_metadata ||
            log_warn "Could not finish orphan IPC metadata cleanup; check state-directory permissions and the runtime lock."
    fi

    # Target temp files are never committed results and may be removed on the
    # next run only when they predate this run.
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        target_dir=$(get_target_dir_for_source "$source_dir")
        cleanup_orphan_temp_files_under "$target_dir"
    done

    if [[ -n "${IPC_CONFLICT_ROOT:-}" ]]; then
        cleanup_orphan_temp_files_under "$IPC_CONFLICT_ROOT"
    fi
}

mark_source_backed_up() {
    local source_file=$1
    BACKED_UP_SOURCE_INDEX["$source_file"]=1
}

is_source_backed_up() {
    local source_file=$1
    [[ -n "${BACKED_UP_SOURCE_INDEX[$source_file]+x}" ]]
}

protect_path_from_retention() {
    local file_path=$1
    RETENTION_PROTECTED_PATHS["$file_path"]=1
}

is_path_protected_from_retention() {
    local file_path=$1
    [[ -n "${RETENTION_PROTECTED_PATHS[$file_path]+x}" ]]
}

queue_source_for_deferred_delete() {
    local source_file=$1
    local target_file=$2
    local file_class=$3

    if [[ -z "$SOURCE_DELETE_PENDING_PATHS_FILE" || -z "$SOURCE_DELETE_PENDING_RECORDS_FILE" ]]; then
        fail_now "source delete manifests are not initialized"
    fi

    printf '%s\0' "$source_file" >> "$SOURCE_DELETE_PENDING_PATHS_FILE" ||
        fail_now "failed to append source delete path"
    printf '%s\0%s\0%s\0' "$source_file" "$target_file" "$file_class" >> "$SOURCE_DELETE_PENDING_RECORDS_FILE" ||
        fail_now "failed to append source delete record"
    append_ledger_record "delete_deferred" "$source_file" "$target_file" "$file_class" "source deletion deferred until removable commit" ||
        fail_now "failed to buffer deferred source record"
}

remove_source_after_record() {
    local source_file=$1
    local target_file=$2
    local file_class=$3
    local target_class=$4
    local verified_sha256=${5:-}

    if [[ "$target_class" == "ipc" ]]; then
        stage_ipc_verified_file "$source_file" "$target_file" "$verified_sha256"
    fi

    append_ledger_record "verified" "$source_file" "$target_file" "$file_class" "target verified and source handling is ready" ||
        fail_now "failed to buffer verified transfer record"

    if $DRY_RUN; then
        if should_delete_source_after_transfer_for_class "$target_class"; then
            log_info "[DRY-RUN] Would delete source after verification: [$source_file]"
        else
            log_info "[DRY-RUN] Would retain source after verification and clean it later by retention: [$source_file]"
        fi
        return 0
    fi

    if ! should_delete_source_after_transfer_for_class "$target_class"; then
        append_ledger_record "source_retained" "$source_file" "$target_file" "$file_class" "source retained after verification for retention-based cleanup" ||
            fail_now "failed to buffer retained source record"
        mark_source_backed_up "$source_file"
        return 0
    fi

    queue_source_for_deferred_delete "$source_file" "$target_file" "$file_class"
}

commit_deferred_source_manifest() {
    if $DRY_RUN; then
        return 0
    fi

    if ! $REMOVABLE_MOUNT_COMMITTED; then
        fail_now "cannot commit source delete manifest before removable commit/unmount"
    fi

    # Commit the path list last; its presence is the commit marker.
    if ! mv -- "$SOURCE_DELETE_PENDING_RECORDS_FILE" "$SOURCE_DELETE_COMMITTED_RECORDS_FILE" ||
       ! mv -- "$SOURCE_DELETE_PENDING_PATHS_FILE" "$SOURCE_DELETE_COMMITTED_PATHS_FILE"; then
        fail_now "failed to atomically commit source delete manifests"
    fi

    SOURCE_DELETE_PENDING_PATHS_FILE=""
    SOURCE_DELETE_PENDING_RECORDS_FILE=""

    sync "$SOURCE_DELETE_COMMITTED_PATHS_FILE" "$SOURCE_DELETE_COMMITTED_RECORDS_FILE" ||
        fail_now "failed to persist committed source delete manifests"
    sync -f "$STATE_DIR" || fail_now "failed to persist source delete manifest directory"
    SOURCE_DELETE_MANIFEST_COMMITTED=true
    log_info "Source delete manifest committed after removable unmount."
}

commit_deferred_source_deletions() {
    local source_file
    local target_file
    local file_class
    local delete_failed=0

    if $DRY_RUN; then
        while IFS= read -r -d $'\0' source_file &&
              IFS= read -r -d $'\0' target_file &&
              IFS= read -r -d $'\0' file_class; do
            log_info "[DRY-RUN] Would batch-delete committed source: [$source_file]"
        done < "$SOURCE_DELETE_PENDING_RECORDS_FILE"
        return 0
    fi

    if ! $REMOVABLE_MOUNT_COMMITTED || ! $SOURCE_DELETE_MANIFEST_COMMITTED; then
        fail_now "source deletion is blocked because removable commit or manifest commit did not complete"
    fi

    if [[ ! -s "$SOURCE_DELETE_COMMITTED_PATHS_FILE" ]]; then
        rm -f -- "$SOURCE_DELETE_COMMITTED_PATHS_FILE" "$SOURCE_DELETE_COMMITTED_RECORDS_FILE"
        SOURCE_DELETE_MANIFEST_COMMITTED=false
        return 0
    fi

    log_info "Batch source deletion start."
    if ! xargs -0 -r rm -f -- < "$SOURCE_DELETE_COMMITTED_PATHS_FILE" 2>> "$LOG_FILE"; then
        delete_failed=1
    fi

    while IFS= read -r -d $'\0' source_file &&
          IFS= read -r -d $'\0' target_file &&
          IFS= read -r -d $'\0' file_class; do
        if [[ -e "$source_file" || -L "$source_file" ]]; then
            append_ledger_record "source_delete_failed" "$source_file" "$target_file" "$file_class" "source remained after batch deletion" ||
                delete_failed=1
            delete_failed=1
        else
            append_ledger_record "source_deleted" "$source_file" "$target_file" "$file_class" "source deleted after removable commit" ||
                delete_failed=1
        fi
    done < "$SOURCE_DELETE_COMMITTED_RECORDS_FILE"

    flush_ledger_buffer || fail_now "failed to flush source deletion ledger"

    if (( delete_failed != 0 )); then
        fail_now "one or more committed source files could not be deleted"
    fi

    rm -f -- "$SOURCE_DELETE_COMMITTED_PATHS_FILE" "$SOURCE_DELETE_COMMITTED_RECORDS_FILE" ||
        fail_now "failed to remove completed source delete manifests"
    SOURCE_DELETE_MANIFEST_COMMITTED=false
    log_info "Batch source deletion complete."
}

extract_date_from_filename_to_result() {
    local filename=$1
    local file_date=""
    local ts
    local candidate=""
    local normalized=""

    if [[ $filename =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        candidate=${BASH_REMATCH[1]}
    elif [[ $filename =~ ([0-9]{8}) ]]; then
        ts=${BASH_REMATCH[1]}
        candidate="${ts:0:4}-${ts:4:2}-${ts:6:2}"
    fi

    if [[ -n "$candidate" ]]; then
        if [[ -z "${DATE_VALIDATION_CACHE[$candidate]+x}" ]]; then
            normalized=$(date -d "$candidate" +"%Y-%m-%d" 2>/dev/null || true)
            if [[ "$normalized" == "$candidate" ]]; then
                DATE_VALIDATION_CACHE["$candidate"]="$candidate"
            else
                DATE_VALIDATION_CACHE["$candidate"]="invalid"
            fi
        fi

        if [[ "${DATE_VALIDATION_CACHE[$candidate]}" != "invalid" ]]; then
            file_date=${DATE_VALIDATION_CACHE[$candidate]}
        fi
    fi
    EXTRACTED_DATE_RESULT=$file_date
}

extract_date_from_filename() {
    extract_date_from_filename_to_result "$1"
    echo "$EXTRACTED_DATE_RESULT"
}

record_collision() {
    local source_dir=$1
    local source_file=$2
    local target_file=$3
    local file_class=$4
    local source_key

    source_key=${SOURCE_RELATIVE_TARGETS[$source_dir]:-$source_dir}
    CONFLICT_COUNTS_BY_SOURCE[$source_key]=$(( ${CONFLICT_COUNTS_BY_SOURCE[$source_key]:-0} + 1 ))
    CONFLICT_TOTAL=$((CONFLICT_TOTAL + 1))
    protect_path_from_retention "$target_file"

    append_ledger_record "collision" "$source_file" "$target_file" "$file_class" "target exists but content differs" ||
        fail_now "failed to buffer collision record"
    log_warn "Detected target collision and skipped source file: [$source_file] ---> [$target_file]"
}

quarantine_conflicting_source() {
    local source_dir=$1
    local source_file=$2
    local original_target_file=$3
    local file_class=$4
    local target_class=$5
    local conflict_root=${IPC_CONFLICT_ROOT:-}
    local source_key
    local relative_path
    local source_hash
    local quarantine_file
    local quarantine_parent
    local temp_file
    local quarantine_hash

    [[ "$target_class" == "ipc" && -n "$conflict_root" ]] || return 1

    source_key=${SOURCE_RELATIVE_TARGETS[$source_dir]:-unknown_source}
    relative_path=${source_file#"$source_dir"}
    relative_path=${relative_path#/}
    [[ -n "$relative_path" ]] || return 1

    if ! calculate_sha256_to_result "$source_file"; then
        log_error "Failed to hash conflicting source before quarantine: [$source_file]"
        return 1
    fi
    source_hash=$SHA256_RESULT

    # The content hash is a directory component so an original 255-byte filename
    # remains valid, while repeated conflicts are naturally idempotent.
    quarantine_file="$conflict_root/$source_key/$source_hash/$relative_path"
    quarantine_parent=${quarantine_file%/*}
    if ! validate_delete_path_under_root "$conflict_root" "$quarantine_file"; then
        log_error "Refused conflict quarantine path outside configured root: [$quarantine_file]"
        return 1
    fi

    if [[ -e "$quarantine_file" || -L "$quarantine_file" ]]; then
        if files_equivalent_for_class "$source_file" "$quarantine_file" "$target_class"; then
            sync "$quarantine_file" && sync -f "$conflict_root" || return 1
            protect_path_from_retention "$original_target_file"
            append_ledger_record "conflict_already_quarantined" "$source_file" "$quarantine_file" "$file_class" "matching quarantine copy already exists" ||
                return 1
            mark_source_backed_up "$source_file"
            QUARANTINED_CONFLICT_TOTAL=$((QUARANTINED_CONFLICT_TOTAL + 1))
            return 0
        fi

        log_error "Refused to overwrite a non-equivalent quarantine path: [$quarantine_file]"
        return 1
    fi

    mkdir -p "$quarantine_parent" 2>> "$LOG_FILE" || {
        log_error "Failed to create conflict quarantine directory: [$quarantine_parent]"
        return 1
    }

    prepare_copy_temp_path_to_result "$quarantine_file" || return 1
    temp_file=$COPY_TEMP_PATH_RESULT
    if ! run_interruptible_command cp --reflink=auto -- \
        "$source_file" "$temp_file" 2>> "$LOG_FILE"; then
        rm -f -- "$temp_file"
        log_error "Failed to copy conflicting source into quarantine: [$source_file]"
        return 1
    fi

    if ! calculate_sha256_to_result "$temp_file"; then
        rm -f -- "$temp_file"
        log_error "Failed to hash conflict quarantine temp file: [$temp_file]"
        return 1
    fi
    quarantine_hash=$SHA256_RESULT
    if [[ "$quarantine_hash" != "$source_hash" ]]; then
        rm -f -- "$temp_file"
        log_error "Conflict quarantine hash verification failed: [$source_file]"
        return 1
    fi

    sync "$temp_file" || {
        rm -f -- "$temp_file"
        log_error "Failed to persist conflict quarantine temp file: [$temp_file]"
        return 1
    }

    if ! mv -n -- "$temp_file" "$quarantine_file" 2>> "$LOG_FILE"; then
        rm -f -- "$temp_file"
        log_error "Failed to commit conflict quarantine file: [$quarantine_file]"
        return 1
    fi

    # GNU mv -n succeeds when it declines an overwrite. Detect that case.
    if [[ -e "$temp_file" || ! -f "$quarantine_file" ]]; then
        rm -f -- "$temp_file"
        log_error "Conflict quarantine commit did not create the expected file: [$quarantine_file]"
        return 1
    fi

    if ! calculate_sha256_to_result "$quarantine_file"; then
        log_error "Failed to hash committed conflict quarantine file: [$quarantine_file]"
        return 1
    fi
    quarantine_hash=$SHA256_RESULT
    if [[ "$quarantine_hash" != "$source_hash" ]]; then
        log_error "Committed conflict quarantine file failed hash verification: [$quarantine_file]"
        return 1
    fi

    sync "$quarantine_file" && sync -f "$conflict_root" || {
        log_error "Failed to persist committed conflict quarantine data: [$quarantine_file]"
        return 1
    }

    protect_path_from_retention "$original_target_file"
    append_ledger_record "conflict_quarantined" "$source_file" "$quarantine_file" "$file_class" "conflicting source copied, hashed and persisted" ||
        return 1
    mark_source_backed_up "$source_file"
    QUARANTINED_CONFLICT_TOTAL=$((QUARANTINED_CONFLICT_TOTAL + 1))
    log_warn "Quarantined conflicting source: [$source_file] ---> [$quarantine_file]"
}

build_conflict_summary() {
    local parts=()
    local source_dir
    local source_key

    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        source_key=${SOURCE_RELATIVE_TARGETS[$source_dir]}
        if [[ -n "${CONFLICT_COUNTS_BY_SOURCE[$source_key]:-}" ]]; then
            parts+=("${source_key}:${CONFLICT_COUNTS_BY_SOURCE[$source_key]}")
        fi
    done

    if (( ${#parts[@]} == 0 )); then
        echo "conflict_count = [${CONFLICT_TOTAL}]"
    else
        local joined
        joined=$(IFS=,; echo "${parts[*]}")
        echo "conflict_count = [${CONFLICT_TOTAL}]; conflict_sources = [${joined}]"
    fi
}

get_directory_latest_file_mtime_epoch() {
    local dir_path=$1
    local mtime_manifest

    mtime_manifest=$(mktemp "$STATE_DIR/directory_mtimes.XXXXXX") || return 1
    if ! find "$dir_path" -type f -printf '%T@\n' > "$mtime_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$mtime_manifest"
        return 1
    fi
    awk 'BEGIN{max=0} {if ($1>max) max=$1} END {if (max>0) printf "%.0f\n", max}' "$mtime_manifest"
    local awk_status=$?
    rm -f -- "$mtime_manifest"
    return "$awk_status"
}

validate_delete_path_under_root() {
    local allowed_root=$1
    local candidate_path=$2
    local resolved_root
    local resolved_candidate

    [[ -n "$allowed_root" && -n "$candidate_path" ]] || return 1
    resolved_root=$(realpath -m "$allowed_root") || return 1
    resolved_candidate=$(realpath -m "$candidate_path") || return 1

    [[ "$resolved_candidate" != "$resolved_root" && "$resolved_candidate" == "$resolved_root/"* ]]
}

reserve_retention_delete_budget() {
    local path_bytes=$1
    local object_type=$2

    if [[ "$object_type" == "tree" ]]; then
        if (( RETENTION_TREE_DELETE_COUNT + 1 > RETENTION_MAX_TREE_DELETIONS )); then
            return 1
        fi
    else
        if (( RETENTION_FILE_DELETE_COUNT + 1 > RETENTION_MAX_FILE_DELETIONS )); then
            return 1
        fi
    fi

    if (( RETENTION_DELETE_BYTES + path_bytes > RETENTION_MAX_DELETE_BYTES )); then
        return 1
    fi

    if [[ "$object_type" == "tree" ]]; then
        RETENTION_TREE_DELETE_COUNT=$((RETENTION_TREE_DELETE_COUNT + 1))
    else
        RETENTION_FILE_DELETE_COUNT=$((RETENTION_FILE_DELETE_COUNT + 1))
    fi
    RETENTION_DELETE_BYTES=$((RETENTION_DELETE_BYTES + path_bytes))
}

enforce_retention_tree_candidate_limit() {
    local total_count=$1
    local candidate_count=$2
    local context=$3
    local allow_full_candidate_ratio=${4:-false}

    (( candidate_count == 0 )) && return 0

    if (( candidate_count > RETENTION_MAX_TREE_DELETIONS )); then
        fail_now "retention tree candidate count exceeds per-run limit: context = [$context], candidates = [$candidate_count], limit = [$RETENTION_MAX_TREE_DELETIONS]"
    fi

    if [[ "$allow_full_candidate_ratio" != "true" ]] &&
       (( total_count > 0 &&
          candidate_count * 100 > total_count * RETENTION_MAX_TREE_DELETE_PERCENT )); then
        fail_now "retention tree candidate ratio tripped the time-safety circuit breaker: context = [$context], candidates = [$candidate_count], total = [$total_count], limit_percent = [$RETENTION_MAX_TREE_DELETE_PERCENT]"
    fi
}

safe_remove_retention_tree() {
    local allowed_root=$1
    local dir_path=$2
    local tree_bytes

    if ! $TIME_TRUSTED; then
        log_warn "Skip retention tree deletion because time is untrusted: [$dir_path]"
        return 1
    fi

    if ! validate_delete_path_under_root "$allowed_root" "$dir_path"; then
        fail_now "refused unsafe retention tree path: root = [$allowed_root], candidate = [$dir_path]"
    fi

    if [[ -L "$dir_path" ]] || findmnt -rn -M "$dir_path" >/dev/null 2>&1; then
        fail_now "refused retention deletion of symlink or mount point: [$dir_path]"
    fi

    tree_bytes=$(du -sb -- "$dir_path" 2>> "$LOG_FILE") ||
        fail_now "failed to calculate retention tree size: [$dir_path]"
    tree_bytes=${tree_bytes%%$'\t'*}
    [[ "$tree_bytes" =~ ^[0-9]+$ ]] || fail_now "failed to calculate retention tree size: [$dir_path]"

    reserve_retention_delete_budget "$tree_bytes" "tree" ||
        fail_now "retention tree deletion budget exceeded before deleting: [$dir_path]"

    if ! rm -rf -- "$dir_path" 2>> "$LOG_FILE"; then
        fail_now "failed to delete retention tree: [$dir_path]"
    fi

    if [[ -e "$dir_path" || -L "$dir_path" ]]; then
        fail_now "retention tree still exists after deletion: [$dir_path]"
    fi
}

safe_remove_retention_file() {
    local allowed_root=$1
    local file_path=$2
    local file_bytes

    if ! $TIME_TRUSTED; then
        return 1
    fi

    if ! validate_delete_path_under_root "$allowed_root" "$file_path"; then
        fail_now "refused unsafe retention file path: root = [$allowed_root], candidate = [$file_path]"
    fi

    if [[ -L "$file_path" ]]; then
        fail_now "refused retention deletion of symlink: [$file_path]"
    fi

    file_bytes=$(get_file_size_bytes "$file_path")
    [[ "$file_bytes" =~ ^[0-9]+$ ]] || fail_now "failed to calculate retention file size: [$file_path]"

    reserve_retention_delete_budget "$file_bytes" "file" ||
        fail_now "retention file deletion budget exceeded before deleting: [$file_path]"

    if ! rm -f -- "$file_path" 2>> "$LOG_FILE"; then
        return 1
    fi

    [[ ! -e "$file_path" && ! -L "$file_path" ]]
}

is_directory_tree_stale() {
    local dir_path=$1
    local stale_days=$2
    local latest_epoch
    local cutoff_epoch

    latest_epoch=$(get_directory_latest_file_mtime_epoch "$dir_path")
    if [[ -z "$latest_epoch" ]]; then
        return 1
    fi

    get_cutoff_date_cached "$stale_days"
    cutoff_epoch=$CUTOFF_EPOCH_RESULT
    (( latest_epoch < cutoff_epoch ))
}

cleanup_empty_directories() {
    local source_dir=$1
    local directory_manifest
    local directory_count
    local remaining_count=0
    local dir_path

    if [[ ! -d "$source_dir" ]]; then
        return 0
    fi
    if $DRY_RUN; then
        log_info "[DRY-RUN] Would remove empty directories under: [$source_dir]"
        return 0
    fi

    directory_manifest=$(mktemp "$STATE_DIR/empty_directories.XXXXXX") ||
        fail_now "failed to allocate empty directory manifest"
    if ! find "$source_dir" -depth -mindepth 1 -type d -empty -print0 > "$directory_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$directory_manifest"
        fail_now "failed to enumerate empty directories: [$source_dir]"
    fi

    directory_count=$(tr -cd '\0' < "$directory_manifest" | wc -c)
    if (( directory_count > 0 )); then
        xargs -0 -r rmdir --ignore-fail-on-non-empty -- < "$directory_manifest" 2>> "$LOG_FILE" || true
        while IFS= read -r -d $'\0' dir_path; do
            [[ -d "$dir_path" ]] && remaining_count=$((remaining_count + 1))
        done < "$directory_manifest"
    fi
    rm -f -- "$directory_manifest"
    log_info "Empty directory cleanup complete: root = [$source_dir], removed = [$((directory_count - remaining_count))], remaining = [$remaining_count]"
}

cleanup_visual_source_directory() {
    local source_dir=$1
    local target_class=$2
    local allow_full_candidate_ratio=${3:-false}
    local cleanup_scanned_count=0
    local cleanup_removed_tree_count=0
    local cleanup_removed_stale_count=0
    local relative_path
    local cleanup_manifest
    local cleanup_total_count=0
    local cleanup_candidate_count=0

    if [[ "$target_class" != "removable" || "$source_dir" != *"/visual/"* ]]; then
        return 0
    fi

    if [[ ! -d "$source_dir" ]]; then
        return 0
    fi
    if ! $TIME_TRUSTED; then
        log_warn "Skip visual source retention because time is untrusted: [$source_dir]"
        return 0
    fi

    log_info "Visual cleanup start: source = [$source_dir]"
    cleanup_manifest=$(mktemp "$STATE_DIR/visual_cleanup.XXXXXX") ||
        fail_now "failed to allocate visual cleanup manifest"
    if ! enumerate_visual_cleanup_directories_for_source "$source_dir" > "$cleanup_manifest"; then
        rm -f -- "$cleanup_manifest"
        fail_now "failed to enumerate visual cleanup directories: [$source_dir]"
    fi

    while IFS= read -r -d $'\0' dir_path; do
        cleanup_total_count=$((cleanup_total_count + 1))
        relative_path="${dir_path#"$source_dir"}"
        if should_delete_directory_tree_for_source "$source_dir" "$dir_path" "$relative_path"; then
            cleanup_candidate_count=$((cleanup_candidate_count + 1))
        elif should_prune_stale_directory_for_source "$source_dir" "$dir_path" "$relative_path" &&
             is_directory_tree_stale "$dir_path" "$VISUAL_STALE_DIRECTORY_DAYS"; then
            cleanup_candidate_count=$((cleanup_candidate_count + 1))
        fi
    done < "$cleanup_manifest"
    enforce_retention_tree_candidate_limit \
        "$cleanup_total_count" "$cleanup_candidate_count" "visual source $source_dir" \
        "$allow_full_candidate_ratio"

    while IFS= read -r -d $'\0' dir_path; do
        cleanup_scanned_count=$((cleanup_scanned_count + 1))
        relative_path="${dir_path#"$source_dir"}"
        if should_delete_directory_tree_for_source "$source_dir" "$dir_path" "$relative_path"; then
            if $DRY_RUN; then
                log_info "[DRY-RUN] Would remove visual directory tree: [$dir_path]"
                continue
            fi
            if safe_remove_retention_tree "$source_dir" "$dir_path"; then
                cleanup_removed_tree_count=$((cleanup_removed_tree_count + 1))
                log_warn "Removed visual directory tree: [$dir_path]"
            fi
            if [[ "$VISUAL_CLEANUP_PROGRESS_INTERVAL" -gt 0 ]] && (( cleanup_scanned_count % VISUAL_CLEANUP_PROGRESS_INTERVAL == 0 )); then
                log_info "Visual cleanup progress: source = [$source_dir], scanned_dirs = [$cleanup_scanned_count], removed_trees = [$cleanup_removed_tree_count], removed_stale = [$cleanup_removed_stale_count]"
            fi
            continue
        fi

        if should_prune_stale_directory_for_source "$source_dir" "$dir_path" "$relative_path"; then
            if is_directory_tree_stale "$dir_path" "$VISUAL_STALE_DIRECTORY_DAYS"; then
                if $DRY_RUN; then
                    log_info "[DRY-RUN] Would remove stale visual directory tree: [$dir_path]"
                    continue
                fi
                if safe_remove_retention_tree "$source_dir" "$dir_path"; then
                    cleanup_removed_stale_count=$((cleanup_removed_stale_count + 1))
                    log_warn "Removed stale non-whitelist visual directory: [$dir_path]"
                fi
            fi
        fi

        if [[ "$VISUAL_CLEANUP_PROGRESS_INTERVAL" -gt 0 ]] && (( cleanup_scanned_count % VISUAL_CLEANUP_PROGRESS_INTERVAL == 0 )); then
            log_info "Visual cleanup progress: source = [$source_dir], scanned_dirs = [$cleanup_scanned_count], removed_trees = [$cleanup_removed_tree_count], removed_stale = [$cleanup_removed_stale_count]"
        fi
    done < "$cleanup_manifest"

    rm -f -- "$cleanup_manifest"
    log_info "Visual cleanup complete: source = [$source_dir], scanned_dirs = [$cleanup_scanned_count], removed_trees = [$cleanup_removed_tree_count], removed_stale = [$cleanup_removed_stale_count]"
    cleanup_empty_directories "$source_dir"
}


# ======================
# IPC/本机磁盘路径: 目录结构同步 + 逐文件复制
# ======================
ensure_directory_structure() {
    local source_dir=$1
    local target_dir=$2
    local directory_manifest
    local subdir
    local relative_path
    local target_subdir

    if [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]]; then
        IPC_COPY_STAGE=scan_directories
        IPC_COPY_CURRENT=$source_dir
        log_ipc_copy_progress true
    fi
    directory_manifest=$(mktemp "$STATE_DIR/source_directories.XXXXXX") ||
        fail_now "failed to allocate source directory manifest"
    if ! find "$source_dir" -type d -print0 > "$directory_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$directory_manifest"
        fail_now "failed to enumerate source directory structure: [$source_dir]"
    fi

    if [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]]; then
        IPC_COPY_STAGE=prepare_directories
        log_ipc_copy_progress true
    fi
    while IFS= read -r -d $'\0' subdir; do
        if [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]]; then
            IPC_COPY_DIRS=$((IPC_COPY_DIRS + 1))
            IPC_COPY_CURRENT=$subdir
            log_ipc_copy_progress false
        fi
        relative_path=${subdir#"$source_dir"}
        relative_path=${relative_path#/}

        if [[ -n "$relative_path" ]]; then
            if ! should_sync_directory_for_source "$source_dir" "$subdir" "$relative_path"; then
                continue
            fi

            target_subdir="$target_dir/$relative_path"
            if [[ ! -d "$target_subdir" ]]; then
                if $DRY_RUN; then
                    log_info "[DRY-RUN] Would create directory: [$target_subdir]"
                else
                    if ! mkdir -p "$target_subdir" 2>> "$LOG_FILE"; then
                        rm -f -- "$directory_manifest"
                        fail_now "failed to create directory: [$target_subdir]"
                    fi
                    if [[ "${IPC_COPY_PROGRESS_ACTIVE:-false}" == true ]]; then
                        IPC_COPY_DIRS_CREATED=$((IPC_COPY_DIRS_CREATED + 1))
                    fi
                fi
            fi
        fi
    done < "$directory_manifest"
    rm -f -- "$directory_manifest"
}

move_files_with_copy() {
    local source_dir=$1
    local target_dir=$2
    local target_class=$3
    local target_root=${TARGET_ROOTS[$target_class]}
    local fast_skipped_count=0
    local IPC_HISTORY_READER_SCOPE=false
    local IPC_COPY_PROGRESS_ACTIVE=false
    local IPC_COPY_INTERVAL=${IPC_COPY_PROGRESS_SECONDS:-10}
    local IPC_COPY_STARTED=$SECONDS IPC_COPY_LAST_LOG=$SECONDS
    local IPC_COPY_STAGE=prepare IPC_COPY_CURRENT="$source_dir"
    local IPC_COPY_SCANNED=0 IPC_COPY_COPIED=0 IPC_COPY_MATCHED=0
    local IPC_COPY_DIRS=0 IPC_COPY_DIRS_CREATED=0
    local IPC_COPY_TOTAL=${IPC_PREFLIGHT_SOURCE_COUNTS[$source_dir]:-unknown}
    local IPC_COPY_CONFLICT_START=$CONFLICT_TOTAL
    local IPC_COPY_REQUEST_START=$IPC_HISTORY_REQUESTS
    local IPC_COPY_READER_BACKEND=stat
    if [[ "$target_class" == ipc ]]; then
        if [[ ! "$IPC_COPY_INTERVAL" =~ ^(0|[1-9][0-9]{0,3})$ ]] || (( IPC_COPY_INTERVAL > 3600 )); then
            log_warn "Invalid IPC_COPY_PROGRESS_SECONDS; using 10 seconds." || true
            IPC_COPY_INTERVAL=10
        fi
        (( IPC_COPY_INTERVAL == 0 )) || IPC_COPY_PROGRESS_ACTIVE=true
    fi

    if [[ ! -d "$source_dir" ]]; then
        fail_now "source directory does not exist: $source_dir"
    fi

    check_target_ready "$target_class" "$target_root"
    ensure_directory_structure "$source_dir" "$target_dir"

    if [[ "$target_class" == ipc ]] && ! $DRY_RUN; then
        IPC_HISTORY_READER_SCOPE=true
        if start_ipc_history_reader; then IPC_COPY_READER_BACKEND=worker; fi
    fi
    local source_manifest
    if [[ "$target_class" == "ipc" &&
          -f "${IPC_PREFLIGHT_SOURCE_MANIFESTS[$source_dir]:-}" ]]; then
        source_manifest=${IPC_PREFLIGHT_SOURCE_MANIFESTS[$source_dir]}
    else
        source_manifest=$(mktemp "$STATE_DIR/copy_source_files.XXXXXX") ||
            fail_now "failed to allocate copy source manifest"
        if ! find "$source_dir" -type f -print0 > "$source_manifest" 2>> "$LOG_FILE"; then
            rm -f -- "$source_manifest"
            fail_now "failed to enumerate source files: [$source_dir]"
        fi
    fi

    IPC_COPY_STAGE=history_check
    log_ipc_copy_progress true
    while IFS= read -r -d $'\0' file; do
        if [[ "$target_class" == ipc ]]; then
            IPC_COPY_SCANNED=$((IPC_COPY_SCANNED + 1))
            IPC_COPY_STAGE=history_check
            IPC_COPY_CURRENT=$file
            log_ipc_copy_progress false
        fi
        local filename
        local relative_path="${file#"$source_dir"}"
        local target_subdir="$target_dir"
        local target_file
        local temp_file
        local copy_error_file
        local copy_error
        local file_class
        local file_size
        local source_hash
        local temp_hash

        relative_path=${relative_path#/}
        filename=${file##*/}

        if ! should_transfer_file_for_source "$source_dir" "$file" "$relative_path"; then
            continue
        fi

        if [[ "$relative_path" == */* ]]; then
            local file_subdir
            file_subdir=${relative_path%/*}
            target_subdir="$target_dir/$file_subdir"
        fi

        if is_recent_protected_log_file "$source_dir" "$filename"; then
            log_info "Skipping protected recent log file: [$file]"
            append_ledger_record "skipped_recent_log" "$file" "" "log" "today_or_yesterday_log_is_skipped" ||
                fail_now "failed to buffer skipped log record"
            continue
        fi

        target_file="$target_subdir/$filename"
        classify_file_to_result "$target_file"
        file_class=$FILE_CLASS_RESULT

        if $DRY_RUN; then
            log_info "[DRY-RUN] Would copy, hash-verify and commit backup: [$file] -> [$target_file]"
            continue
        fi

        if files_equivalent_for_class "$file" "$target_file" "$target_class"; then
            if $FILES_EQUIVALENT_FAST_PATH &&
               [[ -z "${IPC_VERIFIED_THIS_RUN[$file]+x}" ]]; then
                mark_source_backed_up "$file"
                fast_skipped_count=$((fast_skipped_count + 1))
                IPC_FAST_SKIP_TOTAL=$((IPC_FAST_SKIP_TOTAL + 1))
                continue
            fi
            IPC_COPY_MATCHED=$((IPC_COPY_MATCHED + 1))
            log_info "Target already exists and matches source: [$target_file]"
            append_ledger_record "already_exists" "$file" "$target_file" "$file_class" "target already matches source" ||
                fail_now "failed to buffer existing target record"
            remove_source_after_record "$file" "$target_file" "$file_class" "$target_class"
            continue
        fi

        if [[ -e "$target_file" || -L "$target_file" ]]; then
            record_collision "$source_dir" "$file" "$target_file" "$file_class"
            if ! quarantine_conflicting_source "$source_dir" "$file" "$target_file" "$file_class" "$target_class"; then
                append_ledger_record "conflict_quarantine_failed" "$file" "$target_file" "$file_class" "source retained because quarantine failed" ||
                    fail_now "failed to buffer conflict quarantine failure"
            fi
            continue
        fi

        if [[ -z "${TARGET_SPACE_PREFLIGHTED[$target_class:$target_root]+x}" ]]; then
            file_size=$(get_file_size_bytes "$file")
            [[ "$file_size" =~ ^[0-9]+$ ]] ||
                fail_now "failed to read source file size before copy: [$file]"
            ensure_space_for_bytes "$target_class" "$target_root" "$file_size"
        fi

        if ! mkdir -p "$target_subdir" 2>> "$LOG_FILE"; then
            fail_now "failed to create target subdir before copy: [$target_subdir]"
        fi

        prepare_copy_temp_path_to_result "$target_file" ||
            fail_now "failed to select temporary copy path: [$target_file]"
        temp_file=$COPY_TEMP_PATH_RESULT
        copy_error_file=$(mktemp "$STATE_DIR/cp_stderr.XXXXXX") || fail_now "failed to allocate copy error temp file"

        if should_preserve_copy_metadata_for_class "$target_class"; then
            run_interruptible_command cp --reflink=auto -p -- \
                "$file" "$temp_file" 2>"$copy_error_file"
        else
            run_interruptible_command cp --reflink=auto -- \
                "$file" "$temp_file" 2>"$copy_error_file"
        fi

        if [[ $? -ne 0 ]]; then
            copy_error=$(tr '\n' ' ' < "$copy_error_file")
            rm -f -- "$copy_error_file"
            append_ledger_record "copy_failed" "$file" "$temp_file" "$file_class" "failed to copy source to temp file"
            log_copy_failure_details "$file" "$temp_file" "$target_file" "$copy_error"
            rm -f -- "$temp_file" 2>> "$LOG_FILE"
            fail_now "failed to copy source file to temp target: $(quote_path_for_log "$file")"
        fi
        rm -f -- "$copy_error_file"

        calculate_sha256_to_result "$file" ||
            fail_now "failed to hash source after copy: [$file]"
        source_hash=$SHA256_RESULT
        calculate_sha256_to_result "$temp_file" ||
            fail_now "failed to hash temporary copy: [$temp_file]"
        temp_hash=$SHA256_RESULT
        if [[ "$source_hash" != "$temp_hash" ]]; then
            rm -f -- "$temp_file" 2>> "$LOG_FILE"
            append_ledger_record "verify_failed" "$file" "$temp_file" "$file_class" "temp file hash mismatch"
            fail_now "verification failed after copy: $file"
        fi

        if mv -n -- "$temp_file" "$target_file" 2>> "$LOG_FILE" &&
           [[ ! -e "$temp_file" && -f "$target_file" ]]; then
            IPC_COPY_COPIED=$((IPC_COPY_COPIED + 1))
            log_info "Copied and committed: [$file] ---> [$target_file]"
            remove_source_after_record "$file" "$target_file" "$file_class" "$target_class" "$source_hash"
        else
            rm -f -- "$temp_file" 2>> "$LOG_FILE"
            if [[ -e "$target_file" || -L "$target_file" ]]; then
                if files_equivalent_for_class "$file" "$target_file" "$target_class"; then
                    append_ledger_record "already_exists_after_race" "$file" "$target_file" "$file_class" "target appeared during copy and matches source" ||
                        fail_now "failed to buffer raced target record"
                    remove_source_after_record "$file" "$target_file" "$file_class" "$target_class"
                    continue
                fi
                record_collision "$source_dir" "$file" "$target_file" "$file_class"
                if ! quarantine_conflicting_source "$source_dir" "$file" "$target_file" "$file_class" "$target_class"; then
                    append_ledger_record "conflict_quarantine_failed" "$file" "$target_file" "$file_class" "source retained because quarantine failed after commit race" ||
                        fail_now "failed to buffer raced conflict quarantine failure"
                fi
                continue
            fi
            append_ledger_record "rename_failed" "$file" "$target_file" "$file_class" "failed to atomically rename temp file without overwrite"
            fail_now "failed to commit temp file to final target: [$target_file]"
        fi
    done < "$source_manifest"
    if [[ "$target_class" == ipc ]]; then stop_ipc_history_reader || true; fi
    IPC_COPY_STAGE=directory_complete
    IPC_COPY_CURRENT=$source_dir
    log_ipc_copy_progress true
    rm -f -- "$source_manifest"
    unset 'IPC_PREFLIGHT_SOURCE_MANIFESTS[$source_dir]'
    unset 'IPC_PREFLIGHT_SOURCE_COUNTS[$source_dir]'
    if (( fast_skipped_count > 0 )); then
        log_info "IPC verified-index fast path: source = [$source_dir], unchanged_files = [$fast_skipped_count]"
    fi
}


# ======================
# Arm/可移动介质路径: rsync 批量迁移
# ======================
build_existing_target_relative_index() {
    local target_dir=$1
    local index_name=$2
    local target_class=$3
    local relative_path
    local target_manifest
    local -n existing_target_index_ref=$index_name

    if [[ ! -d "$target_dir" ]]; then
        return 0
    fi

    # 说明:
    # 1. 这里先一次性把目标端已有文件的相对路径建成内存索引
    # 2. 后续扫描源文件时, 只有当相对路径命中该索引, 才继续做等价性判定
    # 3. 这样可以避免"目标端大部分文件都不存在"时, 仍然为每个候选文件单独执行
    #    per-file privilege and stat probes.
    target_manifest=$(mktemp "$STATE_DIR/target_index.XXXXXX") ||
        fail_now "failed to allocate target index manifest"
    if ! find "$target_dir" \( -type f -o -type l \) -printf '%P\0' > "$target_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$target_manifest"
        fail_now "target index scan failed: [$target_dir]"
    fi

    while IFS= read -r -d $'\0' relative_path; do
        existing_target_index_ref["exact:$relative_path"]="$relative_path"
        if [[ "${TARGET_CASE_INSENSITIVE[$target_class]:-false}" == "true" ]]; then
            existing_target_index_ref["fold:${relative_path,,}"]="$relative_path"
        fi
    done < "$target_manifest"
    rm -f -- "$target_manifest"
}

build_rsync_transfer_list() {
    local source_dir=$1
    local target_dir=$2
    local target_class=$3
    local list_file=$4
    local scanned_count=0
    local selected_count=0
    local source_manifest
    local exact_key
    local fold_key
    local existing_relative
    declare -A existing_target_index=()
    declare -A selected_casefold_index=()

    : > "$list_file"
    log_info "Starting scan for rsync transfer list: [$source_dir]"
    build_existing_target_relative_index "$target_dir" existing_target_index "$target_class"

    source_manifest=$(mktemp "$STATE_DIR/rsync_source_scan.XXXXXX") ||
        fail_now "failed to allocate rsync source scan manifest"
    if declare -F enumerate_transfer_files_for_source >/dev/null 2>&1; then
        if ! enumerate_transfer_files_for_source "$source_dir" > "$source_manifest"; then
            rm -f -- "$source_manifest"
            fail_now "source transfer scan failed: [$source_dir]"
        fi
    elif ! find "$source_dir" -type f -print0 > "$source_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$source_manifest"
        fail_now "source transfer scan failed: [$source_dir]"
    fi

    while IFS= read -r -d $'\0' file; do
        local filename
        local relative_path="${file#"$source_dir"}"
        local target_file
        local file_class

        relative_path=${relative_path#/}
        scanned_count=$((scanned_count + 1))
        if (( RSYNC_SCAN_PROGRESS_INTERVAL > 0 && scanned_count % RSYNC_SCAN_PROGRESS_INTERVAL == 0 )); then
            log_info "Rsync scan progress: source = [$source_dir], scanned = [${scanned_count}], selected = [${selected_count}]"
        fi

        filename=${file##*/}
        if ! should_transfer_file_for_source "$source_dir" "$file" "$relative_path"; then
            continue
        fi

        if is_recent_protected_log_file "$source_dir" "$filename"; then
            log_info "Skipping protected recent log file: [$file]"
            append_ledger_record "skipped_recent_log" "$file" "" "log" "today_or_yesterday_log_is_skipped" ||
                fail_now "failed to buffer skipped log record"
            continue
        fi

        target_file="$target_dir/$relative_path"
        classify_file_to_result "$target_file"
        file_class=$FILE_CLASS_RESULT

        exact_key="exact:$relative_path"
        if [[ -n "${existing_target_index[$exact_key]+x}" ]]; then
            if files_equivalent_for_class "$file" "$target_file" "$target_class"; then
                log_info "Target already exists and matches source: [$target_file]"
                append_ledger_record "already_exists" "$file" "$target_file" "$file_class" "target already matches source" ||
                    fail_now "failed to buffer existing target record"
                remove_source_after_record "$file" "$target_file" "$file_class" "$target_class"
                continue
            fi

            record_collision "$source_dir" "$file" "$target_file" "$file_class"
            continue
        fi

        if [[ "${TARGET_CASE_INSENSITIVE[$target_class]:-false}" == "true" ]]; then
            fold_key="fold:${relative_path,,}"
            if [[ -n "${existing_target_index[$fold_key]+x}" ]]; then
                existing_relative=${existing_target_index[$fold_key]}
                record_collision "$source_dir" "$file" "$target_dir/$existing_relative" "$file_class"
                append_ledger_record "casefold_collision" "$file" "$target_dir/$existing_relative" "$file_class" "path aliases an existing target on a case-insensitive filesystem" ||
                    fail_now "failed to buffer case-fold collision record"
                continue
            fi
            if [[ -n "${selected_casefold_index[${relative_path,,}]+x}" ]]; then
                existing_relative=${selected_casefold_index[${relative_path,,}]}
                record_collision "$source_dir" "$file" "$target_dir/$existing_relative" "$file_class"
                append_ledger_record "casefold_collision" "$file" "$target_dir/$existing_relative" "$file_class" "two source paths alias on a case-insensitive filesystem" ||
                    fail_now "failed to buffer source case-fold collision record"
                continue
            fi
            selected_casefold_index["${relative_path,,}"]="$relative_path"
        fi

        printf '%s\0' "$relative_path" >> "$list_file"
        selected_count=$((selected_count + 1))
    done < "$source_manifest"

    rm -f -- "$source_manifest"
    log_info "Completed rsync transfer list scan: source = [$source_dir], scanned = [${scanned_count}], selected = [${selected_count}]"
}

prepare_rsync_transfer_plan() {
    local source_dir=$1
    local target_dir=$2
    local target_class=$3
    local list_file
    local required_bytes

    list_file=$(mktemp "$STATE_DIR/rsync_files.XXXXXX") ||
        fail_now "failed to allocate rsync transfer list"
    build_rsync_transfer_list "$source_dir" "$target_dir" "$target_class" "$list_file"
    required_bytes=$(sum_nul_relative_file_list_bytes "$source_dir" "$list_file") ||
        fail_now "failed to calculate actual pending transfer bytes: [$source_dir]"

    PREPARED_RSYNC_LISTS["$source_dir"]="$list_file"
    PREPARED_RSYNC_BYTES["$source_dir"]="$required_bytes"
    log_info "Prepared rsync plan: source = [$source_dir], pending_bytes = [$required_bytes]"
}

move_files_with_rsync() {
    local source_dir=$1
    local target_dir=$2
    local target_class=$3
    local target_root=${TARGET_ROOTS[$target_class]}
    local list_file=${PREPARED_RSYNC_LISTS[$source_dir]:-}
    local rsync_status
    local transfer_itemized_file
    local verify_itemized_file
    local selected_count
    local transferred_count
    local fallback_hash_verification=false
    local verify_failed=0
    local transfer_start_seconds
    local transfer_duration_seconds
    local verify_start_seconds
    local verify_duration_seconds
    local manifest_start_seconds
    local manifest_duration_seconds
    local pending_bytes=${PREPARED_RSYNC_BYTES[$source_dir]:-0}
    local transfer_rate_mib="0.00"
    local -a rsync_extra_args=()

    if [[ ! -d "$source_dir" ]]; then
        fail_now "source directory does not exist: $source_dir"
    fi

    check_target_ready "$target_class" "$target_root"

    if [[ -z "$list_file" ]]; then
        prepare_rsync_transfer_plan "$source_dir" "$target_dir" "$target_class"
        list_file=${PREPARED_RSYNC_LISTS[$source_dir]}
    fi

    if [[ ! -s "$list_file" ]]; then
        return 0
    fi

    if $DRY_RUN; then
        selected_count=$(tr -cd '\0' < "$list_file" | wc -c)
        log_info "[DRY-RUN] Would rsync $selected_count files: [$source_dir] ---> [$target_dir]"
        return 0
    fi

    check_interruption_requested
    mkdir -p "$target_dir" 2>> "$LOG_FILE" || fail_now "failed to create rsync target dir: [$target_dir]"
    transfer_itemized_file=$(mktemp "$STATE_DIR/rsync_transferred.XXXXXX") ||
        fail_now "failed to allocate rsync transfer result"

    if declare -F get_rsync_transfer_extra_args_for_source >/dev/null 2>&1; then
        get_rsync_transfer_extra_args_for_source "$source_dir"
        rsync_extra_args=("${RSYNC_TRANSFER_EXTRA_ARGS_RESULT[@]}")
    fi

    # --ignore-existing is the no-overwrite boundary. Rsync's reconstruction
    # checksum validates the bytes written by each successful transfer.
    get_monotonic_seconds
    transfer_start_seconds=$MONOTONIC_SECONDS_RESULT
    run_interruptible_command rsync -rlt --ignore-existing \
        "${rsync_extra_args[@]}" \
        --modify-window="$RSYNC_MODIFY_WINDOW" \
        --files-from="$list_file" --from0 \
        --itemize-changes --out-format='%i' \
        "$source_dir/" "$target_dir/" > "$transfer_itemized_file" 2>> "$LOG_FILE"
    rsync_status=$?
    if [[ $rsync_status -ne 0 ]]; then
        rm -f -- "$transfer_itemized_file"
        fail_now "rsync failed for source directory: [$source_dir], exit_code = [$rsync_status]"
    fi
    get_monotonic_seconds
    transfer_duration_seconds=$((MONOTONIC_SECONDS_RESULT - transfer_start_seconds))
    if (( transfer_duration_seconds > 0 && pending_bytes > 0 )); then
        transfer_rate_mib=$(awk -v bytes="$pending_bytes" -v seconds="$transfer_duration_seconds" \
            'BEGIN {printf "%.2f", bytes / 1048576 / seconds}')
    fi
    log_info "Rsync transfer timing: source = [$source_dir], pending_bytes = [$pending_bytes], duration_s = [$transfer_duration_seconds], apparent_mib_s = [$transfer_rate_mib]"

    selected_count=$(tr -cd '\0' < "$list_file" | wc -c)
    transferred_count=$(grep -c '^>f' "$transfer_itemized_file" 2>/dev/null || true)
    rm -f -- "$transfer_itemized_file"

    verify_itemized_file=$(mktemp "$STATE_DIR/rsync_verify.XXXXXX") ||
        fail_now "failed to allocate rsync verification result"
    get_monotonic_seconds
    verify_start_seconds=$MONOTONIC_SECONDS_RESULT
    run_interruptible_command rsync -rltni --no-implied-dirs \
        --modify-window="$RSYNC_MODIFY_WINDOW" \
        --files-from="$list_file" --from0 \
        --out-format='%i %n%L' \
        "$source_dir/" "$target_dir/" > "$verify_itemized_file" 2>> "$LOG_FILE"
    rsync_status=$?
    if [[ $rsync_status -ne 0 ]]; then
        rm -f -- "$verify_itemized_file"
        fail_now "batch rsync verification failed: [$source_dir], exit_code = [$rsync_status]"
    fi
    get_monotonic_seconds
    verify_duration_seconds=$((MONOTONIC_SECONDS_RESULT - verify_start_seconds))
    log_info "Rsync dry-run verification timing: source = [$source_dir], duration_s = [$verify_duration_seconds]"

    if [[ -s "$verify_itemized_file" || "$transferred_count" -ne "$selected_count" ]]; then
        fallback_hash_verification=true
        log_warn "Rsync reported a skipped or changed item; hashing this exceptional batch: source = [$source_dir], selected = [$selected_count], transferred = [$transferred_count]"
    fi
    rm -f -- "$verify_itemized_file"

    get_monotonic_seconds
    manifest_start_seconds=$MONOTONIC_SECONDS_RESULT
    while IFS= read -r -d $'\0' relative_path; do
        local source_file="${source_dir%/}/$relative_path"
        local target_file="$target_dir/$relative_path"
        local file_class

        classify_file_to_result "$target_file"
        file_class=$FILE_CLASS_RESULT
        if $fallback_hash_verification &&
           ! files_equivalent_for_class "$source_file" "$target_file" "$target_class"; then
            record_collision "$source_dir" "$source_file" "$target_file" "$file_class"
            append_ledger_record "verify_failed" "$source_file" "$target_file" "$file_class" "target mismatch after rsync" ||
                fail_now "failed to buffer rsync verification failure"
            verify_failed=1
            continue
        fi
        remove_source_after_record "$source_file" "$target_file" "$file_class" "$target_class"
    done < "$list_file"
    get_monotonic_seconds
    manifest_duration_seconds=$((MONOTONIC_SECONDS_RESULT - manifest_start_seconds))
    log_info "Rsync source-manifest timing: source = [$source_dir], records = [$selected_count], duration_s = [$manifest_duration_seconds]"

    flush_ledger_buffer || fail_now "failed to flush rsync batch ledger"
    if (( verify_failed != 0 )); then
        log_error "One or more rsync files failed fallback hash verification; destructive cleanup remains blocked."
    else
        log_info "Rsync batch verify complete: source = [$source_dir], verified = [$selected_count]"
    fi
}


# ======================
# 清理旧文件
# ======================
get_ipc_retention_mtime_to_result() {
    local file_path=$1 status
    FILE_MTIME_EPOCH_RESULT=""
    if [[ "${IPC_RETENTION_READER_SCOPE:-false}" == true &&
          "${IPC_RETENTION_READER_ENABLED:-true}" == true ]] && ! $DRY_RUN; then
        if ! $IPC_HISTORY_ACTIVE && ! $IPC_HISTORY_DISABLED; then
            if start_ipc_history_reader mtime; then IPC_RETENTION_OWNS_READER=true; fi
        fi
        if $IPC_HISTORY_ACTIVE && [[ "$IPC_HISTORY_MODE" == mtime ]]; then
            if query_ipc_metadata "$file_path" mtime; then
                FILE_MTIME_EPOCH_RESULT=$IPC_HISTORY_VALUE_RESULT
                return 0
            else status=$?; fi
            # An explicit MISS is not a deletion candidate, just like failed
            # stat. Transport/protocol faults must retry the original stat.
            (( status != 1 )) || return 1
            disable_ipc_history_reader retention_request_failed
        fi
    fi
    check_interruption_requested
    FILE_MTIME_EPOCH_RESULT=$(get_file_mtime_epoch "$file_path")
}

log_ipc_retention_progress() {
    local force=${1:-false}
    [[ "${IPC_RETENTION_PROGRESS_ACTIVE:-false}" == true ]] || return 0
    if [[ "$force" != true ]] && (( SECONDS - IPC_RETENTION_LAST_LOG < IPC_RETENTION_INTERVAL )); then return 0; fi
    IPC_RETENTION_LAST_LOG=$SECONDS
    log_info "IPC retention progress: stage = [$IPC_RETENTION_STAGE], scope = [$cleanup_scope], directory = [$target_dir], scanned = [$IPC_RETENTION_SCANNED], candidates = [$IPC_RETENTION_CANDIDATES], removed = [$removed_count], reader_requests = [$((IPC_HISTORY_REQUESTS - IPC_RETENTION_REQUEST_START))], duration_s = [$((SECONDS - IPC_RETENTION_STARTED))], current = [$IPC_RETENTION_CURRENT]" || true
}

clean_old_files() {
    local target_dir=$1
    local target_class=$2
    local cleanup_scope=${3:-target}
    local old_file_manifest
    local removed_count=0
    local IPC_RETENTION_READER_SCOPE=false IPC_RETENTION_OWNS_READER=false
    local IPC_RETENTION_PROGRESS_ACTIVE=false
    local IPC_RETENTION_INTERVAL=${IPC_RETENTION_PROGRESS_SECONDS:-10}
    local IPC_RETENTION_STARTED=$SECONDS IPC_RETENTION_LAST_LOG=$SECONDS
    local IPC_RETENTION_SCANNED=0 IPC_RETENTION_CANDIDATES=0
    local IPC_RETENTION_REQUEST_START=$IPC_HISTORY_REQUESTS
    local IPC_RETENTION_STAGE=scan_files IPC_RETENTION_CURRENT="$target_dir"

    if [[ ! -d "$target_dir" ]]; then
        log_warn "Skip cleanup because directory does not exist: [$target_dir]"
        return 0
    fi

    if ! $TIME_TRUSTED; then
        log_warn "Skip retention cleanup because time is untrusted: directory = [$target_dir], reason = [$TIME_TRUST_DETAIL]"
        return 0
    fi

    if [[ "$target_class" == ipc ]]; then
        IPC_RETENTION_READER_SCOPE=true
        if [[ ! "$IPC_RETENTION_INTERVAL" =~ ^(0|[1-9][0-9]{0,3})$ ]] || (( IPC_RETENTION_INTERVAL > 3600 )); then
            log_warn "Invalid IPC_RETENTION_PROGRESS_SECONDS; using 10 seconds." || true
            IPC_RETENTION_INTERVAL=10
        fi
        (( IPC_RETENTION_INTERVAL == 0 )) || IPC_RETENTION_PROGRESS_ACTIVE=true
    fi
    log_ipc_retention_progress true
    cleanup_old_directories_for_target "$target_dir" "$target_class"

    old_file_manifest=$(mktemp "$STATE_DIR/old_files.XXXXXX") ||
        fail_now "failed to allocate old file cleanup manifest"
    if ! enumerate_old_files_for_target "$target_dir" "$target_class" > "$old_file_manifest"; then
        rm -f -- "$old_file_manifest"
        fail_now "failed to enumerate retention candidates: [$target_dir]"
    fi

    IPC_RETENTION_STAGE=check_files
    while IFS= read -r -d $'\0' file; do
        local filename
        local file_date
        local file_mtime_epoch
        local retention_days
        local cutoff
        local cutoff_epoch
        local file_class
        local should_delete=false

        check_interruption_requested
        if [[ "$target_class" == ipc ]]; then
            IPC_RETENTION_SCANNED=$((IPC_RETENTION_SCANNED + 1))
            IPC_RETENTION_CURRENT=$file
            log_ipc_retention_progress false
        fi
        if [[ "$cleanup_scope" == "source" ]] && ! is_source_backed_up "$file"; then
            continue
        fi
        if is_path_protected_from_retention "$file"; then
            continue
        fi

        filename=${file##*/}
        classify_file_to_result "$file"
        file_class=$FILE_CLASS_RESULT
        get_retention_days_for_file_class_to_result "$file_class" "$target_class"
        retention_days=$RETENTION_DAYS_RESULT
        get_cutoff_date_cached "$retention_days"
        cutoff=$CUTOFF_DATE_RESULT
        cutoff_epoch=$CUTOFF_EPOCH_RESULT
        extract_date_from_filename_to_result "$filename"
        file_date=$EXTRACTED_DATE_RESULT

        if [[ -n "$file_date" ]]; then
            if [[ "$file_date" < "$cutoff" ]]; then
                should_delete=true
            fi
        else
            if [[ "$target_class" == ipc ]]; then
                get_ipc_retention_mtime_to_result "$file" || true
                file_mtime_epoch=$FILE_MTIME_EPOCH_RESULT
            else
                file_mtime_epoch=$(get_file_mtime_epoch "$file")
            fi
            if [[ "$file_mtime_epoch" =~ ^[0-9]+$ ]] &&
               (( file_mtime_epoch < cutoff_epoch )); then
                should_delete=true
            fi
        fi

        if ! $should_delete; then
            continue
        fi

        IPC_RETENTION_CANDIDATES=$((IPC_RETENTION_CANDIDATES + 1))
        if $DRY_RUN; then
            log_info "[DRY-RUN] Would delete [${file_class}] file from ${cleanup_scope} retention: [$file]"
            continue
        fi

        if ! safe_remove_retention_file "$target_dir" "$file"; then
            rm -f -- "$old_file_manifest"
            fail_now "failed to delete ${cleanup_scope} retention file: [$file]"
        fi

        if [[ "$cleanup_scope" == "source" ]]; then
            append_ledger_record "source_deleted_retention" "$file" "" "$file_class" "deleted after verified backup by retention ${retention_days} days" ||
                fail_now "failed to buffer source retention deletion"
            if [[ "$target_class" == "ipc" ]]; then
                remove_ipc_verified_file "$file"
            fi
        else
            append_ledger_record "target_deleted" "" "$file" "$file_class" "deleted by retention ${retention_days} days" ||
                fail_now "failed to buffer target retention deletion"
        fi
        removed_count=$((removed_count + 1))
    done < "$old_file_manifest"

    if $IPC_RETENTION_OWNS_READER; then stop_ipc_history_reader || true; fi
    IPC_RETENTION_STAGE=complete
    log_ipc_retention_progress true
    rm -f -- "$old_file_manifest"
    flush_ledger_buffer || fail_now "failed to flush retention ledger"
    log_info "Retention cleanup complete: scope = [$cleanup_scope], directory = [$target_dir], removed = [$removed_count]"
}

clean_ipc_conflict_files() {
    local conflict_root=${1:-${IPC_CONFLICT_ROOT:-}}
    local retention_days=${2:-${IPC_CONFLICT_RETENTION_DAYS:-90}}
    local conflict_manifest
    local conflict_file
    local removed_count=0

    [[ -n "$conflict_root" && -d "$conflict_root" ]] || return 0
    if ! $TIME_TRUSTED; then
        log_warn "Skip conflict retention because time is untrusted: [$conflict_root]"
        return 0
    fi

    get_cutoff_date_cached "$retention_days"
    conflict_manifest=$(mktemp "$STATE_DIR/conflict_retention.XXXXXX") ||
        fail_now "failed to allocate conflict retention manifest"
    if ! find "$conflict_root" -type f ! -newermt "@$CUTOFF_EPOCH_RESULT" -print0 \
        > "$conflict_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$conflict_manifest"
        fail_now "failed to enumerate conflict retention candidates: [$conflict_root]"
    fi

    while IFS= read -r -d $'\0' conflict_file; do
        check_interruption_requested
        if $DRY_RUN; then
            log_info "[DRY-RUN] Would delete quarantined conflict older than $retention_days days: [$conflict_file]"
            continue
        fi
        safe_remove_retention_file "$conflict_root" "$conflict_file" ||
            fail_now "failed to delete expired quarantined conflict: [$conflict_file]"
        append_ledger_record "conflict_deleted" "" "$conflict_file" "conflict" "deleted by independent conflict retention ${retention_days} days" ||
            fail_now "failed to buffer conflict retention deletion"
        removed_count=$((removed_count + 1))
    done < "$conflict_manifest"

    rm -f -- "$conflict_manifest"
    cleanup_empty_directories "$conflict_root"
    flush_ledger_buffer || fail_now "failed to flush conflict retention ledger"
    log_info "Conflict retention complete: directory = [$conflict_root], removed = [$removed_count]"
}
