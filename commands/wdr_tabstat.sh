#!/bin/bash
# Command: wdr_tabstat - WDR table statistics

wdr_tabstat_help() {
    echo "Options for wdr_tabstat:"
    echo "  Usage: vb_tool wdr_tabstat -b begin_time -e end_time -d database_name -s schema_name -t table_name"
    echo "  Description: Display table DML/scan/live-dead-tuple statistics from WDR snapshots."
    echo ""
    echo "  Options:"
    echo "    -b begin_time    Begin time (default: today 00:00:00)"
    echo "    -e end_time      End time   (default: tomorrow 00:00:00)"
    echo "    -d database      Database name  (required)"
    echo "    -s schema        Schema name    (required)"
    echo "    -t table         Table name     (required)"
    echo ""
    echo "  Output Columns:"
    echo "    start_ts   Snapshot timestamp"
    echo "    seqscan    Incremental sequential scans"
    echo "    idxscan    Incremental index scans"
    echo "    ins        Incremental rows inserted"
    echo "    upd        Incremental rows updated"
    echo "    del        Incremental rows deleted"
    echo "    hotupd     Incremental HOT rows updated"
    echo "    alive      Live tuple count (absolute)"
    echo "    dead       Dead tuple count (absolute)"
    echo ""
    echo "  Time Formats:"
    echo "    YYYY-MM-DD              (e.g., 2026-03-02)"
    echo "    YYYY-MM-DD HH           (e.g., 2026-03-02 12)"
    echo "    YYYY-MM-DD HH:MM        (e.g., 2026-03-02 12:30)"
    echo "    YYYY-MM-DD HH:MM:SS     (e.g., 2026-03-02 12:30:00)"
    echo ""
    echo "  Notes:"
    echo "    - Time values with spaces must be quoted"
    echo "    - Begin time automatically subtracts 1 hour when querying snapshots"
    echo "    - End time automatically adds 1 hour when querying snapshots"
    echo "    - Both -b and -e must be specified together (or both omitted for defaults)"
    echo ""
    echo "  Examples:"
    echo "    vb_tool wdr_tabstat -d mydb -s public -t orders"
    echo "    vb_tool wdr_tabstat -b 2026-03-02 -e 2026-03-03 -d mydb -s public -t orders"
    echo "    vb_tool wdr_tabstat -b \"2026-03-02 08\" -e \"2026-03-02 20\" -d mydb -s windba -t coo_queue_head"
    echo ""
}
run_wdr_tabstat() {
    local begin_time=""
    local end_time=""
    local db_name=""
    local schema_name=""
    local table_name=""
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
            -d)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -d requires a value" >&2
                    return 1
                fi
                db_name="$1"
                shift
                ;;
            -s)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -s requires a value" >&2
                    return 1
                fi
                schema_name="$1"
                shift
                ;;
            -t)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -t requires a value" >&2
                    return 1
                fi
                table_name="$1"
                shift
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ -z "$db_name" ]; then
        echo "Error: -d database_name is required" >&2
        return 1
    fi
    if [ -z "$schema_name" ]; then
        echo "Error: -s schema_name is required" >&2
        return 1
    fi
    if [ -z "$table_name" ]; then
        echo "Error: -t table_name is required" >&2
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
        begin_time=$(date +'%Y-%m-%d 00:00:00')
        end_time=$(date -d 'tomorrow 00:00:00' +'%Y-%m-%d %H:%M:%S')
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

    local query_begin=$(date -d "$begin_time 1 hour ago" +'%Y-%m-%d %H:%M:%S')
    local query_end=$(date -d "$end_time 1 hour" +'%Y-%m-%d %H:%M:%S')

    psql -d postgres <<EOF
\pset footer off
\echo '========================='
\echo '   wdr tabstat summary   '
\echo '========================='
\echo '  db: $db_name  schema: $schema_name  table: $table_name'
\echo '                          '
SELECT
    b.start_ts::timestamp(0)                                                         AS start_ts,
    snap_seq_scan
      - coalesce(lag(snap_seq_scan)
                   OVER (ORDER BY b.snapshot_id), 0)                                 AS seqscan,
    snap_idx_scan
      - coalesce(lag(snap_idx_scan)
                   OVER (ORDER BY b.snapshot_id), 0)                                 AS idxscan,
    snap_n_tup_ins
      - coalesce(lag(snap_n_tup_ins)
                   OVER (ORDER BY b.snapshot_id), 0)                                 AS ins,
    snap_n_tup_upd
      - coalesce(lag(snap_n_tup_upd)
                   OVER (ORDER BY b.snapshot_id), 0)                                 AS upd,
    snap_n_tup_del
      - coalesce(lag(snap_n_tup_del)
                   OVER (ORDER BY b.snapshot_id), 0)                                 AS del,
    snap_n_tup_hot_upd
      - coalesce(lag(snap_n_tup_hot_upd)
                   OVER (ORDER BY b.snapshot_id), 0)                                 AS hotupd,
    snap_n_live_tup                                                                  AS alive,
    snap_n_dead_tup                                                                  AS dead
FROM
    snapshot.snap_summary_stat_all_tables a
    JOIN snapshot.snapshot b ON a.snapshot_id = b.snapshot_id
WHERE
    b.start_ts >= '$query_begin'::timestamp
    AND b.start_ts <= '$query_end'::timestamp
    AND a.db_name         = '$db_name'
    AND a.snap_schemaname = '$schema_name'
    AND a.snap_relname    = '$table_name'
ORDER BY 1;
EOF
}
