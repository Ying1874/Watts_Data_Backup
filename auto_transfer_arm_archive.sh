#!/bin/bash

# ARM visual hourly archive primitives.
#
# The module deliberately owns only ARM-specific archive actions. The ARM flow
# decides when to plan, transfer and promote bundles; common continues to own
# locking, interruption, hashing, ledgers and deferred source deletion.

ARM_VISUAL_ARCHIVE_PENDING_BYTES=0
ARM_VISUAL_ARCHIVE_PLAN_READY=false
ARM_VISUAL_ARCHIVE_PLAN_BLOCKED=false
ARM_VISUAL_ARCHIVE_PLAN_BLOCK_DETAIL=""
ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE=""
ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE=""
ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS=0
ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS=0
ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS=0
ARM_VISUAL_ARCHIVE_STAGE_TOTAL_MS=0
ARM_VISUAL_ARCHIVE_DURABLE_START_MS=0
declare -a ARM_VISUAL_ARCHIVE_BUCKETS=()
declare -a ARM_VISUAL_ARCHIVE_RUNTIME_TEMP_DIRS=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_FILES=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_TASK_ROWS=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_DATE=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_HOUR=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_TASK_COUNT=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_BYTES=()
declare -A ARM_VISUAL_ARCHIVE_BUCKET_BUNDLE=()
declare -A ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT=()
declare -A ARM_VISUAL_ARCHIVE_TARGET_ARCHIVE=()
declare -A ARM_VISUAL_ARCHIVE_TARGET_HASH=()
declare -A ARM_VISUAL_ARCHIVE_REQUIRED_TARGETS=()

arm_visual_archive_enabled() {
    [[ "${ARM_VISUAL_TRANSFER_MODE:-hourly_archive}" == "hourly_archive" ]]
}

validate_arm_visual_archive_configuration() {
    local timezone=${ARM_VISUAL_ARCHIVE_TIMEZONE:-Asia/Shanghai}
    local max_tasks=${ARM_VISUAL_ARCHIVE_MAX_TASKS_PER_HOUR:-120}
    local include_current_day=${ARM_VISUAL_ARCHIVE_INCLUDE_CURRENT_DAY:-false}
    local format=${ARM_VISUAL_ARCHIVE_FORMAT:-tar}
    local tar_blocking_factor=${ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR:-1024}
    local zstd_level=${ARM_VISUAL_ARCHIVE_ZSTD_LEVEL:-1}
    local zstd_threads=${ARM_VISUAL_ARCHIVE_ZSTD_THREADS:-1}
    local date_probe

    case "${ARM_VISUAL_TRANSFER_MODE:-hourly_archive}" in
        raw|hourly_archive) ;;
        *)
            fail_now "ARM_VISUAL_TRANSFER_MODE must be raw or hourly_archive"
            ;;
    esac
    arm_visual_archive_enabled || return 0

    if [[ "${REMOVABLE_FS_TYPE:-}" != "ext4" ]]; then
        fail_now "hourly visual archives require the approved ext4 removable filesystem boundary"
    fi
    case "$format" in
        tar|tar.zst|zip-store|zip-deflate) ;;
        *)
            fail_now "ARM_VISUAL_ARCHIVE_FORMAT must be tar, tar.zst, zip-store or zip-deflate"
            ;;
    esac
    if [[ ! "$max_tasks" =~ ^[0-9]+$ ]] || (( max_tasks < 1 || max_tasks > 1000 )); then
        fail_now "ARM_VISUAL_ARCHIVE_MAX_TASKS_PER_HOUR must be an integer between 1 and 1000"
    fi
    if [[ ! "$tar_blocking_factor" =~ ^[0-9]+$ ]] ||
       (( tar_blocking_factor < 1 || tar_blocking_factor > 131072 )); then
        fail_now "ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR must be an integer between 1 and 131072"
    fi
    case "$include_current_day" in
        true|false) ;;
        *)
            fail_now "ARM_VISUAL_ARCHIVE_INCLUDE_CURRENT_DAY must be true or false"
            ;;
    esac
    if [[ ! "$zstd_level" =~ ^[0-9]+$ ]] || (( zstd_level < 1 || zstd_level > 19 )); then
        fail_now "ARM_VISUAL_ARCHIVE_ZSTD_LEVEL must be an integer between 1 and 19"
    fi
    if [[ ! "$zstd_threads" =~ ^[0-9]+$ ]] || (( zstd_threads < 1 || zstd_threads > 4 )); then
        fail_now "ARM_VISUAL_ARCHIVE_ZSTD_THREADS must be an integer between 1 and 4"
    fi

    date_probe=$(TZ="$timezone" date -d '@0' +%Y_%m%d 2>/dev/null) ||
        fail_now "ARM_VISUAL_ARCHIVE_TIMEZONE is not usable by date: [$timezone]"
    [[ -n "$date_probe" ]] ||
        fail_now "ARM_VISUAL_ARCHIVE_TIMEZONE produced an empty date: [$timezone]"

    require_commands sha256sum
    case "$format" in
        tar)
            require_commands tar
            ;;
        tar.zst)
            require_commands tar zstd
            ;;
        zip-store|zip-deflate)
            require_commands unzip zip
            ;;
    esac
}

arm_visual_archive_extension() {
    case "${ARM_VISUAL_ARCHIVE_FORMAT:-tar}" in
        tar) echo "tar" ;;
        tar.zst) echo "tar.zst" ;;
        zip-store|zip-deflate) echo "zip" ;;
    esac
}

reset_arm_visual_archive_plan() {
    local path

    for path in "${ARM_VISUAL_ARCHIVE_BUCKET_FILES[@]}" \
                "${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[@]}" \
                "${ARM_VISUAL_ARCHIVE_BUCKET_TASK_ROWS[@]}"; do
        [[ -n "$path" ]] && rm -f -- "$path"
    done
    [[ -n "$ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE" ]] &&
        rm -f -- "$ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE"
    [[ -n "$ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE" ]] &&
        rm -f -- "$ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE"
    ARM_VISUAL_ARCHIVE_PENDING_BYTES=0
    ARM_VISUAL_ARCHIVE_PLAN_READY=false
    ARM_VISUAL_ARCHIVE_PLAN_BLOCKED=false
    ARM_VISUAL_ARCHIVE_PLAN_BLOCK_DETAIL=""
    ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE=""
    ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE=""
    ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS=0
    ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS=0
    ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS=0
    ARM_VISUAL_ARCHIVE_STAGE_TOTAL_MS=0
    ARM_VISUAL_ARCHIVE_DURABLE_START_MS=0
    ARM_VISUAL_ARCHIVE_BUCKETS=()
    ARM_VISUAL_ARCHIVE_BUCKET_FILES=()
    ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT=()
    ARM_VISUAL_ARCHIVE_BUCKET_TASK_ROWS=()
    ARM_VISUAL_ARCHIVE_BUCKET_DATE=()
    ARM_VISUAL_ARCHIVE_BUCKET_HOUR=()
    ARM_VISUAL_ARCHIVE_BUCKET_TASK_COUNT=()
    ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT=()
    ARM_VISUAL_ARCHIVE_BUCKET_BYTES=()
    ARM_VISUAL_ARCHIVE_BUCKET_BUNDLE=()
    ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT=()
    ARM_VISUAL_ARCHIVE_TARGET_ARCHIVE=()
    ARM_VISUAL_ARCHIVE_TARGET_HASH=()
    ARM_VISUAL_ARCHIVE_REQUIRED_TARGETS=()
}

