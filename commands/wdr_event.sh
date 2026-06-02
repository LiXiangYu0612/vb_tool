#!/bin/bash
# Command: wdr_event - WDR top events

wdr_event_help() {
    echo "Options for wdr_event:"
    echo "  Usage: vb_tool wdr_event [-b begin_time] [-e end_time]"
    echo "  Description: display wdr top event information"
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
    echo "    vb_tool wdr_event                                    # Today 00:00 to tomorrow 00:00"
    echo "    vb_tool wdr_event -b 2026-03-02                     # 2026-03-02 00:00 to tomorrow 00:00"
    echo "    vb_tool wdr_event -e 2026-03-03                     # Today 00:00 to 2026-03-03 00:00"
    echo "    vb_tool wdr_event -b \"2026-03-02 12\" -e \"2026-03-02 20\"  # 12:00 to 20:00 on 2026-03-02"
    echo "    vb_tool wdr_event -b \"2026-03-02 12:30\" -e \"2026-03-02 20:45\""
    echo ""
}
run_wdr_event() {
    local begin_time=""
    local end_time=""
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
\echo 'wdr topevent summary'
\echo '===================='
\echo '                          '
with time_range as (
    select snapshot_id, time_range, el
    from (
        select snapshot_id,
               to_char(lag(start_ts) over(order by snapshot_id),'mmdd hh24:mi')||'-'||to_char(start_ts,'hh24:mi') time_range,
               trunc(extract(epoch from (start_ts - lag(start_ts) over(order by snapshot_id)))) el
        from snapshot.snapshot a 
        where start_ts >= '$query_begin'::timestamp and start_ts <= '$query_end'::timestamp
    ) t
    where length(time_range)>15
),
time_model as (
    select snapshot_id,
    sum(decode(snap_stat_name,'DB_TIME',stat_value,0)) db_time,
    sum(decode(snap_stat_name,'CPU_TIME',stat_value,0)) cpu_time
    from (select snapshot_id,snap_stat_name,
          snap_value-lag(snap_value)over(partition by snap_node_name,snap_stat_name order by snapshot_id) stat_value
              from snapshot.snap_global_instance_time)
    group by snapshot_id
),
all_events as (
    select snapshot_id, 'CPU time' as event, '' as event_type,cpu_time as wait_time, null as waits, 1 as is_cpu
    from time_model
    
    union all
    
    select snapshot_id, event, event_type,wait_time, waits, 0 as is_cpu
    from (
        select snapshot_id, event, event_type,wait_time, waits, 
               row_number() over(partition by snapshot_id order by wait_time desc) rn 
        from (
            select snapshot_id, snap_event as event, snap_type as event_type,
                   snap_total_wait_time - coalesce(lag(snap_total_wait_time) over(partition by snap_event order by snapshot_id), 0) wait_time, 
                   snap_wait - coalesce(lag(snap_wait) over(partition by snap_event order by snapshot_id), 0) waits
            from snapshot.snap_global_wait_events 
            where snap_event not in ('none','wait cmd')
        ) where waits > 0
    ) where rn <= 9
),
ranked_events as (
    select snapshot_id, event,event_type, wait_time, waits, is_cpu,
           row_number() over(partition by snapshot_id order by wait_time desc) as rn
    from all_events 
)
select /*+set(enable_mergejoin off) set(enable_nestloop off) set(enable_index_nestloop off)*/time_range, round(db_time/1e6,1) db_time_s, 
       event, 
       event_type,
       round(wait_time/1e6,1) wait_time_s, 
       waits, 
       case when is_cpu = 1 then null else round(wait_time/waits/1e3,1) end as avg_wait_ms,
       round(100*(wait_time/db_time),1)||'%' db_time_pct
from time_range a, time_model b, ranked_events c 
where a.snapshot_id = b.snapshot_id 
  and a.snapshot_id = c.snapshot_id
  and c.rn<=5
order by a.time_range, c.rn;
EOF
}

