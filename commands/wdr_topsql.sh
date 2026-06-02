#!/bin/bash
# Command: wdr_topsql - WDR top SQL

wdr_topsql_help() {
    echo "Options for wdr_topsql:"
    echo "  Usage: vb_tool wdr_topsql [-b begin_time] [-e end_time] [-n top_n] [-t order_type]"
    echo "  Description: display top SQL information"
    echo ""
    echo "  Options:"
    echo "    -b begin_time    Begin time (default: today 00:00:00)"
    echo "    -e end_time      End time (default: tomorrow 00:00:00)"
    echo "    -n top_n         Number of top SQL to display (default: 10)"
    echo "    -t order_type    Order by: 1=time, 2=cpu, 3=io (default: 1)"
    echo ""
    echo "  Time Formats:"
    echo "    YYYY-MM-DD              (e.g., 2026-03-02)"
    echo "    YYYY-MM-DD HH           (e.g., 2026-03-02 12)"
    echo "    YYYY-MM-DD HH:MM        (e.g., 2026-03-02 12:30)"
    echo "    YYYY-MM-DD HH:MM:SS     (e.g., 2026-03-02 12:30:00)"
    echo ""
    echo "  Notes:"
    echo "    - Time values with spaces must be quoted"
    echo "    - Begin time automatically subtracts 1 hour"
    echo "    - End time automatically adds 1 hour"
    echo ""
    echo "  Examples:"
    echo "    vb_tool wdr_topsql                                         # Today 00:00 to tomorrow 00:00, top 10 by time"
    echo "    vb_tool wdr_topsql -b 2026-03-02 -e 2026-03-03           # 2026-03-02 to 2026-03-03"
    echo "    vb_tool wdr_topsql -n 20 -t 2                             # Top 20 by cpu"
    echo "    vb_tool wdr_topsql -b \"2026-03-02 12\" -e \"2026-03-02 20\" -n 15 -t 3"
    echo ""
}
run_wdr_topsql() {
    local begin_time=""
    local end_time=""
    local top_n="10"
    local order_type="1"
    local found_b=0
    local found_e=0
    local found_n=0
    local found_t=0
    
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
            -n)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -n requires a value" >&2
                    return 1
                fi
                if [[ ! "$1" =~ ^[0-9]+$ ]]; then
                    echo "Error: -n must be a number: $1" >&2
                    return 1
                fi
                top_n="$1"
                found_n=1
                shift
                ;;
            -t)
                shift
                if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                    echo "Error: -t requires a value" >&2
                    return 1
                fi
                if [[ ! "$1" =~ ^[1-3]$ ]]; then
                    echo "Error: -t must be 1 (time), 2 (cpu), or 3 (io): $1" >&2
                    return 1
                fi
                order_type="$1"
                found_t=1
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
\echo '===================='
\echo '   topsql summary   '
\echo '===================='
\echo '                          '
with time_range as (
select * from (
SELECT snapshot_id,
       to_char(start_ts, 'mmdd hh24:mi') || '-' || COALESCE(to_char(lead(start_ts) OVER (ORDER BY snapshot_id), 'hh24:mi'), to_char(now(), 'hh24:mi')) time_range, 
           trunc(extract(epoch FROM (COALESCE(lead(start_ts) OVER (ORDER BY snapshot_id), now()) - start_ts))) el 
FROM snapshot.snapshot a
  where start_ts >= '$query_begin'::timestamp and start_ts <= '$query_end'::timestamp
  ) where el<=7200),
total_sql as (
select snapshot_id,user_name,unique_sql_id,n_calls,round((n_blocks_fetched-n_blocks_hit)) total_pr,
round(total_elapse_time/1e3/n_calls,1) avg_tt_ms,
round(execution_time/1e3/n_calls,1) avg_et_ms,
round(cpu_time/1e3/n_calls,1) avg_cpu_ms,
round(data_io_time/1e3/n_calls,1) avg_io_ms,
round(n_blocks_fetched/n_calls,1) avg_cr,
round((n_blocks_fetched-n_blocks_hit)/n_calls,1) avg_pr,
round(100*ratio_to_report(total_elapse_time)over(partition by snapshot_id),1) time_pct,
round(100*ratio_to_report(cpu_time)over(partition by snapshot_id),1)  cpu_pct,
round(100*ratio_to_report(data_io_time)over(partition by snapshot_id),1) io_pct,
row_number()over(partition by snapshot_id order by 
                 case $order_type 
                   when 1 then total_elapse_time 
                   when 2 then cpu_time 
                   when 3 then data_io_time 
                   else total_elapse_time 
                 end desc) rn
from (select  snapshot_id,user_name,unique_sql_id,
        n_calls-coalesce(lag(n_calls)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) n_calls,
        total_elapse_time-coalesce(lag(total_elapse_time)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) total_elapse_time,
        execution_time-coalesce(lag(execution_time)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) execution_time,
        cpu_time-coalesce(lag(cpu_time)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) cpu_time,
        data_io_time-coalesce(lag(data_io_time)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) data_io_time,
        n_blocks_fetched-coalesce(lag(n_blocks_fetched)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) n_blocks_fetched,
        n_blocks_hit-coalesce(lag(n_blocks_hit)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) n_blocks_hit,
        n_returned_rows-coalesce(lag(n_returned_rows)over(partition by user_name,unique_sql_id order by a.snapshot_id),0) n_returned_rows        
from (select t1.snapshot_id,user_name,unique_sql_id,n_calls,total_elapse_time,n_returned_rows,n_blocks_fetched,n_blocks_hit,db_time,cpu_time,execution_time,data_io_time   
from dbe_perf.statement t,(select max(snapshot_id)+1 snapshot_id from snapshot.snap_summary_statement) t1
union all
select snapshot_id,snap_user_name,snap_unique_sql_id,snap_n_calls,snap_total_elapse_time,snap_n_returned_rows,snap_n_blocks_fetched,snap_n_blocks_hit,snap_db_time,snap_cpu_time,snap_execution_time,snap_data_io_time from snapshot.snap_summary_statement) a) 
where n_calls>0)
select t1.time_range,user_name uname,unique_sql_id sql_id,n_calls calls,total_pr,avg_tt_ms avg_tt,avg_et_ms avg_et,avg_cpu_ms avg_cpu,avg_io_ms avg_io,avg_cr,avg_pr,
       case $order_type 
         when 1 then time_pct 
         when 2 then cpu_pct 
         when 3 then io_pct 
         else time_pct 
       end "pct%"
from time_range t1 
left join total_sql t2 on t1.snapshot_id=t2.snapshot_id
where rn<=$top_n
order by 1 desc, 
         case $order_type 
           when 1 then time_pct 
           when 2 then cpu_pct 
           when 3 then io_pct 
           else time_pct 
         end desc;
EOF
}
