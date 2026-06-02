#!/bin/bash
# Common utility functions for vb_tool

[[ -n "$_VB_COMMON_LOADED" ]] && return 0
_VB_COMMON_LOADED=1

# --- Helper Utilities ---
# Robust Executor: Handles timeouts, errors, and formatting
# Usage: safe_exec "Task Description" "Command" [Timeout, default 10s]
safe_exec() {
    local title="$1"
    local cmd="$2"
    local timeout_val="${3:-10s}"

    # Handle the 250KB function library issue using BASH_ENV
    local TMP_FUNC_FILE="/tmp/vb_funcs_$$.sh"
    local REQUIRED_FUNCS=(run_collect_log_osinfo run_nets run_lsds run_as run_asp_cnt_query run_asp_event_query run_asp_waitchain_query run_asp_sql_query run_mem run_xloghc run_dead_tups run_wdr_event run_wdr_summary run_wdr_topsql run_collect_log_asp run_collect_log_wdr run_collect_log_mem run_collect_log_dbinfo run_collect_log_dbfiles run_memhist safe_exec run_collect_log_deadtups run_collect_log_extension run_collect_log_version run_collect_log_stack run_collect_log_cmdn run_collect_log_param run_collect_log_xlog run_collect_log_pglog)
    [ ! -f "$TMP_FUNC_FILE" ] && declare -f "${REQUIRED_FUNCS[@]}" > "$TMP_FUNC_FILE"

    # Execute and capture both stdout and stderr
    local result
	result=$(BASH_ENV="$TMP_FUNC_FILE" timeout --foreground "$timeout_val" bash -c "$cmd" 2>&1)
    local ret=$?

	local width=45
    if [ $ret -eq 0 ]; then
        # SUCCESS: Use \r to return to the beginning of the line and overwrite old text with spaces for "in-place updates."
        # This ensures only the currently executing task is displayed on the screen.
        printf "\r\033[K[INFO ] Progress: %-${width}s [OK]" "$title" >&2
		# Inject a clean English header into the redirected output (.txt file)
        echo "---------- [$(date '+%H:%M:%S')] ${title} (CMD: ${cmd}) ----------"
		echo "$result"
    else
        # FAILURE: Print the error in red on a new line to ensure it is not overwritten by subsequent progress updates.
        printf "\n\033[0;31m[ERROR] Progress: %-${width}s [FAILED]\033[0m\n" "$title" >&2
        printf "        >> %s\n" "$(echo "$result" | head -n 1)" >&2
    fi
}