cleanup_arm_visual_archive_runtime() {
    local temp_dir
    local target_root=${TARGET_ROOTS[removable]:-}
    local resolved_target
    local resolved_temp

    [[ -n "$target_root" ]] || return 0
    resolved_target=$(realpath -m "$target_root") || return 1
    for temp_dir in "${ARM_VISUAL_ARCHIVE_RUNTIME_TEMP_DIRS[@]}"; do
        [[ -n "$temp_dir" && -e "$temp_dir" ]] || continue
        resolved_temp=$(realpath -m "$temp_dir") || continue
        if [[ "$resolved_temp" != "$resolved_target/"* ||
              "${resolved_temp##*/}" != .*"$TMP_SUFFIX" ]]; then
            log_error "Refused unsafe visual archive temp cleanup: [$resolved_temp]"
            continue
        fi
        rm -rf -- "$resolved_temp" 2>> "$LOG_FILE" || {
            log_error "Failed to remove current-run visual archive temp directory: [$resolved_temp]"
            continue
        }
        log_warn "Removed current-run visual archive temp directory: [$resolved_temp]"
    done
    ARM_VISUAL_ARCHIVE_RUNTIME_TEMP_DIRS=()
    reset_arm_visual_archive_plan
}

cleanup_orphan_arm_visual_archive_directories() {
    local target_dir=$1
    local orphan_manifest
    local temp_dir
    local temp_mtime
    local resolved_target
    local resolved_temp

    $DRY_RUN && return 0
    [[ -d "$target_dir" ]] || return 0
    resolved_target=$(realpath -m "$target_dir") ||
        fail_now "failed to resolve visual archive target for orphan cleanup: [$target_dir]"
    orphan_manifest=$(mktemp "$STATE_DIR/archive_orphan_dirs.XXXXXX") ||
        fail_now "failed to allocate visual archive orphan directory manifest"
    if ! find "$target_dir" -mindepth 2 -maxdepth 2 -type d \
        -name ".hour_*${TMP_SUFFIX}" -print0 > "$orphan_manifest" 2>> "$LOG_FILE"; then
        rm -f -- "$orphan_manifest"
        fail_now "failed to enumerate orphan visual archive directories: [$target_dir]"
    fi

    while IFS= read -r -d $'\0' temp_dir; do
        check_interruption_requested
        temp_mtime=$(get_file_mtime_epoch "$temp_dir")
        [[ "$temp_mtime" =~ ^[0-9]+$ &&
           "$temp_mtime" -lt "$RUN_START_EPOCH" ]] || continue
        resolved_temp=$(realpath -m "$temp_dir") ||
            fail_now "failed to resolve orphan visual archive directory: [$temp_dir]"
        if [[ "$resolved_temp" != "$resolved_target/"* ||
              "${resolved_temp##*/}" != .hour_*"$TMP_SUFFIX" ]]; then
            rm -f -- "$orphan_manifest"
            fail_now "refused unsafe orphan visual archive cleanup: [$resolved_temp]"
        fi
        rm -rf -- "$resolved_temp" 2>> "$LOG_FILE" ||
            fail_now "failed to remove orphan visual archive directory: [$resolved_temp]"
        [[ ! -e "$resolved_temp" && ! -L "$resolved_temp" ]] ||
            fail_now "orphan visual archive directory remained after deletion: [$resolved_temp]"
        log_warn "Removed orphan visual archive staging directory: [$resolved_temp]"
    done < "$orphan_manifest"
    rm -f -- "$orphan_manifest"
}

