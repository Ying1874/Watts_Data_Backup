#!/bin/bash

# IPC receives authoritative local time from the PLC over Modbus TCP.  The
# time-sync daemon already records every accepted sample, so retention can
# validate that evidence without changing the PLC protocol or daemon.

IPC_PLC_TIME_LOG_DIR="${IPC_PLC_TIME_LOG_DIR:-$WORKSPACE_ROOT/vpfi_data/logs/cabinet/plc_time_sync}"
IPC_PLC_TIME_LOG_TAIL_BYTES="${IPC_PLC_TIME_LOG_TAIL_BYTES:-131072}"
IPC_PLC_TIME_REQUIRED_SAMPLES="${IPC_PLC_TIME_REQUIRED_SAMPLES:-5}"
IPC_PLC_TIME_MAX_SAMPLE_GAP_MS="${IPC_PLC_TIME_MAX_SAMPLE_GAP_MS:-5000}"
IPC_PLC_TIME_MAX_OFFSET_SPREAD_MS="${IPC_PLC_TIME_MAX_OFFSET_SPREAD_MS:-100}"
IPC_PLC_TIME_MAX_ABS_OFFSET_MS="${IPC_PLC_TIME_MAX_ABS_OFFSET_MS:-5000}"
IPC_PLC_TIME_MAX_CURRENT_SKEW_MS="${IPC_PLC_TIME_MAX_CURRENT_SKEW_MS:-10000}"
IPC_PLC_TIME_MAX_WALL_DRIFT_MS="${IPC_PLC_TIME_MAX_WALL_DRIFT_MS:-10000}"
IPC_PLC_TIME_EXPECTED_UTC_OFFSET="${IPC_PLC_TIME_EXPECTED_UTC_OFFSET:-+0800}"

IPC_PLC_TIME_EVIDENCE_DETAIL="not_checked"
IPC_PLC_TIME_LATEST_EPOCH_MS=0
IPC_PLC_TIME_LATEST_OFFSET_MS=0
IPC_PLC_TIME_REFERENCE_MONOTONIC_MS=0

ipc_abs_integer() {
    local value=$1
    if (( value < 0 )); then
        IPC_ABS_INTEGER_RESULT=$((-value))
    else
        IPC_ABS_INTEGER_RESULT=$value
    fi
}

validate_ipc_plc_time_configuration() {
    local value

    for value in \
        "$IPC_PLC_TIME_LOG_TAIL_BYTES" \
        "$IPC_PLC_TIME_REQUIRED_SAMPLES" \
        "$IPC_PLC_TIME_MAX_SAMPLE_GAP_MS" \
        "$IPC_PLC_TIME_MAX_OFFSET_SPREAD_MS" \
        "$IPC_PLC_TIME_MAX_ABS_OFFSET_MS" \
        "$IPC_PLC_TIME_MAX_CURRENT_SKEW_MS" \
        "$IPC_PLC_TIME_MAX_WALL_DRIFT_MS"; do
        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
            IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_invalid_configuration"
            return 1
        fi
    done

    if (( IPC_PLC_TIME_LOG_TAIL_BYTES == 0 ||
          IPC_PLC_TIME_REQUIRED_SAMPLES < 2 ||
          IPC_PLC_TIME_MAX_SAMPLE_GAP_MS == 0 )); then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_invalid_configuration"
        return 1
    fi
    if [[ ! "$IPC_PLC_TIME_EXPECTED_UTC_OFFSET" =~ ^[+-][0-9]{4}$ ]]; then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_invalid_timezone_configuration"
        return 1
    fi
}

