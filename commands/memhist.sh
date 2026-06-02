#!/bin/bash
# Command: memhist - Memory usage history

memhist_help() {
    echo "Options for memhist:"
    echo "  Usage: vb_tool memhist [-b begin_time] [-e end_time]"
    echo "  Description: display memory usage history from snapshots"
    echo ""
    echo "  Options:"
    echo "    -b begin_time    Begin time (default: today 00:00:00)"
    echo "    -e end_time      End time (default: current time)"
    echo ""
    echo "  Time Formats:"
    echo "    YYYY-MM-DD              (e.g., 2026-03-02)"
    echo "    YYYY-MM-DD HH           (e.g., 2026-03-02 12)"
    echo "    YYYY-MM-DD HH:MM        (e.g., 2026-03-02 12:30)"
    echo "    YYYY-MM-DD HH:MM:SS     (e.g., 2026-03-02 12:30:00)"
    echo ""
    echo "  Notes:"
    echo "    - Time values with spaces must be quoted"
    echo "    - Both -b and -e must be specified together when using time parameters"
    echo "    - Memory values are displayed in human-readable format (KB, MB, GB)"
    echo ""
    echo "  Examples:"
    echo "    vb_tool memhist                                    # Today 00:00 to current time"
    echo "    vb_tool memhist -b 2026-03-02                      # 2026-03-02 00:00 to current time"
    echo "    vb_tool memhist -e 2026-03-03                      # Today 00:00 to 2026-03-03 00:00"
    echo "    vb_tool memhist -b \"2026-03-02 09\" -e \"2026-03-02 18\"    # 09:00 to 18:00 on 2026-03-02"
    echo "    vb_tool memhist -b \"2026-03-02 09:30\" -e \"2026-03-02 17:45\""
    echo ""
}
run_memhist() {
    local begin_time=""
    local end_time=""
    local args=()
    local found_b=0
    local found_e=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -b requires a value" >&2
                    return 1
                fi
                if [[ ! "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
                    echo "Error: Invalid time format for -b: $1" >&2
                    return 1
                fi
                begin_time="$1"
                found_b=1
                shift
                if [[ $# -gt 0 && "$1" =~ ^[0-9]{1,2}$ ]]; then
                    echo "Error: Time value with space not quoted: -b $begin_time $1" >&2
                    echo "  Please quote time values with spaces: -b \"$begin_time $1\"" >&2
                    return 1
                fi
                if [[ $# -gt 0 && "$1" =~ ^[0-9]{1,2}:[0-9]{1,2}$ ]]; then
                    echo "Error: Time value with space not quoted: -b $begin_time $1" >&2
                    echo "  Please quote time values with spaces: -b \"$begin_time $1\"" >&2
                    return 1
                fi
                ;;
            -e)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -e requires a value" >&2
                    return 1
                fi
                if [[ ! "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
                    echo "Error: Invalid time format for -e: $1" >&2
                    return 1
                fi
                end_time="$1"
                found_e=1
                shift
                if [[ $# -gt 0 && "$1" =~ ^[0-9]{1,2}$ ]]; then
                    echo "Error: Time value with space not quoted: -e $end_time $1" >&2
                    echo "  Please quote time values with spaces: -e \"$end_time $1\"" >&2
                    return 1
                fi
                if [[ $# -gt 0 && "$1" =~ ^[0-9]{1,2}:[0-9]{1,2}$ ]]; then
                    echo "Error: Time value with space not quoted: -e $end_time $1" >&2
                    echo "  Please quote time values with spaces: -e \"$end_time $1\"" >&2
                    return 1
                fi
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    if [ ${#args[@]} -gt 0 ]; then
        echo "Error: Unexpected arguments: ${args[*]}" >&2
        return 1
    fi
    
    if [ $found_b -ne $found_e ]; then
        echo "Error: Both -b and -e parameters are required when specifying time" >&2
        return 1
    fi
    
    format_time() {
        local input="$1"
        local result=""
        
        if [ -z "$input" ]; then
            echo "Error: Time parameter cannot be empty" >&2
            return 1
        fi
        
        input=$(echo "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        if [[ "$input" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{1,2})$ ]]; then
            local date_part="${BASH_REMATCH[1]}"
            local hour_part="${BASH_REMATCH[2]}"
            if [ "$hour_part" -ge 0 ] && [ "$hour_part" -le 23 ]; then
                printf -v hour_part "%02d" "$((10#$hour_part))"
                result="$date_part $hour_part:00:00"
                echo "$result"
                return 0
            else
                echo "Error: Hour must be between 0 and 23: $hour_part" >&2
                return 1
            fi
        fi
        
        if [[ "$input" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{1,2}):([0-9]{1,2})$ ]]; then
            local date_part="${BASH_REMATCH[1]}"
            local hour_part="${BASH_REMATCH[2]}"
            local minute_part="${BASH_REMATCH[3]}"
            if [ "$hour_part" -ge 0 ] && [ "$hour_part" -le 23 ] && [ "$minute_part" -ge 0 ] && [ "$minute_part" -le 59 ]; then
                printf -v hour_part "%02d" "$((10#$hour_part))"
                printf -v minute_part "%02d" "$((10#$minute_part))"
                result="$date_part $hour_part:$minute_part:00"
                echo "$result"
                return 0
            else
                echo "Error: Invalid hour or minute value: $hour_part:$minute_part" >&2
                return 1
            fi
        fi
        
        if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
            local hour_part="${BASH_REMATCH[1]}"
            local minute_part="${BASH_REMATCH[2]}"
            local second_part="${BASH_REMATCH[3]}"
            if [ "$hour_part" -ge 0 ] && [ "$hour_part" -le 23 ] && \
               [ "$minute_part" -ge 0 ] && [ "$minute_part" -le 59 ] && \
               [ "$second_part" -ge 0 ] && [ "$second_part" -le 59 ]; then
                echo "$input"
                return 0
            else
                echo "Error: Invalid time value: $hour_part:$minute_part:$second_part" >&2
                return 1
            fi
        fi
        
        if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            result="$input 00:00:00"
            echo "$result"
            return 0
        fi
        
        echo "Error: Invalid time format: $input" >&2
        return 1
    }
    
    if [ -z "$begin_time" ] && [ -z "$end_time" ]; then
        # 默认：今天零点到现在
        begin_time=$(date +'%Y-%m-%d 00:00:00')
        end_time=$(date +'%Y-%m-%d %H:%M:%S')
    else
        begin_time=$(format_time "$begin_time")
        if [ $? -ne 0 ]; then
            return 1
        fi
        
        end_time=$(format_time "$end_time")
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    psql -d postgres <<EOF
\pset footer off
\echo '==========================='
\echo '   Memory Usage History'
\echo '==========================='
\echo ''
WITH tmp
AS (
    SELECT a.snapshot_id, a.snap_memorytype, a.snap_memorymbytes, to_char(b.start_ts,'yyyy-mm-dd hh24:mi:ss') start_ts
    FROM snapshot.snap_global_memory_node_detail a, snapshot.tables_snap_timestamp b
    WHERE a.snapshot_id = b.snapshot_id AND b.tablename = 'snap_global_memory_node_detail'
     and b.start_ts >= '$begin_time'::timestamp
     and b.start_ts <= '$end_time'::timestamp
)
SELECT start_ts,
       pg_size_pretty(process_used*1024*1024::numeric(100,0)) process_used,
       pg_size_pretty(dynamic_used*1024*1024::numeric(100,0)) dynamic_used,
       pg_size_pretty(dynamic_used_shrctx*1024*1024::numeric(100,0)) dynamic_used_shrctx,  
       pg_size_pretty(shared_used*1024*1024::numeric(100,0)) shared_used,
       pg_size_pretty(backend_used*1024*1024::numeric(100,0)) backend_used,
       pg_size_pretty(other_used*1024*1024::numeric(100,0)) other_used
FROM tmp
PIVOT(sum(snap_memorymbytes) FOR snap_memorytype IN 
      ('process_used_memory' AS process_used, 
       'dynamic_used_memory' AS dynamic_used, 
       'dynamic_used_shrctx' AS dynamic_used_shrctx,
       'shared_used_memory' AS shared_used, 
       'backend_used_memory' AS backend_used,
       'other_used_memory' AS other_used))
ORDER BY start_ts;
EOF
}

