#!/bin/bash
# Command: xlogcom - analyze WAL commits per second

xlogcom_help() {
    echo "Options for xlogcom:"
    echo "  Usage: [START_WAL] [END_WAL]"
    echo "  Description: analyze WAL commits per second"
    echo ""
}

run_xlogcom() {
    
    local start_wal="$1"
    local end_wal="$2"
    local wal_dir="${3:-${PGDATA}/pg_xlog}"
	
    if [ -z "$start_wal" ] || [ -z "$end_wal" ]; then
        echo "Error: Missing required parameters" >&2
        echo "Usage: vb_tool xlogcom <start_wal> <end_wal>" >&2
        echo "Example: vb_tool xlogcom 000000010000000800000042 00000001000000080000004C" >&2
        exit 1
    fi
    
    pg_xlogdump -p $wal_dir "$start_wal" "$end_wal" | awk 'BEGIN {
    max_len = 19  
    count_len = 6  
}
/XLOG_XACT_COMMIT_COMPACT/ {
    if (match($0, /commit: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, arr)) {
        time = arr[1]
        count[time]++
    }
} END {
    total = 0
    for (t in count) {
        total += count[t]
    }
    
    print "+---------------------+--------+"
    print "|        time         | commit |"
    print "+---------------------+--------+"
    
    n = asorti(count, sorted)
    for (i = 1; i <= n; i++) {
        t = sorted[i]
        printf "| %-19s | %6d |\n", t, count[t]
    }
    
    print "+---------------------+--------+"
    printf "| %-19s | %6d |\n", "TOTAL", total
    print "+---------------------+--------+"
}'
}
