#!/bin/bash
# Command: wdr_summary - WDR workload summary

wdr_summary_help() {
    echo "Options for wdr_summary:"
    echo "  Usage: vb_tool wdr_summary [-b begin_time] [-e end_time]"
    echo "  Description: display wdr workload information"
    echo ""
    echo "  Options:"
    echo "    -b begin_time    Begin time (default: today 00:00:00)"
    echo "    -e end_time      End time (default: tomorrow 00:00:00)"
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
    echo "    vb_tool wdr_summary                                    # Today 00:00 to tomorrow 00:00"
    echo "    vb_tool wdr_summary -b 2026-03-02                     # 2026-03-02 00:00 to tomorrow 00:00"
    echo "    vb_tool wdr_summary -e 2026-03-03                     # Today 00:00 to 2026-03-03 00:00"
    echo "    vb_tool wdr_summary -b \"2026-03-02 12\" -e \"2026-03-02 20\"  # 12:00 to 20:00 on 2026-03-02"
    echo "    vb_tool wdr_summary -b \"2026-03-02 12:30\" -e \"2026-03-02 20:45\""
    echo ""
}
run_wdr_summary() {
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
\echo 'wdr workload summary'
\echo '===================='
\echo '                          '
with time_range as (
   select snapshot_id,
           to_char(lag(start_ts) over(order by snapshot_id),'mmdd hh24:mi')||'-'||to_char(start_ts,'hh24:mi') time_range,
           trunc(extract(epoch from (start_ts - lag(start_ts) over(order by snapshot_id)))) el
    from snapshot.snapshot a
  where start_ts >= '$query_begin'::timestamp and start_ts <= '$query_end'::timestamp),
time_model as (
select snapshot_id,
round(sum(decode(snap_stat_name,'DB_TIME',stat_value,0))/1e6,1) db_time,
round(sum(decode(snap_stat_name,'CPU_TIME',stat_value,0))/1e6,1) cpu_time,
round(sum(decode(snap_stat_name,'DATA_IO_TIME',stat_value,0))/1e6,1) data_io_time,
round(sum(decode(snap_stat_name,'EXECUTION_TIME',stat_value,0))/1e6,1) execution_time,
round(sum(decode(snap_stat_name,'PL_EXECUTION_TIME',stat_value,0))/1e6,1) pl_execution_time,
round(sum(decode(snap_stat_name,'PLAN_TIME',stat_value,0))/1e6,1) plan_time,
round(sum(decode(snap_stat_name,'REWRITE_TIME',stat_value,0))/1e6,1) rewrite_time,
round(sum(decode(snap_stat_name,'PARSE_TIME',stat_value,0))/1e6,1) parse_time,
round(sum(decode(snap_stat_name,'PL_COMPILATION_TIME',stat_value,0))/1e6,1) pl_compilation_time,
round(sum(decode(snap_stat_name,'NET_SEND_TIME',stat_value,0))/1e6,1) net_send_time
from (select snapshot_id,snap_stat_name,
      snap_value-lag(snap_value)over(partition by snap_node_name,snap_stat_name order by snapshot_id) stat_value
          from snapshot.snap_global_instance_time)
group by snapshot_id),
tps as (
select snapshot_id,trans-lag(trans)over(order by snapshot_id) total_trans,cr-lag(cr)over(order by snapshot_id) total_cr,hit-lag(hit)over(order by snapshot_id) total_hit
from (select snapshot_id,sum(snap_xact_commit+snap_xact_rollback) trans,sum(snap_blks_read) cr,sum(snap_blks_hit) hit
  from snapshot.snap_summary_stat_database
 group by snapshot_id)),
sql as (
select snapshot_id,n_calls-lag(n_calls)over(order by snapshot_id) calls,parse-lag(parse)over(order by snapshot_id) parse,hard-lag(hard)over(order by snapshot_id) hard from (
select snapshot_id,sum(snap_n_calls) n_calls,sum(snap_n_soft_parse+snap_n_hard_parse) parse,sum(snap_n_hard_parse) hard from snapshot.snap_summary_statement group by snapshot_id)),
iops as (
select snapshot_id,(snap_phyrds)-lag(snap_phyrds)over(order by snapshot_id) snap_phyrds,
                                   (snap_phywrts)-lag(snap_phywrts)over(order by snapshot_id) snap_phywrts,
                                   (snap_phyblkrd)-lag(snap_phyblkrd)over(order by snapshot_id) snap_phyblkrd,
                                   (snap_phyblkwrt)-lag(snap_phyblkwrt)over(order by snapshot_id) snap_phyblkwrt
                from (select snapshot_id,sum(snap_phyrds) snap_phyrds,sum(snap_phywrts) snap_phywrts,sum(snap_phyblkrd) snap_phyblkrd,sum(snap_phyblkwrt) snap_phyblkwrt from snapshot.snap_summary_file_iostat group by snapshot_id)),
redo as (
select  snapshot_id,redo_phywrts-lag(redo_phywrts)over(order by snapshot_id) redo_phywrts,redo_phyblkwrt-lag(redo_phyblkwrt)over(order by snapshot_id) redo_phyblkwrt
from (select snapshot_id,sum(snap_phywrts) as redo_phywrts, sum(snap_phyblkwrt) as redo_phyblkwrt from snapshot.snap_summary_file_redo_iostat group by snapshot_id))
select /*+leading(t1 t2 t3 t4 t5 t6) set(rewrite_rule 'magicset,predpushnormal')*/time_range,round(db_time/60,1) dbtime,round(db_time/el,1) aas,round(cpu_time/60,1) cputime,round(data_io_time/60,1) iotime,round(total_trans/el,1) tps,round(total_cr/el,1) "cr/s",round((snap_phyrds+snap_phywrts)/el,1) iops,round((snap_phyblkrd+snap_phyblkwrt)*8/1024/el,1) mbps,round(redo_phyblkwrt*8/1024/el,1) "wal_mb/s",round(calls/el,1) "call/s",round(parse/el,1) "parse/s",round(hard/el,1) "hard/s"
from time_range t1,time_model t2,tps t3,iops t4,redo t5,sql t6
where t1.snapshot_id=t2.snapshot_id
  and t1.snapshot_id=t3.snapshot_id
  and t1.snapshot_id=t4.snapshot_id
  and t1.snapshot_id=t5.snapshot_id
  and t1.snapshot_id=t6.snapshot_id
  and db_time>0 and length(time_range)>15 order by 1 desc;
EOF
}

