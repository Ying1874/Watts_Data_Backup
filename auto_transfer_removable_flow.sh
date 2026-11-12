#!/bin/bash

# ARM removable-media lifecycle orchestration.
#
# This file owns the policy order:
#   identify -> bounded wait -> exclusive mount -> identity/RW probe
#   -> sync -> normal unmount -> post-unmount verification.
#
# Reusable primitives such as UUID/LABEL resolution, findmnt inspection and
# write/sync probing remain in auto_transfer_common.sh.

validate_removable_mount_options() {
    local mount_options=${REMOVABLE_MOUNT_OPTIONS:-}

    if [[ ",$mount_options," == *,ro,* ||
          ",$mount_options," != *,rw,* ]]; then
        log_error "REMOVABLE_MOUNT_OPTIONS must explicitly contain rw and must not contain ro"
        return 1
    fi
    if [[ ",$mount_options," == *,remount,* ||
          ",$mount_options," == *,bind,* ||
          ",$mount_options," == *,rbind,* ||
          ",$mount_options," == *,move,* ]]; then
        log_error "REMOVABLE_MOUNT_OPTIONS contains a disallowed mount operation"
        return 1
    fi
}

verify_removable_exclusive_mount() {
    local target_root=$1
    local resolved_target
    local mount_target
    local resolved_mount_target
    local mount_count=0

    resolved_target=$(realpath -m "$target_root") || return 1
    get_mount_targets_for_device "$REMOVABLE_EXPECTED_DEVICE"

    while IFS= read -r mount_target; do
        [[ -n "$mount_target" ]] || continue
        mount_count=$((mount_count + 1))
        resolved_mount_target=$(realpath -m "$mount_target") || return 1
        if [[ "$resolved_mount_target" != "$resolved_target" ]]; then
            log_error "Removable device is also mounted outside the managed target: expected = [$resolved_target], actual = [$resolved_mount_target]"
            return 1
        fi
    done <<< "$MOUNT_TARGETS_RESULT"

    if (( mount_count != 1 )); then
        log_error "Expected exactly one removable mount, found $mount_count for device [$REMOVABLE_EXPECTED_DEVICE]"
        return 1
    fi
}

clear_removable_active_state() {
    REMOVABLE_MOUNT_OWNED=false
    REMOVABLE_ACTIVE_TARGET=""
    REMOVABLE_ACTIVE_SOURCE=""
    REMOVABLE_ACTIVE_UUID=""
    REMOVABLE_ACTIVE_LABEL=""
    REMOVABLE_ACTIVE_MAJMIN=""
}

recover_managed_preexisting_mount() {
    local target_root=$1

    verify_removable_mount_identity "$target_root" "true" ||
        fail_now "existing mount at removable target has an unexpected identity or is not writable: [$target_root]"
    verify_removable_exclusive_mount "$target_root" ||
        fail_now "existing removable mount is not exclusive: [$target_root]"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Verified managed removable mount without adopting or unmounting it: spec = [$REMOVABLE_EXPECTED_SPEC], source = [$REMOVABLE_ACTIVE_SOURCE], target = [$target_root]"
        TARGET_READY_INDEX["removable:$target_root"]=1
        return 0
    fi

    # auto_transfer's process lock is already held and this is the dedicated
    # mount point. Exact device identity and exclusive-mount checks above let a
    # new run reconcile a mount left behind by a forcibly stopped previous run.
    # Never use lazy/force unmount: a busy or unhealthy mount remains visible
    # and requires operator intervention.
    REMOVABLE_MOUNT_OWNED=true
    log_warn "Recovering an exclusively mounted managed removable target left by an earlier run: [$target_root]"
    if ! sync -f "$target_root" >> "$LOG_FILE" 2>&1; then
        fail_now "failed to synchronize preexisting managed removable mount: [$target_root]"
    fi
    if ! umount "$target_root" >> "$LOG_FILE" 2>&1; then
        fail_now "normal unmount of preexisting managed removable target failed; no lazy/force unmount was attempted: [$target_root]"
    fi
    if get_exact_mount_info "$target_root"; then
        fail_now "normal recovery umount returned success but removable target remains mounted: [$target_root]"
    fi

    get_mount_targets_for_device "$REMOVABLE_EXPECTED_DEVICE"
    if [[ -n "$MOUNT_TARGETS_RESULT" ]]; then
        fail_now "removable device still has mount targets after recovery unmount: [$MOUNT_TARGETS_RESULT]"
    fi

    clear_removable_active_state
    log_info "Preexisting managed removable mount was synchronized and normally unmounted; continuing with a fresh mount."
}

