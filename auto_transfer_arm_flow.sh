#!/bin/bash

# ARM orchestration only. Transfer, verification and deletion primitives live
# in auto_transfer_common.sh.
auto_transfer_arm_main() {
    if ! declare -F set_state_or_fail >/dev/null; then
        printf '%s\n' '[ERROR] Incompatible backup modules: update common and flow scripts together.' >&2
        return 1
    fi
    local source_dir
    local target_dir
    local target_class
    local target_root=${TARGET_ROOTS[removable]}
    local conflict_summary
    local total_required_bytes=0
    local source_required_bytes

    setup_auto_transfer_runtime "$@"

    # Lock before creating a run log or changing externally visible state.
    acquire_lock
    initialize_phase_timing
    start_timed_phase "initialize_and_mount"
    ensure_state_files
    write_line_atomically "$PID_FILE" "$$" ||
        fail_now "failed to write pid file: $PID_FILE"
    set_state_or_fail "1" "running"
    initialize_time_context
    require_commands \
        awk cat date df du find findmnt grep mktemp mv readlink realpath rm \
        rmdir rsync sha256sum sort stat sync touch tr wc xargs

    prepare_removable_target "$target_root"
    cleanup_orphan_temp_files
    cleanup_orphan_arm_visual_archive_directories \
        "$(get_target_dir_for_source "$ARM_VISUAL_SOURCE_DIR")"
    check_interruption_requested

    log_info "======================================================="
    log_info "========= Starting ARM data transfer process =========="
    log_info "======================================================="
    log_info "Run reference time: [$RUN_REFERENCE_DATE]"
    finish_timed_phase

    check_interruption_requested
    log_info ""
    log_info "------------------------------------------------------"
    log_info "---- Step 0: Build transfer plans and check space ----"
    log_info "------------------------------------------------------"
    start_timed_phase "plan_and_space"
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        if [[ ! -d "$source_dir" ]]; then
            fail_now "source directory does not exist during preflight: $source_dir"
        fi

        target_dir=$(get_target_dir_for_source "$source_dir")
        target_class=$(get_target_class_for_source "$source_dir")
        validate_source_target_separation "$source_dir" "$target_dir"
        check_target_ready "$target_class" "${TARGET_ROOTS[$target_class]}"
        if [[ "$source_dir" == "$ARM_VISUAL_SOURCE_DIR" ]] &&
           arm_visual_archive_enabled; then
            prepare_arm_visual_archive_plan "$source_dir" "$target_dir"
            source_required_bytes=$ARM_VISUAL_ARCHIVE_PENDING_BYTES
        else
            prepare_rsync_transfer_plan "$source_dir" "$target_dir" "$target_class"
            source_required_bytes=${PREPARED_RSYNC_BYTES[$source_dir]}
        fi
        total_required_bytes=$((total_required_bytes + source_required_bytes))
    done

    if $DRY_RUN; then
        log_info "[DRY-RUN] Actual pending write total is $total_required_bytes bytes; 20 GiB reserve would also be enforced."
    else
        ensure_space_for_bytes "removable" "$target_root" "$total_required_bytes"
    log_info "ARM capacity check passed: pending_bytes = [$total_required_bytes], reserve_gib = [${TARGET_RESERVED_GB[removable]}]"
    fi
    finish_timed_phase

    check_interruption_requested
    log_info ""
    log_info "------------------------------------------------------"
    log_info "----- Step 1: Transfer files without overwriting -----"
    log_info "------------------------------------------------------"
    start_timed_phase "transfer_and_verify"
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        target_dir=$(get_target_dir_for_source "$source_dir")
        target_class=$(get_target_class_for_source "$source_dir")
        log_info "Processing: [$source_dir] ---> [$target_dir]"
        if [[ "$source_dir" == "$ARM_VISUAL_SOURCE_DIR" ]] &&
           arm_visual_archive_enabled; then
            transfer_arm_visual_archives "$source_dir" "$target_dir"
            promote_staged_arm_visual_archives
        else
            move_files_with_rsync "$source_dir" "$target_dir" "$target_class"
        fi
        check_interruption_requested
    done
    flush_ledger_buffer || fail_now "failed to flush transfer ledger"
    set_state_or_fail "2" "transfer_done"
    finish_timed_phase

    # Time-based visual selection is not allowed to silently turn into a
    # successful partial backup. Other source classes may already have been
    # copied, so persist and release the USB, but retain every source file.
    if $ARM_VISUAL_ARCHIVE_PLAN_BLOCKED; then
        start_timed_phase "blocked_sync_and_unmount"
        if ! $DRY_RUN; then
            commit_and_unmount_removable_target "$target_root"
        fi
        finish_timed_phase
        start_timed_phase "finalize"
        log_error "ARM transfer stopped at a fail-closed visual archive boundary; skipped all destructive cleanup: [$ARM_VISUAL_ARCHIVE_PLAN_BLOCK_DETAIL]"
        finish_timed_phase "blocked"
        log_phase_timing_summary "blocked"
        set_state_or_fail "-1" "$ARM_VISUAL_ARCHIVE_PLAN_BLOCK_DETAIL"
        return 1
    fi

    # Any collision blocks every destructive cleanup in this run. The
    # successfully transferred files are synchronized and the USB is released,
    # but no target retention or source deletion is performed.
    if (( CONFLICT_TOTAL > 0 )); then
        start_timed_phase "collision_sync_and_unmount"
        if ! $DRY_RUN; then
            commit_and_unmount_removable_target "$target_root"
        fi
        finish_timed_phase
        start_timed_phase "finalize"
        persist_trusted_time
        conflict_summary=$(build_conflict_summary)
        log_error "ARM transfer finished with collisions; skipped all destructive cleanup. ${conflict_summary}"
        finish_timed_phase "collision"
        log_phase_timing_summary "collision"
        set_state_or_fail "-1" "$conflict_summary"
        return 1
    fi

    check_interruption_requested
    log_info ""
    log_info "------------------------------------------------------"
    log_info "----- Step 2: Target retention before commit ---------"
    log_info "------------------------------------------------------"
    start_timed_phase "target_retention"
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        target_dir=$(get_target_dir_for_source "$source_dir")
        target_class=$(get_target_class_for_source "$source_dir")
        clean_old_files "$target_dir" "$target_class" "target"
        check_interruption_requested
    done
    flush_ledger_buffer || fail_now "failed to flush target cleanup ledger"
    finish_timed_phase

    check_interruption_requested
    log_info ""
    log_info "------------------------------------------------------"
    log_info "-- Step 3: Sync, unmount and commit source manifest --"
    log_info "------------------------------------------------------"
    start_timed_phase "sync_unmount_and_manifest_commit"
    if $DRY_RUN; then
        log_info "[DRY-RUN] Would sync and unmount removable target before committing source deletion."
    else
        commit_and_unmount_removable_target "$target_root"
        commit_deferred_source_manifest
    fi
    finish_timed_phase

    log_info ""
    log_info "------------------------------------------------------"
    log_info "---- Step 4: Batch-delete committed source files -----"
    log_info "------------------------------------------------------"
    start_timed_phase "batch_source_delete"
    commit_deferred_source_deletions
    finish_timed_phase
    check_interruption_requested

    # Whole-tree source retention is only reachable after a successful target
    # commit/unmount and committed-manifest deletion. At this boundary every
    # source date directory may legitimately be eligible after a production
    # pause, so allow a 100% candidate ratio while preserving all other delete
    # budgets and safety checks.
    start_timed_phase "visual_tree_cleanup"
    for source_dir in "${SOURCE_DIR_ORDER[@]}"; do
        target_class=$(get_target_class_for_source "$source_dir")
        cleanup_visual_source_directory "$source_dir" "$target_class" true
    done
    finish_timed_phase

    start_timed_phase "finalize"
    persist_trusted_time
    flush_ledger_buffer || fail_now "failed to flush final ledger"
    finish_timed_phase
    log_phase_timing_summary "completed"
    log_info ""
    log_info "======================================================="
    log_info "=========== ARM transfer process completed ============"
    log_info "======================================================="

    set_state_or_fail "0" "cleanup_done"
    return 0
}
