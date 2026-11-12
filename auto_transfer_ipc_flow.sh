#!/bin/bash

# IPC orchestration only. IPC keeps verified source files until retention;
# conflicting source data is eligible for retention only after quarantine.
auto_transfer_ipc_main() {
    local source_dir
    local target_dir
    local target_class
    local target_root=${TARGET_ROOTS[ipc]}
    local required_bytes
    local total_required_bytes=0
    local conflict_summary

    setup_auto_transfer_runtime "$@"

    # Lock before run-log initialization, PID changes or state transitions.
    acquire_lock
    initialize_phase_timing
    start_timed_phase "initialize"
    ensure_state_files
    write_line_atomically "$PID_FILE" "$$" ||
        fail_now "failed to write pid file: $PID_FILE"
    set_state "1" "running"
    require_commands \
        awk cat cp date df du find grep mktemp mv readlink realpath rm rmdir \
        sha256sum sort stat sync tail touch tr wc xargs
    initialize_ipc_time_context
    cleanup_orphan_temp_files
    check_interruption_requested

    log_info "======================================================="
    log_info "========= Starting IPC data backup process ============"
    log_info "Run reference time: [$RUN_REFERENCE_DATE]"
    finish_timed_phase

    check_interruption_requested
    log_info "------------------------------------------------------"
    log_info "------------- Step 0: Preflight checks ---------------"
    start_timed_phase "preflight_and_space"
    check_target_ready "ipc" "$target_root"
    validate_delete_path_under_root "$target_root" "$IPC_CONFLICT_ROOT" ||
        fail_now "IPC conflict directory must be inside the target backup root: [$IPC_CONFLICT_ROOT]"
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        if [[ ! -d "$source_dir" ]]; then
            fail_now "source directory does not exist during preflight: $source_dir"
        fi

        target_dir=$(get_target_dir_for_source "$source_dir")
        target_class=$(get_target_class_for_source "$source_dir")
        validate_source_target_separation "$source_dir" "$target_dir"
        validate_source_target_separation "$source_dir" "$IPC_CONFLICT_ROOT"
        sum_pending_copy_bytes_for_directory \
            "$source_dir" "$target_dir" "$target_class"
        required_bytes=$SUM_PENDING_COPY_BYTES_RESULT
        [[ "$required_bytes" =~ ^[0-9]+$ ]] ||
            fail_now "failed to calculate IPC pending write bytes: [$source_dir]"
        total_required_bytes=$((total_required_bytes + required_bytes))
    done

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would enforce IPC actual pending write requirement: $total_required_bytes bytes."
    else
        ensure_space_for_bytes "ipc" "$target_root" "$total_required_bytes"
        TARGET_SPACE_PREFLIGHTED["ipc:$target_root"]=1
    fi
    finish_timed_phase

    check_interruption_requested
    log_info "------------------------------------------------------"
    log_info "------- Step 1: Copy, hash and commit backups --------"
    start_timed_phase "backup_and_verify"
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        target_dir=$(get_target_dir_for_source "$source_dir")
        target_class=$(get_target_class_for_source "$source_dir")
        log_info "Processing: [$source_dir] ---> [$target_dir]"
        move_files_with_copy "$source_dir" "$target_dir" "$target_class"
        check_interruption_requested
    done
    if (( IPC_FAST_SKIP_TOTAL > 0 )); then
        log_info "IPC verified-index summary: unchanged_files = [$IPC_FAST_SKIP_TOTAL]"
    fi
    flush_ledger_buffer || fail_now "failed to flush IPC transfer ledger"
    finish_timed_phase

    start_timed_phase "persist_before_retention"
    if ! $DRY_RUN; then
        sync -f "$target_root" ||
            fail_now "failed to persist IPC backup filesystem before retention"
        if ! commit_ipc_verified_index; then
            log_warn "Failed to persist IPC verified index; the next run will safely fall back to SHA-256 verification."
        fi
    fi
    set_state "2" "transfer_done"
    finish_timed_phase

    check_interruption_requested
    log_info "------------------------------------------------------"
    log_info "---- Step 2: Conditional source/target retention -----"
    start_timed_phase "conditional_retention"
    revalidate_ipc_time_context_before_retention
    if should_run_ipc_retention_today; then
        for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
            target_dir=$(get_target_dir_for_source "$source_dir")
            target_class=$(get_target_class_for_source "$source_dir")

            # A conflicting original target is protected for this run. A source
            # conflict is present in BACKED_UP_SOURCE_INDEX only after quarantine.
            clean_old_files "$target_dir" "$target_class" "target"
            if should_clean_source_files_for_class "$target_class"; then
                clean_old_files "$source_dir" "$target_class" "source"
            fi
        done

        clean_ipc_conflict_files "$IPC_CONFLICT_ROOT" "$IPC_CONFLICT_RETENTION_DAYS"
        if $TIME_TRUSTED; then
            IPC_RETENTION_PERFORMED=true
        fi
    else
        log_info "IPC retention already completed for [$RUN_REFERENCE_DATE]; skipping repeated source/target scans."
    fi
    flush_ledger_buffer || fail_now "failed to flush IPC cleanup ledger"
    finish_timed_phase

    check_interruption_requested
    start_timed_phase "final_persist"
    if ! $DRY_RUN; then
        sync -f "$target_root" ||
            fail_now "failed to persist IPC cleanup changes"
        if ! commit_ipc_verified_index; then
            log_warn "Failed to persist IPC verified index cleanup; stale cache records will be revalidated safely."
        fi
        if ! commit_ipc_retention_date; then
            log_warn "Failed to persist IPC retention date; retention may be repeated safely on the next run."
        fi
    fi

    persist_trusted_time
    finish_timed_phase
    log_info "=========== IPC backup process completed ============="
    log_info "======================================================="

    if (( CONFLICT_TOTAL > 0 )); then
        conflict_summary=$(build_conflict_summary)
        conflict_summary="${conflict_summary}; quarantined = [${QUARANTINED_CONFLICT_TOTAL}]"
        log_error "IPC backup completed with collisions. ${conflict_summary}"
        log_phase_timing_summary "collision"
        set_state "-1" "$conflict_summary"
        return 1
    fi

    log_phase_timing_summary "completed"
    if $TIME_TRUSTED; then
        set_state "0" "cleanup_done"
    else
        set_state "0" "transfer_done_retention_skipped:$TIME_TRUST_DETAIL"
    fi
    return 0
}