prepare_removable_target() {
    local target_root=$1
    local mount_options=${REMOVABLE_MOUNT_OPTIONS:-rw,nodev,nosuid,noexec}
    local expected_fstype=${REMOVABLE_FS_TYPE:-}

    require_commands blkid findmnt mount umount readlink realpath sleep sync
    validate_removable_identity_configuration ||
        fail_now "invalid removable identity configuration"
    validate_removable_mount_options ||
        fail_now "invalid removable mount options"
    [[ -n "$expected_fstype" ]] ||
        fail_now "REMOVABLE_FS_TYPE must be configured"

    if ! wait_for_expected_removable_device; then
        fail_now "expected removable device was not detected before timeout; no hub reset or driver unbind was attempted"
    fi

    if get_exact_mount_info "$target_root"; then
        recover_managed_preexisting_mount "$target_root"
        if $DRY_RUN; then
            return 0
        fi
    fi

    get_mount_targets_for_device "$REMOVABLE_EXPECTED_DEVICE"
    if [[ -n "$MOUNT_TARGETS_RESULT" ]]; then
        fail_now "removable device is already mounted outside the managed target: [$MOUNT_TARGETS_RESULT]"
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would mount stable removable spec [$REMOVABLE_EXPECTED_SPEC] as [$expected_fstype] at [$target_root]"
        TARGET_READY_INDEX["removable:$target_root"]=1
        return 0
    fi

    mkdir -p "$target_root" ||
        fail_now "failed to create removable mount point: [$target_root]"
    if ! mount -t "$expected_fstype" -o "$mount_options" \
        "$REMOVABLE_EXPECTED_SPEC" "$target_root" >> "$LOG_FILE" 2>&1; then
        fail_now "failed to mount removable device without recovery action: [$REMOVABLE_EXPECTED_SPEC] -> [$target_root]"
    fi

    # Ownership is recorded immediately after mount succeeds so any
    # subsequent validation failure uses a normal unmount during cleanup.
    REMOVABLE_MOUNT_OWNED=true
    REMOVABLE_ACTIVE_TARGET=$(realpath -m "$target_root")
    check_interruption_requested

    verify_removable_mount_identity "$target_root" "true" ||
        fail_now "new removable mount failed post-mount identity/writability validation: [$target_root]"
    verify_removable_exclusive_mount "$target_root" ||
        fail_now "new removable mount is not exclusive: [$target_root]"
    log_info "Mounted removable target: spec = [$REMOVABLE_EXPECTED_SPEC], source = [$REMOVABLE_ACTIVE_SOURCE], uuid = [$REMOVABLE_ACTIVE_UUID], label = [$REMOVABLE_ACTIVE_LABEL], target = [$target_root]"

    if ! probe_target_write_and_sync "$target_root"; then
        fail_now "removable target failed write/rename/sync probe; no remount or fsck was attempted: [$target_root]"
    fi
    check_interruption_requested
    TARGET_READY_INDEX["removable:$target_root"]=1
}