# Read only a bounded tail from each daily log.  A concurrently appended
# partial line cannot match the complete record expression and is ignored.
validate_ipc_plc_time_evidence() {
    local -a log_files=()
    local -a sample_records=()
    local -a selected_samples=()
    local -a last_relevant_event=()
    local file
    local file_index=0
    local tail_output
    local line
    local plc_epoch_ms
    local offset_ms
    local sample_file_index
    local previous_plc_epoch_ms=0
    local gap_ms
    local min_offset=0
    local max_offset=0
    local current_epoch_ms
    local current_skew_ms
    local current_offset
    local latest_plc_date
    local current_system_date
    local nullglob_was_set=false

    IPC_PLC_TIME_EVIDENCE_DETAIL="not_checked"
    IPC_PLC_TIME_LATEST_EPOCH_MS=0
    IPC_PLC_TIME_LATEST_OFFSET_MS=0

    validate_ipc_plc_time_configuration || return 1
    if [[ ! -d "$IPC_PLC_TIME_LOG_DIR" || -L "$IPC_PLC_TIME_LOG_DIR" ||
          ! -r "$IPC_PLC_TIME_LOG_DIR" ]]; then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_log_directory_unavailable"
        return 1
    fi

    shopt -q nullglob && nullglob_was_set=true
    shopt -s nullglob
    log_files=("$IPC_PLC_TIME_LOG_DIR"/time_sync_daemon_*.log)
    $nullglob_was_set || shopt -u nullglob
    if (( ${#log_files[@]} == 0 )); then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_log_missing"
        return 1
    fi

    for file in "${log_files[@]}"; do
        if [[ ! -f "$file" || -L "$file" || ! -r "$file" ]]; then
            IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_log_file_unsafe_or_unreadable"
            return 1
        fi
        if ! tail_output=$(tail -c "$IPC_PLC_TIME_LOG_TAIL_BYTES" -- "$file" 2>/dev/null); then
            IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_log_read_failed"
            return 1
        fi

        last_relevant_event[$file_index]="none"
        while IFS= read -r line; do
            if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}.*Event[[:space:]]*=[[:space:]]*\[sync_ok\],[[:space:]]*plc_ms[[:space:]]*=[[:space:]]*\[([0-9]{13})\],[[:space:]]*offset_ms[[:space:]]*=[[:space:]]*\[(-?[0-9]{1,10})\][[:space:]]*$ ]]; then
                plc_epoch_ms=${BASH_REMATCH[1]}
                offset_ms=${BASH_REMATCH[2]}
                sample_records+=("$plc_epoch_ms $offset_ms $file_index")
                last_relevant_event[$file_index]="sync_ok"
            elif [[ "$line" =~ Event[[:space:]]*=[[:space:]]*\[(clock_set_fail|offset_rejected|sample_unstable|calendar_invalid|sample_stale)\] ]]; then
                last_relevant_event[$file_index]=${BASH_REMATCH[1]}
            fi
        done <<< "$tail_output"
        file_index=$((file_index + 1))
    done

    if (( ${#sample_records[@]} < IPC_PLC_TIME_REQUIRED_SAMPLES )); then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_insufficient_samples"
        return 1
    fi

    mapfile -t selected_samples < <(
        printf '%s\n' "${sample_records[@]}" |
            sort -k1,1n |
            tail -n "$IPC_PLC_TIME_REQUIRED_SAMPLES"
    )
    if (( ${#selected_samples[@]} != IPC_PLC_TIME_REQUIRED_SAMPLES )); then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_sample_selection_failed"
        return 1
    fi

    for line in "${selected_samples[@]}"; do
        read -r plc_epoch_ms offset_ms sample_file_index <<< "$line"
        if (( previous_plc_epoch_ms > 0 )); then
            gap_ms=$((plc_epoch_ms - previous_plc_epoch_ms))
            if (( gap_ms <= 0 || gap_ms > IPC_PLC_TIME_MAX_SAMPLE_GAP_MS )); then
                IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_samples_not_continuous"
                return 1
            fi
        fi

        ipc_abs_integer "$offset_ms"
        if (( IPC_ABS_INTEGER_RESULT > IPC_PLC_TIME_MAX_ABS_OFFSET_MS )); then
            IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_offset_too_large"
            return 1
        fi
        if (( previous_plc_epoch_ms == 0 )); then
            min_offset=$offset_ms
            max_offset=$offset_ms
        else
            (( offset_ms < min_offset )) && min_offset=$offset_ms
            (( offset_ms > max_offset )) && max_offset=$offset_ms
        fi

        previous_plc_epoch_ms=$plc_epoch_ms
        IPC_PLC_TIME_LATEST_EPOCH_MS=$plc_epoch_ms
        IPC_PLC_TIME_LATEST_OFFSET_MS=$offset_ms
    done

    if (( max_offset - min_offset > IPC_PLC_TIME_MAX_OFFSET_SPREAD_MS )); then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_offsets_unstable"
        return 1
    fi
    if [[ "${last_relevant_event[$sample_file_index]}" != "sync_ok" ]]; then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_failure_after_latest_sample"
        return 1
    fi

    current_epoch_ms=$(date +%s%3N 2>/dev/null || true)
    if [[ ! "$current_epoch_ms" =~ ^[0-9]{13}$ ]]; then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_current_clock_unreadable"
        return 1
    fi
    current_skew_ms=$((current_epoch_ms - IPC_PLC_TIME_LATEST_EPOCH_MS))
    ipc_abs_integer "$current_skew_ms"
    if (( IPC_ABS_INTEGER_RESULT > IPC_PLC_TIME_MAX_CURRENT_SKEW_MS )); then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_latest_sample_not_fresh"
        return 1
    fi

    current_offset=$(date +%z 2>/dev/null || true)
    if [[ "$current_offset" != "$IPC_PLC_TIME_EXPECTED_UTC_OFFSET" ]]; then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_timezone_offset_mismatch"
        return 1
    fi

    latest_plc_date=$(date -d "@$((IPC_PLC_TIME_LATEST_EPOCH_MS / 1000))" +%Y-%m-%d 2>/dev/null || true)
    current_system_date=$(date -d "@$((current_epoch_ms / 1000))" +%Y-%m-%d 2>/dev/null || true)
    if [[ -z "$latest_plc_date" || -z "$current_system_date" ||
          "$latest_plc_date" != "$current_system_date" ]]; then
        IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_reference_date_mismatch"
        return 1
    fi

    IPC_PLC_TIME_EVIDENCE_DETAIL="plc_time_fresh_and_stable"
    return 0
}

initialize_ipc_time_context() {
    local last_trusted_epoch=""
    local delta=0

    RUN_REFERENCE_EPOCH=$(date +%s) || fail_now "failed to read IPC system time"
    RUN_REFERENCE_DATE=$(date -d "@$RUN_REFERENCE_EPOCH" +"%Y-%m-%d") ||
        fail_now "failed to format IPC system time"
    RUN_TODAY="$RUN_REFERENCE_DATE"
    RUN_YESTERDAY=$(date -d "@$((RUN_REFERENCE_EPOCH - 86400))" +"%Y-%m-%d") ||
        fail_now "failed to calculate IPC yesterday"
    get_monotonic_milliseconds
    IPC_PLC_TIME_REFERENCE_MONOTONIC_MS=$MONOTONIC_MILLISECONDS_RESULT

    if (( RUN_REFERENCE_EPOCH < TIME_MIN_EPOCH || RUN_REFERENCE_EPOCH > TIME_MAX_EPOCH )); then
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL="system_time_outside_plausible_range"
    elif ! validate_ipc_plc_time_evidence; then
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL=$IPC_PLC_TIME_EVIDENCE_DETAIL
    elif [[ -e "$LAST_TRUSTED_TIME_FILE" || -L "$LAST_TRUSTED_TIME_FILE" ]]; then
        if [[ ! -f "$LAST_TRUSTED_TIME_FILE" || -L "$LAST_TRUSTED_TIME_FILE" ||
              ! -r "$LAST_TRUSTED_TIME_FILE" ]]; then
            TIME_TRUSTED=false
            TIME_TRUST_DETAIL="persistent_time_anchor_unavailable"
        else
            IFS= read -r last_trusted_epoch < "$LAST_TRUSTED_TIME_FILE" || true
            if [[ ! "$last_trusted_epoch" =~ ^[0-9]+$ ]]; then
                TIME_TRUSTED=false
                TIME_TRUST_DETAIL="persistent_time_anchor_invalid"
            else
                delta=$((RUN_REFERENCE_EPOCH - last_trusted_epoch))
                if (( delta < -TIME_MAX_BACKWARD_SECONDS )); then
                    TIME_TRUSTED=false
                    TIME_TRUST_DETAIL="system_time_moved_backwards"
                elif (( delta > TIME_MAX_FORWARD_SECONDS )); then
                    # A backup gap is not evidence of a clock jump. Fresh PLC
                    # evidence has already passed above; keep the pre-retention
                    # PLC and monotonic-clock recheck before allowing cleanup.
                    TIME_TRUSTED=true
                    TIME_TRUST_DETAIL="plc_time_fresh_and_stable_after_long_idle"
                    log_warn "Long IPC backup interval accepted using fresh PLC evidence: elapsed_seconds = [$delta], threshold_seconds = [$TIME_MAX_FORWARD_SECONDS]"
                else
                    TIME_TRUSTED=true
                    TIME_TRUST_DETAIL="plc_time_fresh_stable_and_continuous"
                fi
            fi
        fi
    else
        TIME_TRUSTED=true
        TIME_TRUST_DETAIL="plc_time_fresh_and_stable_first_run"
    fi

    if $TIME_TRUSTED; then
        log_info "Retention time check passed: reference = [$RUN_REFERENCE_DATE], reason = [$TIME_TRUST_DETAIL], plc_epoch_ms = [$IPC_PLC_TIME_LATEST_EPOCH_MS], offset_ms = [$IPC_PLC_TIME_LATEST_OFFSET_MS]"
    else
        log_error "Retention cleanup is disabled because IPC time is untrusted: reference = [$RUN_REFERENCE_DATE], reason = [$TIME_TRUST_DETAIL]"
    fi
}

revalidate_ipc_time_context_before_retention() {
    local current_epoch_ms
    local expected_epoch_ms
    local elapsed_monotonic_ms
    local wall_drift_ms

    if ! $TIME_TRUSTED; then
        log_warn "IPC retention time recheck remains disabled: reason = [$TIME_TRUST_DETAIL]"
        return 0
    fi

    if ! validate_ipc_plc_time_evidence; then
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL="retention_recheck_${IPC_PLC_TIME_EVIDENCE_DETAIL}"
        log_error "Retention cleanup is disabled by IPC time recheck: reason = [$TIME_TRUST_DETAIL]"
        return 0
    fi

    current_epoch_ms=$(date +%s%3N 2>/dev/null || true)
    get_monotonic_milliseconds
    if [[ ! "$current_epoch_ms" =~ ^[0-9]{13}$ ||
          ! "$MONOTONIC_MILLISECONDS_RESULT" =~ ^[0-9]+$ ||
          "$MONOTONIC_MILLISECONDS_RESULT" -lt "$IPC_PLC_TIME_REFERENCE_MONOTONIC_MS" ]]; then
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL="retention_recheck_clock_unreadable"
        log_error "Retention cleanup is disabled by IPC time recheck: reason = [$TIME_TRUST_DETAIL]"
        return 0
    fi

    elapsed_monotonic_ms=$((MONOTONIC_MILLISECONDS_RESULT - IPC_PLC_TIME_REFERENCE_MONOTONIC_MS))
    expected_epoch_ms=$((RUN_REFERENCE_EPOCH * 1000 + elapsed_monotonic_ms))
    wall_drift_ms=$((current_epoch_ms - expected_epoch_ms))
    ipc_abs_integer "$wall_drift_ms"
    if (( IPC_ABS_INTEGER_RESULT > IPC_PLC_TIME_MAX_WALL_DRIFT_MS )); then
        TIME_TRUSTED=false
        TIME_TRUST_DETAIL="retention_recheck_wall_clock_jump"
        log_error "Retention cleanup is disabled by IPC time recheck: reason = [$TIME_TRUST_DETAIL], wall_drift_ms = [$wall_drift_ms]"
        return 0
    fi

    TIME_TRUST_DETAIL="plc_time_revalidated_before_retention"
    log_info "Retention time recheck passed: reference = [$RUN_REFERENCE_DATE], plc_epoch_ms = [$IPC_PLC_TIME_LATEST_EPOCH_MS], offset_ms = [$IPC_PLC_TIME_LATEST_OFFSET_MS], wall_drift_ms = [$wall_drift_ms]"
}