load_existing_arm_visual_archive_index() {
    local target_dir=$1
    local source_date_dirs=$2
    local manifest_list
    local source_date_dir
    local manifest_path
    local manifest_hash_path
    local manifest_hash_output
    local expected_manifest_hash
    local actual_manifest_hash
    local bundle_dir
    local date_dir
    local date_name
    local record_type
    local field1
    local field2
    local field3
    local field4
    local field5
    local field6
    local archive_name=""
    local archive_hash=""
    local archive_path=""
    local member_key
    local fingerprint
    local version_seen=false
    local archive_seen=false

    [[ -d "$target_dir" ]] || return 0
    manifest_list=$(mktemp "$STATE_DIR/archive_target_manifests.XXXXXX") ||
        fail_now "failed to allocate visual archive target manifest list"
    : > "$manifest_list"
    while IFS= read -r -d $'\0' source_date_dir; do
        date_name=${source_date_dir##*/}
        arm_visual_is_date_directory_name "$date_name" || continue
        [[ -d "$target_dir/$date_name" ]] || continue
        if ! find "$target_dir/$date_name" -mindepth 2 -maxdepth 2 -type f \
            -path "$target_dir/$date_name/hour_*/manifest.tsv" -print0 \
            >> "$manifest_list" 2>> "$LOG_FILE"; then
            rm -f -- "$manifest_list"
            fail_now "visual archive target index scan failed: [$target_dir/$date_name]"
        fi
    done < "$source_date_dirs"

    while IFS= read -r -d $'\0' manifest_path; do
        bundle_dir=${manifest_path%/*}
        date_dir=${bundle_dir%/*}
        date_name=${date_dir##*/}
        archive_name=""
        archive_hash=""
        archive_path=""
        version_seen=false
        archive_seen=false

        manifest_hash_path="$bundle_dir/manifest.sha256"
        [[ -f "$manifest_hash_path" ]] || {
            rm -f -- "$manifest_list"
            fail_now "visual archive manifest checksum is missing: [$bundle_dir]"
        }
        IFS=' ' read -r expected_manifest_hash _ < "$manifest_hash_path" || true
        [[ "$expected_manifest_hash" =~ ^[0-9a-f]{64}$ ]] || {
            rm -f -- "$manifest_list"
            fail_now "malformed visual archive manifest checksum: [$manifest_hash_path]"
        }
        manifest_hash_output=$(mktemp "$STATE_DIR/archive_manifest_hash.XXXXXX") ||
            fail_now "failed to allocate visual archive manifest checksum output"
        sha256sum "$manifest_path" > "$manifest_hash_output" || {
            rm -f -- "$manifest_hash_output" "$manifest_list"
            fail_now "failed to hash visual archive manifest: [$manifest_path]"
        }
        IFS=' ' read -r actual_manifest_hash _ < "$manifest_hash_output" || true
        rm -f -- "$manifest_hash_output"
        [[ "$actual_manifest_hash" == "$expected_manifest_hash" ]] || {
            rm -f -- "$manifest_list"
            fail_now "visual archive manifest checksum mismatch: [$manifest_path]"
        }

        while IFS=$'\t' read -r record_type field1 field2 field3 field4 field5 field6; do
            case "$record_type" in
                V)
                    if $version_seen || [[ "$field1" != "1" ]]; then
                        rm -f -- "$manifest_list"
                        fail_now "unsupported visual archive manifest version: [$manifest_path]"
                    fi
                    version_seen=true
                    ;;
                A)
                    if ! $version_seen || $archive_seen; then
                        rm -f -- "$manifest_list"
                        fail_now "malformed visual archive manifest record order: [$manifest_path]"
                    fi
                    archive_name=$field1
                    archive_hash=$field2
                    if [[ -z "$archive_name" || "$archive_name" == */* ||
                          ! "$archive_hash" =~ ^[0-9a-f]{64}$ ||
                          ! "$field3" =~ ^(tar|tar[.]zst|zip-store|zip-deflate)$ ||
                          ! "$field4" =~ ^[0-9]{13}$ ||
                          "$field5" != "$date_name" ||
                          ! "$field6" =~ ^[0-9]{2}$ ]]; then
                        rm -f -- "$manifest_list"
                        fail_now "malformed visual archive manifest header: [$manifest_path]"
                    fi
                    archive_path="$bundle_dir/$archive_name"
                    [[ -f "$archive_path" ]] || {
                        rm -f -- "$manifest_list"
                        fail_now "visual archive bundle is incomplete: [$bundle_dir]"
                    }
                    if [[ -n "${ARM_VISUAL_ARCHIVE_TARGET_HASH[$archive_path]+x}" &&
                          "${ARM_VISUAL_ARCHIVE_TARGET_HASH[$archive_path]}" != "$archive_hash" ]]; then
                        rm -f -- "$manifest_list"
                        fail_now "conflicting target archive hashes in manifests: [$archive_path]"
                    fi
                    ARM_VISUAL_ARCHIVE_TARGET_HASH["$archive_path"]=$archive_hash
                    archive_seen=true
                    ;;
                T)
                    if ! $archive_seen ||
                       [[ ! "$field1" =~ ^[0-9]{13}$ ||
                          -z "$field2" || -z "$field3" ||
                          ! "$field4" =~ ^[0-9]+$ ||
                          ! "$field5" =~ ^[0-9]+$ ]]; then
                        rm -f -- "$manifest_list"
                        fail_now "malformed visual archive task record: [$manifest_path]"
                    fi
                    ;;
                F)
                    $archive_seen || {
                        rm -f -- "$manifest_list"
                        fail_now "visual archive member appeared before archive header: [$manifest_path]"
                    }
                    if [[ -z "$field1" || "$field1" == /* || "$field1" == ../* ||
                          "$field1" == */../* || "$field1" == *$'\t'* ||
                          "$field1" == *$'\n'* || "$field1" == *$'\r'* ||
                          ! "$field2" =~ ^[0-9]+$ ||
                          ! "$field3" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                        rm -f -- "$manifest_list"
                        fail_now "malformed visual archive member record: [$manifest_path]"
                    fi
                    member_key="$date_name/$field1"
                    fingerprint="$field2:$field3"
                    if [[ -n "${ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT[$member_key]+x}" &&
                          "${ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT[$member_key]}" != "$fingerprint" ]]; then
                        rm -f -- "$manifest_list"
                        fail_now "target archive index contains conflicting member fingerprints: [$member_key]"
                    fi
                    ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT["$member_key"]=$fingerprint
                    ARM_VISUAL_ARCHIVE_TARGET_ARCHIVE["$member_key"]=$archive_path
                    ;;
                *)
                    rm -f -- "$manifest_list"
                    fail_now "unknown visual archive manifest record: [$manifest_path]"
                    ;;
            esac
        done < "$manifest_path"

        if ! $version_seen || ! $archive_seen || [[ -z "$archive_path" ]]; then
            rm -f -- "$manifest_list"
            fail_now "visual archive manifest has no archive header: [$manifest_path]"
        fi
    done < "$manifest_list"
    rm -f -- "$manifest_list"
}

arm_visual_archive_get_bucket_files() {
    local bucket=$1
    local files_path=${ARM_VISUAL_ARCHIVE_BUCKET_FILES[$bucket]:-}
    local snapshot_path=${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[$bucket]:-}

    if [[ -z "$files_path" ]]; then
        files_path=$(mktemp "$STATE_DIR/archive_${bucket}_files.XXXXXX") ||
            fail_now "failed to allocate hourly archive file list"
        snapshot_path=$(mktemp "$STATE_DIR/archive_${bucket}_snapshot.XXXXXX") ||
            fail_now "failed to allocate hourly archive snapshot"
        ARM_VISUAL_ARCHIVE_BUCKET_FILES["$bucket"]=$files_path
        ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT["$bucket"]=$snapshot_path
        ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT["$bucket"]=0
        ARM_VISUAL_ARCHIVE_BUCKET_BYTES["$bucket"]=0
    fi
}

prepare_arm_visual_archive_plan() {
    local source_dir=$1
    local target_dir=$2
    local timezone=${ARM_VISUAL_ARCHIVE_TIMEZONE:-Asia/Shanghai}
    local include_current_day=${ARM_VISUAL_ARCHIVE_INCLUDE_CURRENT_DAY:-false}
    local max_tasks=${ARM_VISUAL_ARCHIVE_MAX_TASKS_PER_HOUR:-120}
    local date_dirs
    local date_dir
    local date_name
    local scan_file
    local relative_path
    local task_relative_path
    local file_size
    local file_mtime
    local task_name
    local timestamp_ms
    local timestamp_seconds
    local bucket
    local bucket_epoch
    local next_date_name
    local bucket_date_hour
    local bucket_date
    local bucket_hour
    local source_file
    local target_key
    local fingerprint
    local target_archive
    local legacy_target
    local file_class
    local tasks_seen_file
    local task_key
    local task_rows
    local task_count
    local task_bytes
    local plan_hash_file
    local plan_hash
    local extension
    local bundle_name
    local estimated_bytes
    local bucket_order_all
    local bucket_has_new_files
    local archive_today
    local archive_window_cutoff
    local normalized_date_name
    declare -A all_buckets=()
    declare -A task_seen=()
    declare -A task_timestamp=()
    declare -A task_vin=()
    declare -A new_task_seen=()
    declare -A new_task_file_count=()
    declare -A new_task_total_bytes=()

    reset_arm_visual_archive_plan
    validate_arm_visual_archive_configuration

    ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE=$(mktemp "$STATE_DIR/archive_staged.XXXXXX") ||
        fail_now "failed to allocate staged visual archive ledger"
    ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE=$(mktemp "$STATE_DIR/archive_covered.XXXXXX") ||
        fail_now "failed to allocate covered visual source ledger"

    # Hour selection and the decision to delete a successfully archived source
    # both depend on wall-clock time. Keep logs and other sources transferable,
    # but fail closed for visual archives when the time trust boundary is not
    # satisfied.
    if ! $TIME_TRUSTED; then
        ARM_VISUAL_ARCHIVE_PLAN_READY=true
        ARM_VISUAL_ARCHIVE_PLAN_BLOCKED=true
        ARM_VISUAL_ARCHIVE_PLAN_BLOCK_DETAIL="visual_archive_time_untrusted:$TIME_TRUST_DETAIL"
        log_error "Skipping visual hourly archives and blocking this round's source cleanup because time is untrusted: reason = [$TIME_TRUST_DETAIL]"
        return 0
    fi

    archive_today=$(TZ="$timezone" date -d "@$RUN_REFERENCE_EPOCH" +%Y_%m%d 2>/dev/null) ||
        fail_now "failed to calculate archive-local current date"
    archive_window_cutoff=$(TZ="$timezone" date \
        -d "@$((RUN_REFERENCE_EPOCH - VISUAL_DATE_WINDOW_DAYS * 86400))" \
        +%Y_%m%d 2>/dev/null) ||
        fail_now "failed to calculate archive-local visual window cutoff"
    date_dirs=$(mktemp "$STATE_DIR/archive_date_dirs.XXXXXX") ||
        fail_now "failed to allocate visual archive date directory list"

    if ! find "$source_dir" -mindepth 1 -maxdepth 1 -type d -print0 \
        > "$date_dirs" 2>> "$LOG_FILE"; then
        rm -f -- "$date_dirs"
        fail_now "failed to enumerate visual archive date directories: [$source_dir]"
    fi
    load_existing_arm_visual_archive_index "$target_dir" "$date_dirs"

    while IFS= read -r -d $'\0' date_dir; do
        check_interruption_requested
        date_name=${date_dir##*/}
        arm_visual_is_date_directory_name "$date_name" || continue
        normalized_date_name=$(TZ="$timezone" date \
            -d "${date_name:0:4}-${date_name:5:2}-${date_name:7:2}" \
            +%Y_%m%d 2>/dev/null) ||
            fail_now "failed to validate visual archive source date: [$date_name]"
        [[ "$normalized_date_name" == "$date_name" ]] ||
            fail_now "invalid visual archive source date: [$date_name]"
        if [[ "$date_name" < "$archive_window_cutoff" ]]; then
            continue
        fi
        if [[ "$date_name" > "$archive_today" ]]; then
            log_warn "Skipping future visual date from hourly archive planning: [$date_dir]"
            continue
        fi
        if [[ "$include_current_day" != "true" &&
              "$date_name" == "$archive_today" ]]; then
            log_info "Skipping current visual date from hourly archive planning: [$date_dir]"
            continue
        fi

        scan_file=$(mktemp "$STATE_DIR/archive_date_scan.XXXXXX") ||
            fail_now "failed to allocate visual archive date scan"
        if ! find "$date_dir" \
            \( -path "$date_dir/*/ori/*" -o -path "$date_dir/*/global/ori/*" \) \
            -type f -printf '%P\0%s\0%T@\0' > "$scan_file" 2>> "$LOG_FILE"; then
            rm -f -- "$scan_file" "$date_dirs"
            fail_now "failed to scan visual archive source date: [$date_dir]"
        fi

        while IFS= read -r -d $'\0' relative_path &&
              IFS= read -r -d $'\0' file_size &&
              IFS= read -r -d $'\0' file_mtime; do
            task_name=${relative_path%%/*}
            if [[ "$task_name" == "$relative_path" ||
                  ! "$task_name" =~ ^([0-9]{13})-(.+)$ ]]; then
                rm -f -- "$scan_file" "$date_dirs"
                fail_now "visual task directory must be <13-digit-epoch-ms>-<vin>: [$date_dir/$task_name]"
            fi
            task_relative_path=${relative_path#*/}
            case "$task_relative_path" in
                ori/*|global/ori/*) ;;
                *)
                    # GNU find -path globs can match '/'. Keep the actual
                    # whitelist boundary explicit instead of trusting only
                    # the coarse candidate scan pattern.
                    continue
                    ;;
            esac
            if [[ "$relative_path" == *$'\t'* || "$relative_path" == *$'\n'* ||
                  "$relative_path" == *$'\r'* ]]; then
                rm -f -- "$scan_file" "$date_dirs"
                fail_now "visual archive path contains a TSV-unsafe character: [$relative_path]"
            fi
            timestamp_ms=${BASH_REMATCH[1]}
            timestamp_seconds=$((timestamp_ms / 1000))
            bucket=$((timestamp_seconds / 3600 * 3600))
            if [[ "$include_current_day" == "true" &&
                  "$bucket" -ge "$((RUN_REFERENCE_EPOCH / 3600 * 3600))" ]]; then
                continue
            fi
            # Keep files from different physical date directories separate,
            # even when a task timestamp spans midnight.
            bucket="$date_name:$bucket"
            all_buckets["$bucket"]=1
            ARM_VISUAL_ARCHIVE_BUCKET_DATE["$bucket"]=$date_name

            task_key="$bucket|$task_name"
            if [[ -z "${task_seen[$task_key]+x}" ]]; then
                task_seen["$task_key"]=1
                ARM_VISUAL_ARCHIVE_BUCKET_TASK_COUNT["$bucket"]=$(( ${ARM_VISUAL_ARCHIVE_BUCKET_TASK_COUNT[$bucket]:-0} + 1 ))
                task_timestamp["$task_key"]=$timestamp_ms
                task_vin["$task_key"]=${BASH_REMATCH[2]}
            fi

            source_file="$date_dir/$relative_path"
            target_key="$date_name/$relative_path"
            fingerprint="$file_size:$file_mtime"
            if [[ -n "${ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT[$target_key]+x}" ]]; then
                target_archive=${ARM_VISUAL_ARCHIVE_TARGET_ARCHIVE[$target_key]}
                if [[ "${ARM_VISUAL_ARCHIVE_TARGET_FINGERPRINT[$target_key]}" != "$fingerprint" ]]; then
                    classify_file_to_result "$source_file"
                    file_class=$FILE_CLASS_RESULT
                    record_collision "$source_dir" "$source_file" "$target_archive" "$file_class"
                    continue
                fi
                classify_file_to_result "$source_file"
                file_class=$FILE_CLASS_RESULT
                printf '%s\0%s\0%s\0' "$source_file" "$target_archive" "$file_class" \
                    >> "$ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE" ||
                    fail_now "failed to append covered visual source record"
                ARM_VISUAL_ARCHIVE_REQUIRED_TARGETS["$target_archive"]=${ARM_VISUAL_ARCHIVE_TARGET_HASH[$target_archive]}
                continue
            fi

            # Upgrade compatibility: a previous raw-file release may already
            # have copied this visual member. Hash only these exceptional
            # existing targets, keep an equivalent raw backup as-is, and never
            # overwrite a conflicting one.
            legacy_target="$target_dir/$target_key"
            if [[ -e "$legacy_target" || -L "$legacy_target" ]]; then
                classify_file_to_result "$source_file"
                file_class=$FILE_CLASS_RESULT
                if [[ -f "$legacy_target" && ! -L "$legacy_target" ]] &&
                   files_equivalent_for_class "$source_file" "$legacy_target" "removable"; then
                    printf '%s\0%s\0%s\0' "$source_file" "$legacy_target" "$file_class" \
                        >> "$ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE" ||
                        fail_now "failed to append legacy covered visual source record"
                else
                    record_collision "$source_dir" "$source_file" "$legacy_target" "$file_class"
                fi
                continue
            fi

            arm_visual_archive_get_bucket_files "$bucket"
            if [[ -z "${new_task_seen[$task_key]+x}" ]]; then
                new_task_seen["$task_key"]=1
                new_task_file_count["$task_key"]=0
                new_task_total_bytes["$task_key"]=0
            fi
            new_task_file_count["$task_key"]=$((new_task_file_count[$task_key] + 1))
            new_task_total_bytes["$task_key"]=$((new_task_total_bytes[$task_key] + file_size))
            printf '%s\0' "$relative_path" >> "${ARM_VISUAL_ARCHIVE_BUCKET_FILES[$bucket]}" ||
                fail_now "failed to append hourly archive file list"
            printf '%s\t%s\t%s\n' "$relative_path" "$file_size" "$file_mtime" \
                >> "${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[$bucket]}" ||
                fail_now "failed to append hourly archive source snapshot"
            ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT["$bucket"]=$((ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT[$bucket] + 1))
            ARM_VISUAL_ARCHIVE_BUCKET_BYTES["$bucket"]=$((ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket] + file_size))
        done < "$scan_file"
        rm -f -- "$scan_file"
    done < "$date_dirs"
    rm -f -- "$date_dirs"

    bucket_order_all=$(mktemp "$STATE_DIR/archive_all_buckets.XXXXXX") ||
        fail_now "failed to allocate visual archive bucket validation order"
    for bucket in "${!all_buckets[@]}"; do
        printf '%s\n' "$bucket" >> "$bucket_order_all"
    done
    sort -t ":" -k1,1 -k2,2n -o "$bucket_order_all" "$bucket_order_all" ||
        fail_now "failed to sort visual archive buckets"

    extension=$(arm_visual_archive_extension)
    while IFS= read -r bucket; do
        [[ -n "$bucket" ]] || continue
        bucket_epoch=${bucket#*:}
        bucket_date_hour=$(TZ="$timezone" date -d "@$bucket_epoch" '+%Y_%m%d %H' 2>/dev/null) ||
            fail_now "failed to convert visual archive hour bucket: [$bucket]"
        bucket_date=${bucket_date_hour%% *}
        bucket_hour=${bucket_date_hour#* }
        if [[ "$bucket_date" != "${ARM_VISUAL_ARCHIVE_BUCKET_DATE[$bucket]}" ]]; then
            # A task started before midnight may save its remaining files in
            # the next day's directory. Retain the real parent and task hour.
            next_date_name=$(TZ="$timezone" date \
                -d "${bucket_date:0:4}-${bucket_date:5:2}-${bucket_date:7:2} +1 day" \
                +%Y_%m%d 2>/dev/null) ||
                fail_now "failed to calculate next date for visual task: [$bucket_date]"
            [[ "$next_date_name" == "${ARM_VISUAL_ARCHIVE_BUCKET_DATE[$bucket]}" ]] ||
                fail_now "visual task timestamp date does not match parent directory: bucket = [$bucket_date_hour], parent = [${ARM_VISUAL_ARCHIVE_BUCKET_DATE[$bucket]}]"
            log_warn "Visual task crossed midnight: task_hour = [$bucket_date_hour], source_date = [${ARM_VISUAL_ARCHIVE_BUCKET_DATE[$bucket]}]; archiving from the actual source date directory"
        fi
        bucket_date=${ARM_VISUAL_ARCHIVE_BUCKET_DATE[$bucket]}
        ARM_VISUAL_ARCHIVE_BUCKET_HOUR["$bucket"]=$bucket_hour
        task_count=${ARM_VISUAL_ARCHIVE_BUCKET_TASK_COUNT[$bucket]:-0}
        if (( task_count > max_tasks )); then
            fail_now "visual hourly task limit exceeded: date = [$bucket_date], hour = [$bucket_hour], tasks = [$task_count], limit = [$max_tasks]"
        fi

        bucket_has_new_files=${ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT[$bucket]:-0}
        (( bucket_has_new_files > 0 )) || continue
        sort -z -o "${ARM_VISUAL_ARCHIVE_BUCKET_FILES[$bucket]}" \
            "${ARM_VISUAL_ARCHIVE_BUCKET_FILES[$bucket]}" ||
            fail_now "failed to sort hourly archive file list"
        sort -o "${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[$bucket]}" \
            "${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[$bucket]}" ||
            fail_now "failed to sort hourly archive source snapshot"

        task_rows=$(mktemp "$STATE_DIR/archive_${bucket}_tasks.XXXXXX") ||
            fail_now "failed to allocate hourly archive task rows"
        for task_key in "${!new_task_seen[@]}"; do
            [[ "$task_key" == "$bucket|"* ]] || continue
            task_name=${task_key#*|}
            printf 'T\t%s\t%s\t%s\t%s\t%s\n' \
                "${task_timestamp[$task_key]}" "${task_vin[$task_key]}" "$task_name" \
                "${new_task_file_count[$task_key]}" "${new_task_total_bytes[$task_key]}" >> "$task_rows" ||
                fail_now "failed to append hourly archive task row"
        done
        sort -t $'\t' -k2,2n -o "$task_rows" "$task_rows" ||
            fail_now "failed to sort hourly archive task rows"
        ARM_VISUAL_ARCHIVE_BUCKET_TASK_ROWS["$bucket"]=$task_rows

        plan_hash_file=$(mktemp "$STATE_DIR/archive_${bucket}_digest.XXXXXX") ||
            fail_now "failed to allocate hourly archive digest output"
        sha256sum "${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[$bucket]}" > "$plan_hash_file" ||
            fail_now "failed to hash hourly archive source snapshot"
        IFS=' ' read -r plan_hash _ < "$plan_hash_file" || true
        rm -f -- "$plan_hash_file"
        [[ "$plan_hash" =~ ^[0-9a-f]{64}$ ]] ||
            fail_now "invalid hourly archive source snapshot digest"
        bundle_name="hour_${bucket_hour}_$((bucket_epoch * 1000))_${plan_hash:0:16}"
        ARM_VISUAL_ARCHIVE_BUCKET_BUNDLE["$bucket"]=$bundle_name
        ARM_VISUAL_ARCHIVE_BUCKETS+=("$bucket")

        # Reserve one configured tar record for end-of-archive padding instead
        # of retaining the former fixed 4 MiB allowance.
        estimated_bytes=$(( ${ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket]} +
            ${ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT[$bucket]} * 1024 +
            ${ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR:-1024} * 512 ))
        ARM_VISUAL_ARCHIVE_PENDING_BYTES=$((ARM_VISUAL_ARCHIVE_PENDING_BYTES + estimated_bytes))
        log_info "Prepared visual hourly archive: date = [$bucket_date], hour = [$bucket_hour], tasks = [$task_count], files = [${ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT[$bucket]}], source_bytes = [${ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket]}], reserved_output_bytes = [$estimated_bytes], bundle = [$bundle_name], format = [${ARM_VISUAL_ARCHIVE_FORMAT:-tar}]"
    done < "$bucket_order_all"
    rm -f -- "$bucket_order_all"

    ARM_VISUAL_ARCHIVE_PLAN_READY=true
    log_info "Visual hourly archive plan complete: new_buckets = [${#ARM_VISUAL_ARCHIVE_BUCKETS[@]}], pending_output_reservation_bytes = [$ARM_VISUAL_ARCHIVE_PENDING_BYTES]"
}

create_arm_visual_archive_file() {
    local date_dir=$1
    local files_file=$2
    local archive_path=$3
    local format=${ARM_VISUAL_ARCHIVE_FORMAT:-tar}
    local tar_blocking_factor=${ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR:-1024}
    local zstd_level=${ARM_VISUAL_ARCHIVE_ZSTD_LEVEL:-1}
    local zstd_threads=${ARM_VISUAL_ARCHIVE_ZSTD_THREADS:-1}
    local zip_list
    local zip_status

    case "$format" in
        tar)
            run_interruptible_command tar --blocking-factor="$tar_blocking_factor" \
                -C "$date_dir" --null --verbatim-files-from \
                --no-recursion --files-from="$files_file" -cf "$archive_path"
            ;;
        tar.zst)
            run_interruptible_command tar --blocking-factor="$tar_blocking_factor" \
                -C "$date_dir" --null --verbatim-files-from \
                --no-recursion --files-from="$files_file" \
                -I "zstd -q -${zstd_level} -T${zstd_threads}" -cf "$archive_path"
            ;;
        zip-store|zip-deflate)
            zip_list=$(mktemp "$STATE_DIR/archive_zip_list.XXXXXX") ||
                fail_now "failed to allocate zip member list"
            tr '\0' '\n' < "$files_file" > "$zip_list" ||
                fail_now "failed to convert zip member list"
            if [[ "$format" == "zip-store" ]]; then
                run_interruptible_command_in_directory "$date_dir" \
                    zip -q -0 "$archive_path" -@ < "$zip_list"
            else
                run_interruptible_command_in_directory "$date_dir" \
                    zip -q -1 "$archive_path" -@ < "$zip_list"
            fi
            zip_status=$?
            rm -f -- "$zip_list"
            return "$zip_status"
            ;;
    esac
}

verify_arm_visual_archive_file() {
    local archive_path=$1
    local format=${ARM_VISUAL_ARCHIVE_FORMAT:-tar}
    local tar_blocking_factor=${ARM_VISUAL_ARCHIVE_TAR_BLOCKING_FACTOR:-1024}

    case "$format" in
        tar)
            run_interruptible_command tar --blocking-factor="$tar_blocking_factor" \
                -tf "$archive_path" >/dev/null
            ;;
        tar.zst)
            run_interruptible_command tar --blocking-factor="$tar_blocking_factor" \
                -I zstd -tf "$archive_path" >/dev/null
            ;;
        zip-store|zip-deflate)
            run_interruptible_command unzip -tqq "$archive_path" >/dev/null
            ;;
    esac
}

verify_covered_arm_visual_archives() {
    local archive_path
    local expected_hash
    local hash_output
    local actual_hash
    local source_file
    local target_file
    local file_class

    for archive_path in "${!ARM_VISUAL_ARCHIVE_REQUIRED_TARGETS[@]}"; do
        check_interruption_requested
        expected_hash=${ARM_VISUAL_ARCHIVE_REQUIRED_TARGETS[$archive_path]}
        [[ -f "$archive_path" ]] ||
            fail_now "previously committed visual archive is missing: [$archive_path]"
        hash_output=$(mktemp "$STATE_DIR/archive_existing_hash.XXXXXX") ||
            fail_now "failed to allocate existing archive hash output"
        run_interruptible_command sha256sum "$archive_path" > "$hash_output" ||
            fail_now "failed to hash existing visual archive: [$archive_path]"
        IFS=' ' read -r actual_hash _ < "$hash_output" || true
        rm -f -- "$hash_output"
        [[ "$actual_hash" == "$expected_hash" ]] ||
            fail_now "existing visual archive hash mismatch; source files retained: [$archive_path]"
        log_info "Verified existing visual archive for resume: [$archive_path]"
    done

    while IFS= read -r -d $'\0' source_file &&
          IFS= read -r -d $'\0' target_file &&
          IFS= read -r -d $'\0' file_class; do
        remove_source_after_record "$source_file" "$target_file" "$file_class" "removable"
    done < "$ARM_VISUAL_ARCHIVE_COVERED_RECORDS_FILE"
}

transfer_arm_visual_archives() {
    local source_dir=$1
    local target_dir=$2
    local target_root=${TARGET_ROOTS[removable]}
    local extension
    local bucket
    local bucket_epoch
    local date_name
    local date_dir
    local bundle_name
    local final_bundle
    local temp_bundle
    local archive_name
    local archive_path
    local manifest_path
    local manifest_hash_path
    local manifest_hash_output
    local manifest_hash
    local hash_output
    local archive_hash
    local relative_path
    local source_file
    local file_class
    local start_milliseconds
    local duration_milliseconds
    local duration_seconds
    local create_duration_milliseconds
    local create_duration_seconds
    local verify_start_milliseconds
    local verify_duration_milliseconds
    local verify_duration_seconds
    local hash_start_milliseconds
    local hash_duration_milliseconds
    local hash_duration_seconds
    local archive_bytes
    local create_rate_mib="0.00"

    $ARM_VISUAL_ARCHIVE_PLAN_READY ||
        fail_now "visual hourly archive transfer was requested before planning"
    check_target_ready "removable" "$target_root"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create ${#ARM_VISUAL_ARCHIVE_BUCKETS[@]} non-empty visual hourly archives under [$target_dir]"
        return 0
    fi

    verify_covered_arm_visual_archives
    extension=$(arm_visual_archive_extension)
    for bucket in "${ARM_VISUAL_ARCHIVE_BUCKETS[@]}"; do
        check_interruption_requested
        bucket_epoch=${bucket#*:}
        date_name=${ARM_VISUAL_ARCHIVE_BUCKET_DATE[$bucket]}
        date_dir="${source_dir%/}/$date_name"
        bundle_name=${ARM_VISUAL_ARCHIVE_BUCKET_BUNDLE[$bucket]}
        final_bundle="$target_dir/$date_name/$bundle_name"
        temp_bundle="$target_dir/$date_name/.${bundle_name}.${RUN_ID}${TMP_SUFFIX}"
        archive_name="data.$extension"
        archive_path="$temp_bundle/$archive_name"
        manifest_path="$temp_bundle/manifest.tsv"
        manifest_hash_path="$temp_bundle/manifest.sha256"

        if [[ -e "$final_bundle" || -L "$final_bundle" ]]; then
            fail_now "visual archive bundle already exists but was not a verified resume match: [$final_bundle]"
        fi
        mkdir -p "${temp_bundle%/*}" "$temp_bundle" 2>> "$LOG_FILE" ||
            fail_now "failed to create visual archive staging directory: [$temp_bundle]"
        ARM_VISUAL_ARCHIVE_RUNTIME_TEMP_DIRS+=("$temp_bundle")

        get_monotonic_milliseconds
        if (( ARM_VISUAL_ARCHIVE_DURABLE_START_MS == 0 )); then
            ARM_VISUAL_ARCHIVE_DURABLE_START_MS=$MONOTONIC_MILLISECONDS_RESULT
        fi
        start_milliseconds=$MONOTONIC_MILLISECONDS_RESULT
        create_arm_visual_archive_file "$date_dir" \
            "${ARM_VISUAL_ARCHIVE_BUCKET_FILES[$bucket]}" "$archive_path" 2>> "$LOG_FILE" ||
            fail_now "failed to create visual hourly archive: [$archive_path]"
        get_monotonic_milliseconds
        create_duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - start_milliseconds))
        ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS=$((ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS + create_duration_milliseconds))

        verify_start_milliseconds=$MONOTONIC_MILLISECONDS_RESULT
        verify_arm_visual_archive_file "$archive_path" ||
            fail_now "visual hourly archive integrity test failed: [$archive_path]"
        get_monotonic_milliseconds
        verify_duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - verify_start_milliseconds))
        ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS=$((ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS + verify_duration_milliseconds))

        hash_start_milliseconds=$MONOTONIC_MILLISECONDS_RESULT
        hash_output=$(mktemp "$STATE_DIR/archive_new_hash.XXXXXX") ||
            fail_now "failed to allocate new archive hash output"
        run_interruptible_command sha256sum "$archive_path" > "$hash_output" ||
            fail_now "failed to hash new visual archive: [$archive_path]"
        IFS=' ' read -r archive_hash _ < "$hash_output" || true
        rm -f -- "$hash_output"
        [[ "$archive_hash" =~ ^[0-9a-f]{64}$ ]] ||
            fail_now "invalid hash for new visual archive: [$archive_path]"
        get_monotonic_milliseconds
        hash_duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - hash_start_milliseconds))
        ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS=$((ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS + hash_duration_milliseconds))
        archive_bytes=$(stat -c %s "$archive_path") ||
            fail_now "failed to read new visual archive size: [$archive_path]"
        if (( create_duration_milliseconds > 0 &&
              ${ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket]} > 0 )); then
            create_rate_mib=$(awk \
                -v bytes="${ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket]}" \
                -v milliseconds="$create_duration_milliseconds" \
                'BEGIN {printf "%.2f", bytes / 1048576 * 1000 / milliseconds}')
        else
            create_rate_mib="0.00"
        fi

        {
            printf 'V\t1\n'
            printf 'A\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$archive_name" "$archive_hash" "${ARM_VISUAL_ARCHIVE_FORMAT:-tar}" \
                "$((bucket_epoch * 1000))" "$date_name" "${ARM_VISUAL_ARCHIVE_BUCKET_HOUR[$bucket]}"
            cat "${ARM_VISUAL_ARCHIVE_BUCKET_TASK_ROWS[$bucket]}"
            awk -F '\t' '{printf "F\t%s\t%s\t%s\n", $1, $2, $3}' \
                "${ARM_VISUAL_ARCHIVE_BUCKET_SNAPSHOT[$bucket]}"
        } > "$manifest_path" ||
            fail_now "failed to write visual archive manifest: [$manifest_path]"
        manifest_hash_output=$(mktemp "$STATE_DIR/archive_new_manifest_hash.XXXXXX") ||
            fail_now "failed to allocate new archive manifest hash output"
        sha256sum "$manifest_path" > "$manifest_hash_output" ||
            fail_now "failed to hash new visual archive manifest: [$manifest_path]"
        IFS=' ' read -r manifest_hash _ < "$manifest_hash_output" || true
        rm -f -- "$manifest_hash_output"
        [[ "$manifest_hash" =~ ^[0-9a-f]{64}$ ]] ||
            fail_now "invalid hash for new visual archive manifest: [$manifest_path]"
        printf '%s  manifest.tsv\n' "$manifest_hash" > "$manifest_hash_path" ||
            fail_now "failed to write visual archive manifest checksum: [$manifest_hash_path]"

        printf '%s\0%s\0' "$temp_bundle" "$final_bundle" \
            >> "$ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE" ||
            fail_now "failed to record staged visual archive bundle"

        while IFS= read -r -d $'\0' relative_path; do
            source_file="$date_dir/$relative_path"
            classify_file_to_result "$source_file"
            file_class=$FILE_CLASS_RESULT
            remove_source_after_record "$source_file" "$final_bundle/$archive_name" "$file_class" "removable"
        done < "${ARM_VISUAL_ARCHIVE_BUCKET_FILES[$bucket]}"

        get_monotonic_milliseconds
        duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - start_milliseconds))
        ARM_VISUAL_ARCHIVE_STAGE_TOTAL_MS=$((ARM_VISUAL_ARCHIVE_STAGE_TOTAL_MS + duration_milliseconds))
        duration_seconds=$(format_milliseconds_as_seconds "$duration_milliseconds")
        create_duration_seconds=$(format_milliseconds_as_seconds "$create_duration_milliseconds")
        verify_duration_seconds=$(format_milliseconds_as_seconds "$verify_duration_milliseconds")
        hash_duration_seconds=$(format_milliseconds_as_seconds "$hash_duration_milliseconds")
        append_ledger_record "archive_staged" "$date_dir" "$final_bundle/$archive_name" "visual_archive" \
            "hour=${ARM_VISUAL_ARCHIVE_BUCKET_HOUR[$bucket]},files=${ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT[$bucket]},source_bytes=${ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket]},sha256=$archive_hash" ||
            fail_now "failed to buffer visual archive ledger record"
        log_info "Visual hourly archive staged: bundle = [$final_bundle], files = [${ARM_VISUAL_ARCHIVE_BUCKET_FILE_COUNT[$bucket]}], source_bytes = [${ARM_VISUAL_ARCHIVE_BUCKET_BYTES[$bucket]}], archive_bytes = [$archive_bytes], duration_ms = [$duration_milliseconds], duration_s = [$duration_seconds]"
        log_info "Visual archive timing: bundle = [$final_bundle], create_ms = [$create_duration_milliseconds], create_s = [$create_duration_seconds], create_source_mib_s = [$create_rate_mib], integrity_verify_ms = [$verify_duration_milliseconds], integrity_verify_s = [$verify_duration_seconds], sha256_ms = [$hash_duration_milliseconds], sha256_s = [$hash_duration_seconds]"
    done
}

promote_staged_arm_visual_archives() {
    local target_root=${TARGET_ROOTS[removable]}
    local temp_bundle
    local final_bundle
    local promoted=0
    local sync_start_milliseconds
    local first_sync_duration_milliseconds
    local second_sync_duration_milliseconds
    local promote_start_milliseconds
    local promote_duration_milliseconds
    local first_sync_duration_seconds
    local second_sync_duration_seconds
    local promote_duration_seconds
    local persist_sync_milliseconds
    local persist_sync_seconds
    local staging_overhead_milliseconds
    local durable_active_milliseconds
    local durable_total_milliseconds
    local durable_total_seconds
    local archive_create_total_seconds
    local verify_total_seconds
    local hash_total_seconds

    $DRY_RUN && return 0
    [[ -n "$ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE" &&
       -s "$ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE" ]] || return 0

    check_interruption_requested
    log_info "Synchronizing staged visual hourly archives before atomic promotion."
    get_monotonic_milliseconds
    sync_start_milliseconds=$MONOTONIC_MILLISECONDS_RESULT
    sync -f "$target_root" ||
        fail_now "failed to persist staged visual hourly archives"
    get_monotonic_milliseconds
    first_sync_duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - sync_start_milliseconds))
    promote_start_milliseconds=$MONOTONIC_MILLISECONDS_RESULT

    while IFS= read -r -d $'\0' temp_bundle &&
          IFS= read -r -d $'\0' final_bundle; do
        [[ -d "$temp_bundle" ]] ||
            fail_now "staged visual archive directory is missing: [$temp_bundle]"
        if [[ -e "$final_bundle" || -L "$final_bundle" ]]; then
            fail_now "refused to overwrite visual archive bundle during promotion: [$final_bundle]"
        fi
        mv -- "$temp_bundle" "$final_bundle" ||
            fail_now "failed to atomically promote visual archive bundle: [$final_bundle]"
        promoted=$((promoted + 1))
        append_ledger_record "archive_committed" "" "$final_bundle" "visual_archive" \
            "staged bundle atomically promoted before whole-round removable commit" ||
            fail_now "failed to buffer promoted visual archive record"
    done < "$ARM_VISUAL_ARCHIVE_STAGED_RECORDS_FILE"

    get_monotonic_milliseconds
    promote_duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - promote_start_milliseconds))
    sync_start_milliseconds=$MONOTONIC_MILLISECONDS_RESULT
    sync -f "$target_root" ||
        fail_now "failed to persist promoted visual hourly archive directories"
    get_monotonic_milliseconds
    second_sync_duration_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - sync_start_milliseconds))
    ARM_VISUAL_ARCHIVE_RUNTIME_TEMP_DIRS=()

    first_sync_duration_seconds=$(format_milliseconds_as_seconds "$first_sync_duration_milliseconds")
    promote_duration_seconds=$(format_milliseconds_as_seconds "$promote_duration_milliseconds")
    second_sync_duration_seconds=$(format_milliseconds_as_seconds "$second_sync_duration_milliseconds")
    persist_sync_milliseconds=$((first_sync_duration_milliseconds + second_sync_duration_milliseconds))
    persist_sync_seconds=$(format_milliseconds_as_seconds "$persist_sync_milliseconds")
    staging_overhead_milliseconds=$((ARM_VISUAL_ARCHIVE_STAGE_TOTAL_MS -
        ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS -
        ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS -
        ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS))
    (( staging_overhead_milliseconds < 0 )) && staging_overhead_milliseconds=0
    durable_active_milliseconds=$((ARM_VISUAL_ARCHIVE_STAGE_TOTAL_MS +
        first_sync_duration_milliseconds +
        promote_duration_milliseconds +
        second_sync_duration_milliseconds))
    durable_total_milliseconds=$((MONOTONIC_MILLISECONDS_RESULT - ARM_VISUAL_ARCHIVE_DURABLE_START_MS))
    durable_total_seconds=$(format_milliseconds_as_seconds "$durable_total_milliseconds")
    archive_create_total_seconds=$(format_milliseconds_as_seconds "$ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS")
    verify_total_seconds=$(format_milliseconds_as_seconds "$ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS")
    hash_total_seconds=$(format_milliseconds_as_seconds "$ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS")

    log_info "Visual hourly archive promotion complete: bundles = [$promoted], staged_sync_ms = [$first_sync_duration_milliseconds], staged_sync_s = [$first_sync_duration_seconds], rename_ms = [$promote_duration_milliseconds], rename_s = [$promote_duration_seconds], promoted_sync_ms = [$second_sync_duration_milliseconds], promoted_sync_s = [$second_sync_duration_seconds]"
    log_info "Visual archive durable timing summary: bundles = [$promoted], archive_create_ms = [$ARM_VISUAL_ARCHIVE_CREATE_TOTAL_MS], archive_create_s = [$archive_create_total_seconds], integrity_verify_ms = [$ARM_VISUAL_ARCHIVE_VERIFY_TOTAL_MS], integrity_verify_s = [$verify_total_seconds], sha256_ms = [$ARM_VISUAL_ARCHIVE_HASH_TOTAL_MS], sha256_s = [$hash_total_seconds], staging_overhead_ms = [$staging_overhead_milliseconds], persist_sync_ms = [$persist_sync_milliseconds], persist_sync_s = [$persist_sync_seconds], atomic_rename_ms = [$promote_duration_milliseconds], durable_active_ms = [$durable_active_milliseconds], durable_total_ms = [$durable_total_milliseconds], durable_total_s = [$durable_total_seconds]"
    check_interruption_requested
}