commit_and_unmount_removable_target() {
    local target_root=$1
    local sync_start_seconds
    local sync_duration_seconds
    local unmount_start_seconds
    local unmount_duration_seconds

    $REMOVABLE_MOUNT_OWNED ||
        fail_now "source deletion is blocked because this run does not own the removable mount"
    verify_removable_mount_identity "$target_root" "true" ||
        fail_now "removable target is missing, read-only or changed before commit"
    verify_removable_exclusive_mount "$target_root" ||
        fail_now "removable target is no longer exclusively mounted before commit"

    log_info "Synchronizing removable filesystem before source commit: [$target_root]"
    get_monotonic_seconds
    sync_start_seconds=$MONOTONIC_SECONDS_RESULT
    sync -f "$target_root" ||
        fail_now "failed to synchronize removable filesystem: [$target_root]"
    get_monotonic_seconds
    sync_duration_seconds=$((MONOTONIC_SECONDS_RESULT - sync_start_seconds))

    # Deliberately use only a normal unmount. Lazy (-l), force (-f) and
    # read-only fallback (-r) would hide a busy or unhealthy filesystem.
    get_monotonic_seconds
    unmount_start_seconds=$MONOTONIC_SECONDS_RESULT
    if ! umount "$target_root" >> "$LOG_FILE" 2>&1; then
        fail_now "normal unmount failed after synchronization; source deletion remains blocked and no lazy/force unmount was attempted: [$target_root]"
    fi
    get_monotonic_seconds
    unmount_duration_seconds=$((MONOTONIC_SECONDS_RESULT - unmount_start_seconds))
    if get_exact_mount_info "$target_root"; then
        fail_now "umount returned success but removable target is still mounted: [$target_root]"
    fi

    get_mount_targets_for_device "$REMOVABLE_EXPECTED_DEVICE"
    if [[ -n "$MOUNT_TARGETS_RESULT" ]]; then
        fail_now "removable device still has mount targets after managed unmount: [$MOUNT_TARGETS_RESULT]"
    fi

    clear_removable_active_state
    REMOVABLE_MOUNT_COMMITTED=true
    log_info "Removable commit timing: sync_duration_s = [$sync_duration_seconds], unmount_duration_s = [$unmount_duration_seconds]"
    log_info "Removable target committed and normally unmounted successfully: [$target_root]"
}

release_removable_target() {
    local target_root=${REMOVABLE_ACTIVE_TARGET:-}
    local release_detail

    if ! $REMOVABLE_MOUNT_OWNED || [[ -z "$target_root" ]]; then
        return 0
    fi

    if ! get_exact_mount_info "$target_root"; then
        log_warn "Managed removable target is not visible as the exact mount during runtime cleanup: target = [$target_root], detail = [$MOUNT_INFO_ERROR_DETAIL]"
        clear_removable_active_state
        return 0
    fi

    # Do not unmount an unexpected filesystem from the shared cleanup trap.
    if [[ -n "$REMOVABLE_ACTIVE_MAJMIN" &&
          "$MOUNT_INFO_MAJMIN" != "$REMOVABLE_ACTIVE_MAJMIN" ]]; then
        release_detail="refused to unmount changed removable target during cleanup: target = [$target_root], expected_majmin = [$REMOVABLE_ACTIVE_MAJMIN], actual_majmin = [$MOUNT_INFO_MAJMIN]"
        log_error "$release_detail"
        set_state "-1" "$release_detail"
        return 1
    fi
    if [[ -n "$REMOVABLE_ACTIVE_UUID" &&
          -n "$MOUNT_INFO_UUID" &&
          "$MOUNT_INFO_UUID" != "$REMOVABLE_ACTIVE_UUID" ]]; then
        release_detail="refused to unmount changed removable UUID during cleanup: target = [$target_root], expected_uuid = [$REMOVABLE_ACTIVE_UUID], actual_uuid = [$MOUNT_INFO_UUID]"
        log_error "$release_detail"
        set_state "-1" "$release_detail"
        return 1
    fi

    if ! sync -f "$target_root" >> "$LOG_FILE" 2>&1; then
        log_error "Failed to sync removable target during failure cleanup; attempting only a normal unmount: [$target_root]"
    fi
    if ! umount "$target_root" >> "$LOG_FILE" 2>&1; then
        release_detail="normal removable unmount failed during cleanup; no lazy/force unmount was attempted, manual intervention required: target = [$target_root]"
        log_error "$release_detail"
        set_state "-1" "$release_detail"
        return 1
    fi
    if get_exact_mount_info "$target_root"; then
        release_detail="normal umount returned success but removable target remains mounted during cleanup: target = [$target_root]"
        log_error "$release_detail"
        set_state "-1" "$release_detail"
        return 1
    fi

    clear_removable_active_state
    log_info "Removable target normally unmounted during runtime cleanup: [$target_root]"
}
