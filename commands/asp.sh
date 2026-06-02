#!/bin/bash
# Command: asp - Active session profile analysis

asp_help() {
    echo "Options for asp:"
    echo "  Usage: asp <type> -b <begin_time> -e <end_time>"
    echo "  Types:"
    echo "    cnt        active session count statistics"
    echo "    event      event analysis"
    echo "    waitchain  wait chain analysis"
    echo "    sql        running sql"
    echo "  Options:"
    echo "    -b: start time (format: 'YYYY-MM-DD HH24:MI:SS')"
    echo "    -e: end time (format: 'YYYY-MM-DD HH24:MI:SS')"
    echo ""
}
run_asp() {
    local query_type=$1
    shift
    
    local begin_time=""
    local end_time=""
    
    while getopts "b:e:" opt; do
        case $opt in
            b) begin_time="$OPTARG" ;;
            e) end_time="$OPTARG" ;;
            *) 
                echo "Error: Invalid option -$OPTARG"
                asp_help
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$query_type" || -z "$begin_time" || -z "$end_time" ]]; then
        echo "Error: type, start time and end time are all required"
        asp_help
        exit 1
    fi
    
    case "$query_type" in
        cnt)
            run_asp_cnt_query "$begin_time" "$end_time"
            ;;
        event)
            run_asp_event_query "$begin_time" "$end_time"
            ;;
        waitchain)
            run_asp_waitchain_query "$begin_time" "$end_time"
            ;;
        sql)
            run_asp_sql_query "$begin_time" "$end_time"
            ;;
        *)
            echo "Error: Invalid type '$query_type'"
            asp_help
            exit 1
            ;;
    esac
}


run_asp_cnt_query() {
# las_flag: Schema version identifier for the `local_active_session` table.
# The version is determined by the presence of specific columns.
#   0 - Table does not exist in the database.
#   3 - identified by the presence of both `cur_event` and `state` columns (and gs_asp.state).
#   4 - identified by the presence of an `event` column and the absence of a `state` column.
#   * - Reserved for future schema definitions; currently unuse	
    local las_flag=$(psql -qAtXc "select is_event + is_curevent + is_state as las_flag from (
                            select coalesce(sum(case when attname='event' then 4 else 0 end),0) is_event, 
                                   coalesce(sum(case when attname='cur_event' then 2 else 0 end),0)  is_curevent,
                                   coalesce(sum(case when attname='state' then 1 else 0 end),0)  is_state 
                            from pg_attribute a,pg_class b, pg_namespace c
                            where a.attrelid=b.oid 
                            and b.relnamespace=c.oid
                            and b.relname='local_active_session' 
                            and c.nspname='dbe_perf')")
    local begin_time=$(date -d "$1" +'%Y-%m-%d %H:%M:%S')
    local end_time=$(date -d "$2" +'%Y-%m-%d %H:%M:%S')

    if [[ "$las_flag" = 4 ||  "$las_flag" = 0 ]]; then
        condition1="1=1"
        condition2="a.event='wait wal sync'"
        condition3="a.event='wait transaction sync'"
        condition4="a.event=b.event"
		
	elif [[ "$las_flag" = 2 ]]; then
    condition1="1=1"
    condition2="a.cur_event='wait wal sync'"
    condition3="a.cur_event='wait transaction sync'"
    condition4="a.cur_event=b.event"
	
    else 
        condition1="state='active'"
        condition2="a.cur_event='wait wal sync'"
        condition3="a.cur_event='wait transaction sync'"
        condition4="a.cur_event=b.event"
    fi
 
    if [[ "$las_flag" = 0 ]]; then
	    psql -d postgres <<EOF
\pset footer off
\echo '=================================='
\echo '   active session history count '
\echo '=================================='
WITH time_counts AS (
        SELECT 'b' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        COUNT(*) AS cnt,
        sum(case when $condition1 then 1 else 0 end) active_cnt,
        sum(case when b.type='LOCK_EVENT'  then 1 else 0 end) wait_lock_cnt,
        sum(case when b.type='LWLOCK_EVENT'  then 1 else 0 end) wait_lwlock_cnt,
        sum(case when b.type='IO_EVENT'  then 1 else 0 end) wait_io_cnt,
        sum(case when a.event='wait wal sync' then 1 else 0 end) wait_wal_sync_cnt,
        sum(case when a.event='wait transaction sync' then 1 else 0 end) wait_trans_sync_cnt
    FROM 
        gs_asp a  left join dbe_perf.wait_events b on a.event=b.event 
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time'
    GROUP BY 
        sample_time::timestamp(0) without time zone
),
has_a_data AS (
    SELECT EXISTS(SELECT 1 FROM time_counts WHERE table_type = 'a') AS has_a_records
),
filtered_data AS (
    SELECT 
        table_type,
        sample_time,
        cnt,
        active_cnt,
        wait_lock_cnt,
        wait_lwlock_cnt,
        wait_io_cnt,
        wait_wal_sync_cnt,
        wait_trans_sync_cnt
    FROM 
        time_counts
    WHERE 
        table_type = CASE 
            WHEN (SELECT has_a_records FROM has_a_data) THEN 'a'
            ELSE 'b'
        END
),
five_min_intervals AS (
    SELECT 
        DATE_TRUNC('hour', sample_time) 
        + FLOOR(EXTRACT(MINUTE FROM sample_time) / 5) * INTERVAL '5 min' AS interval_start,
        table_type,
        cnt,
        active_cnt,
        wait_lock_cnt,
        wait_lwlock_cnt,
        wait_io_cnt,
        wait_wal_sync_cnt,
        wait_trans_sync_cnt
    FROM 
        filtered_data
)
SELECT /*+set(enable_nestloop off) set(enable_mergejoin off) set(enable_index_nestloop off)*/
    CASE 
        WHEN table_type = 'a' THEN '[local_active_session] ' 
        ELSE '[gs_asp] ' 
    END || 
    to_char(interval_start, 'YYYY-MM-DD HH24:MI:SS') || '-' || 
    to_char(interval_start + INTERVAL '5 minutes', 'HH24:MI:SS') AS date_time,
    MAX(cnt) AS max_sess,
    ROUND(AVG(cnt)) AS avg_sess,
    MAX(active_cnt) AS max_active_sess,
    MAX(wait_lock_cnt) AS wait_lock,
    MAX(wait_lwlock_cnt) AS wait_lwlock,
    MAX(wait_io_cnt) AS wait_io,
    MAX(wait_wal_sync_cnt) wait_wal_sync,
    MAX(wait_trans_sync_cnt) wait_trans_sync
FROM 
    five_min_intervals
GROUP BY 
    interval_start, table_type
ORDER BY 
    interval_start;
EOF
    else 
    psql -d postgres <<EOF
\pset footer off
\echo '=================================='
\echo '   active session history count '
\echo '=================================='
WITH time_counts AS (
    SELECT 'a' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        COUNT(*) AS cnt,
        sum(case when $condition1 then 1 else 0 end) active_cnt,
        sum(case when b.type='LOCK_EVENT' then 1 else 0 end) wait_lock_cnt,
        sum(case when b.type='LWLOCK_EVENT'  then 1 else 0 end) wait_lwlock_cnt,
        sum(case when b.type='IO_EVENT' then 1 else 0 end) wait_io_cnt,
        sum(case when $condition2 then 1 else 0 end) wait_wal_sync_cnt,
        sum(case when $condition3 then 1 else 0 end) wait_trans_sync_cnt
    FROM 
        dbe_perf.local_active_session a  left join dbe_perf.wait_events b on $condition4
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' 
    GROUP BY 
        sample_time::timestamp(0) without time zone
    UNION ALL 
    SELECT 'b' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        COUNT(*) AS cnt,
        sum(case when $condition1 then 1 else 0 end) active_cnt,
        sum(case when b.type='LOCK_EVENT'  then 1 else 0 end) wait_lock_cnt,
        sum(case when b.type='LWLOCK_EVENT'  then 1 else 0 end) wait_lwlock_cnt,
        sum(case when b.type='IO_EVENT'  then 1 else 0 end) wait_io_cnt,
        sum(case when a.event='wait wal sync' then 1 else 0 end) wait_wal_sync_cnt,
        sum(case when a.event='wait transaction sync' then 1 else 0 end) wait_trans_sync_cnt
    FROM 
        gs_asp a  left join dbe_perf.wait_events b on a.event=b.event 
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time'
    GROUP BY 
        sample_time::timestamp(0) without time zone
),
has_a_data AS (
    SELECT EXISTS(SELECT 1 FROM time_counts WHERE table_type = 'a') AS has_a_records
),
filtered_data AS (
    SELECT 
        table_type,
        sample_time,
        cnt,
        active_cnt,
        wait_lock_cnt,
        wait_lwlock_cnt,
        wait_io_cnt,
        wait_wal_sync_cnt,
        wait_trans_sync_cnt
    FROM 
        time_counts
    WHERE 
        table_type = CASE 
            WHEN (SELECT has_a_records FROM has_a_data) THEN 'a'
            ELSE 'b'
        END
),
five_min_intervals AS (
    SELECT 
        DATE_TRUNC('hour', sample_time) 
        + FLOOR(EXTRACT(MINUTE FROM sample_time) / 5) * INTERVAL '5 min' AS interval_start,
        table_type,
        cnt,
        active_cnt,
        wait_lock_cnt,
        wait_lwlock_cnt,
        wait_io_cnt,
        wait_wal_sync_cnt,
        wait_trans_sync_cnt
    FROM 
        filtered_data
)
SELECT /*+set(enable_nestloop off) set(enable_mergejoin off) set(enable_index_nestloop off)*/
    CASE 
        WHEN table_type = 'a' THEN '[local_active_session] ' 
        ELSE '[gs_asp] ' 
    END || 
    to_char(interval_start, 'YYYY-MM-DD HH24:MI:SS') || '-' || 
    to_char(interval_start + INTERVAL '5 minutes', 'HH24:MI:SS') AS date_time,
    MAX(cnt) AS max_sess,
    ROUND(AVG(cnt)) AS avg_sess,
    MAX(active_cnt) AS max_active_sess,
    MAX(wait_lock_cnt) AS wait_lock,
    MAX(wait_lwlock_cnt) AS wait_lwlock,
    MAX(wait_io_cnt) AS wait_io,
    MAX(wait_wal_sync_cnt) wait_wal_sync,
    MAX(wait_trans_sync_cnt) wait_trans_sync
FROM 
    five_min_intervals
GROUP BY 
    interval_start, table_type
ORDER BY 
    interval_start;
EOF
    fi
}

run_asp_sql_query() {
# las_flag: Schema version identifier for the `local_active_session` table.
# The version is determined by the presence of specific columns.
#   0 - Table does not exist in the database.
#   3 - identified by the presence of both `cur_event` and `state` columns (and gs_asp.state).
#   4 - identified by the presence of an `event` column and the absence of a `state` column.
#   * - Reserved for future schema definitions; currently unuse	
    local las_flag=$(psql -qAtXc "select is_event + is_curevent + is_state as las_flag from (
                            select coalesce(sum(case when attname='event' then 4 else 0 end),0) is_event, 
                                   coalesce(sum(case when attname='cur_event' then 2 else 0 end),0)  is_curevent,
                                   coalesce(sum(case when attname='state' then 1 else 0 end),0)  is_state 
                            from pg_attribute a,pg_class b, pg_namespace c
                            where a.attrelid=b.oid 
                            and b.relnamespace=c.oid
                            and b.relname='local_active_session' 
                            and c.nspname='dbe_perf')")
    local begin_time=$(date -d "$1" +'%Y-%m-%d %H:%M:%S')
    local end_time=$(date -d "$2" +'%Y-%m-%d %H:%M:%S')

    if [[ "$las_flag" = 4 ||  "$las_flag" = 0 ]]; then
        condition1="1=1"
        condition4="a.event=b.event"
        condition5="a.event"
	
	elif [[ "$las_flag" = 2 ]]; then
    condition1="1=1"
    condition4="a.cur_event=b.event"
    condition5="a.cur_event"
	
    else 
        condition1="state='active'"
        condition4="a.cur_event=b.event"
        condition5="a.cur_event"
    fi
	
    if [[ "$las_flag" = 0 ]]; then
    psql -d postgres <<EOF
\pset footer off
\echo '==================================' 
\echo '   active session history topsql  '
\echo '=================================='
WITH time_counts AS (
        SELECT 'b' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        a.unique_query_id as unique_query_id,
        substr(REGEXP_REPLACE(REGEXP_REPLACE(unique_query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) unique_query,
        COUNT(*) AS cnt    
    FROM 
        gs_asp a left join dbe_perf.wait_events b on a.event=b.event
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' and $condition1 and a.event not in ('none') and unique_query_id>0
    GROUP BY 
        sample_time::timestamp(0) without time zone, a.unique_query_id,substr(REGEXP_REPLACE(REGEXP_REPLACE(unique_query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)
),
has_a_data AS (
    SELECT EXISTS(SELECT 1 FROM time_counts WHERE table_type = 'a') AS has_a_records
),
filtered_data AS (
    SELECT *
    FROM 
        time_counts
    WHERE 
        table_type = CASE 
            WHEN (SELECT has_a_records FROM has_a_data) THEN 'a'
            ELSE 'b'
        END
),
five_min_intervals AS (
    SELECT 
        DATE_TRUNC('hour', sample_time) 
        + FLOOR(EXTRACT(MINUTE FROM sample_time) / 5) * INTERVAL '5 min' AS interval_start,
        filtered_data.*
    FROM 
        filtered_data
),
ranked_data AS (
    SELECT 
        CASE 
            WHEN table_type = 'a' THEN '[local_active_session] ' 
            ELSE '[gs_asp] ' 
        END || 
        to_char(interval_start, 'YYYY-MM-DD HH24:MI:SS') || '-' || 
        to_char(interval_start + INTERVAL '5 minutes', 'HH24:MI:SS') AS date_time,
        unique_query_id,
        unique_query,
        max(cnt) max_cnt,
        round(avg(cnt)) avg_cnt,
        ROW_NUMBER() OVER (PARTITION BY date_time ORDER BY max(cnt) DESC) AS row_num
    FROM 
        five_min_intervals
    GROUP BY 
        interval_start, table_type, unique_query_id,unique_query
)
SELECT 
    date_time,
    unique_query_id,
    unique_query,
    max_cnt,
    avg_cnt
FROM 
    ranked_data
WHERE 
    row_num <= 5
ORDER BY 
    date_time, max_cnt DESC;
EOF
    else 
    psql -d postgres <<EOF
\pset footer off
\echo '==================================' 
\echo '   active session history topsql  '
\echo '=================================='
WITH time_counts AS (
    SELECT 'a' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        a.unique_query_id as unique_query_id,
        substr(REGEXP_REPLACE(REGEXP_REPLACE(unique_query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) unique_query,
        COUNT(*) AS cnt        
    FROM 
        dbe_perf.local_active_session a left join dbe_perf.wait_events b on $condition4
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' and $condition1 and $condition5 not in ('none') and unique_query_id>0
    GROUP BY 
        sample_time::timestamp(0) without time zone, a.unique_query_id,substr(REGEXP_REPLACE(REGEXP_REPLACE(unique_query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)
    UNION ALL 
    SELECT 'b' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        a.unique_query_id as unique_query_id,
        substr(REGEXP_REPLACE(REGEXP_REPLACE(unique_query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) unique_query,
        COUNT(*) AS cnt    
    FROM 
        gs_asp a left join dbe_perf.wait_events b on a.event=b.event
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' and $condition1 and a.event not in ('none') and unique_query_id>0
    GROUP BY 
        sample_time::timestamp(0) without time zone, a.unique_query_id,substr(REGEXP_REPLACE(REGEXP_REPLACE(unique_query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)
),
has_a_data AS (
    SELECT EXISTS(SELECT 1 FROM time_counts WHERE table_type = 'a') AS has_a_records
),
filtered_data AS (
    SELECT *
    FROM 
        time_counts
    WHERE 
        table_type = CASE 
            WHEN (SELECT has_a_records FROM has_a_data) THEN 'a'
            ELSE 'b'
        END
),
five_min_intervals AS (
    SELECT 
        DATE_TRUNC('hour', sample_time) 
        + FLOOR(EXTRACT(MINUTE FROM sample_time) / 5) * INTERVAL '5 min' AS interval_start,
        filtered_data.*
    FROM 
        filtered_data
),
ranked_data AS (
    SELECT 
        CASE 
            WHEN table_type = 'a' THEN '[local_active_session] ' 
            ELSE '[gs_asp] ' 
        END || 
        to_char(interval_start, 'YYYY-MM-DD HH24:MI:SS') || '-' || 
        to_char(interval_start + INTERVAL '5 minutes', 'HH24:MI:SS') AS date_time,
        unique_query_id,
        unique_query,
        max(cnt) max_cnt,
        round(avg(cnt)) avg_cnt,
        ROW_NUMBER() OVER (PARTITION BY date_time ORDER BY max(cnt) DESC) AS row_num
    FROM 
        five_min_intervals
    GROUP BY 
        interval_start, table_type, unique_query_id,unique_query
)
SELECT 
    date_time,
    unique_query_id,
    unique_query,
    max_cnt,
    avg_cnt
FROM 
    ranked_data
WHERE 
    row_num <= 5
ORDER BY 
    date_time, max_cnt DESC;
EOF
    fi
}

run_asp_event_query() {
 # las_flag: Schema version identifier for the `local_active_session` table.
# The version is determined by the presence of specific columns.
#   0 - Table does not exist in the database.
#   3 - identified by the presence of both `cur_event` and `state` columns (and gs_asp.state).
#   4 - identified by the presence of an `event` column and the absence of a `state` column.
#   * - Reserved for future schema definitions; currently unuse	
   local las_flag=$(psql -qAtXc "select is_event + is_curevent + is_state as las_flag from (
                            select coalesce(sum(case when attname='event' then 4 else 0 end),0) is_event, 
                                   coalesce(sum(case when attname='cur_event' then 2 else 0 end),0)  is_curevent,
                                   coalesce(sum(case when attname='state' then 1 else 0 end),0)  is_state 
                            from pg_attribute a,pg_class b, pg_namespace c
                            where a.attrelid=b.oid 
                            and b.relnamespace=c.oid
                            and b.relname='local_active_session' 
                            and c.nspname='dbe_perf')")
							
    local begin_time=$(date -d "$1" +'%Y-%m-%d %H:%M:%S')
    local end_time=$(date -d "$2" +'%Y-%m-%d %H:%M:%S')

    if [[ "$las_flag" = 4 ||  "$las_flag" = 0 ]]; then
        condition1="1=1"
        condition4="a.event=b.event"
        condition5="a.event"
		
	elif [[ "$las_flag" = 2 ]]; then
        condition1="1=1"
        condition4="a.cur_event=b.event"
        condition5="a.cur_event"
	
    else 
        condition1="a.state='active'"
        condition4="a.cur_event=b.event"
        condition5="a.cur_event"
    fi
	
    if [[ "$las_flag" = 0 ]]; then	
   psql -d postgres <<EOF
\pset footer off
\echo '=================================='
\echo '   active session history event   '
\echo '=================================='
WITH time_counts AS (
        SELECT 'b' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        type event_type,
        a.event as event,
        COUNT(*) AS cnt    
    FROM 
        gs_asp a left join dbe_perf.wait_events b on a.event=b.event
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' and $condition1 and a.event not in ('none')
    GROUP BY 
        sample_time::timestamp(0) without time zone,type,a.event
),
has_a_data AS (
    SELECT EXISTS(SELECT 1 FROM time_counts WHERE table_type = 'a') AS has_a_records
),
filtered_data AS (
    SELECT *
    FROM 
        time_counts
    WHERE 
        table_type = CASE 
            WHEN (SELECT has_a_records FROM has_a_data) THEN 'a'
            ELSE 'b'
        END
),
five_min_intervals AS (
    SELECT 
        DATE_TRUNC('hour', sample_time) 
        + FLOOR(EXTRACT(MINUTE FROM sample_time) / 5) * INTERVAL '5 min' AS interval_start,
        filtered_data.*
    FROM 
        filtered_data
)
SELECT /*+set(enable_nestloop off) set(enable_mergejoin off) set(enable_index_nestloop off)*/
    CASE 
        WHEN table_type = 'a' THEN '[local_active_session] ' 
        ELSE '[gs_asp] ' 
    END || 
    to_char(interval_start, 'YYYY-MM-DD HH24:MI:SS') || '-' || 
    to_char(interval_start + INTERVAL '5 minutes', 'HH24:MI:SS') AS date_time,
    event_type,
    event,
    max(cnt) max_cnt,
    round(avg(cnt)) avg_cnt
FROM 
    five_min_intervals
GROUP BY 
    interval_start, table_type,event_type,event
ORDER BY 
    interval_start,max_cnt;
EOF
    else 
   psql -d postgres <<EOF
\pset footer off
\echo '=================================='
\echo '   active session history event   '
\echo '=================================='
WITH time_counts AS (
    SELECT 'a' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        type as event_type,
        $condition5 as event,
        COUNT(*) AS cnt        
    FROM 
        dbe_perf.local_active_session a left join dbe_perf.wait_events b on $condition4
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' and $condition1 and $condition5 not in ('none')
    GROUP BY 
        sample_time::timestamp(0) without time zone,type,$condition5
    UNION ALL 
    SELECT 'b' AS table_type,
        sample_time::timestamp(0) without time zone AS sample_time,
        type event_type,
        a.event as event,
        COUNT(*) AS cnt    
    FROM 
        gs_asp a left join dbe_perf.wait_events b on a.event=b.event
    WHERE 
        sample_time BETWEEN '$begin_time' AND '$end_time' and $condition1 and a.event not in ('none')
    GROUP BY 
        sample_time::timestamp(0) without time zone,type,a.event
),
has_a_data AS (
    SELECT EXISTS(SELECT 1 FROM time_counts WHERE table_type = 'a') AS has_a_records
),
filtered_data AS (
    SELECT *
    FROM 
        time_counts
    WHERE 
        table_type = CASE 
            WHEN (SELECT has_a_records FROM has_a_data) THEN 'a'
            ELSE 'b'
        END
),
five_min_intervals AS (
    SELECT 
        DATE_TRUNC('hour', sample_time) 
        + FLOOR(EXTRACT(MINUTE FROM sample_time) / 5) * INTERVAL '5 min' AS interval_start,
        filtered_data.*
    FROM 
        filtered_data
)
SELECT /*+set(enable_nestloop off) set(enable_mergejoin off) set(enable_index_nestloop off)*/
    CASE 
        WHEN table_type = 'a' THEN '[local_active_session] ' 
        ELSE '[gs_asp] ' 
    END || 
    to_char(interval_start, 'YYYY-MM-DD HH24:MI:SS') || '-' || 
    to_char(interval_start + INTERVAL '5 minutes', 'HH24:MI:SS') AS date_time,
    event_type,
    event,
    max(cnt) max_cnt,
    round(avg(cnt)) avg_cnt
FROM 
    five_min_intervals
GROUP BY 
    interval_start, table_type,event_type,event
ORDER BY 
    interval_start,max_cnt;
EOF
    fi
}


run_asp_waitchain_query() {
# las_flag: Schema version identifier for the `local_active_session` table.
# The version is determined by the presence of specific columns.
#   0 - Table does not exist in the database.
#   3 - identified by the presence of both `cur_event` and `state` columns (and gs_asp.state).
#   4 - identified by the presence of an `event` column and the absence of a `state` column.
#   * - Reserved for future schema definitions; currently unuse	
    local las_flag=$(psql -qAtXc "select is_event + is_curevent + is_state as las_flag from (
                            select coalesce(sum(case when attname='event' then 4 else 0 end),0) is_event, 
                                   coalesce(sum(case when attname='cur_event' then 2 else 0 end),0)  is_curevent,
                                   coalesce(sum(case when attname='state' then 1 else 0 end),0)  is_state 
                            from pg_attribute a,pg_class b, pg_namespace c
                            where a.attrelid=b.oid 
                            and b.relnamespace=c.oid
                            and b.relname='local_active_session' 
                            and c.nspname='dbe_perf')")
    local begin_time=$(date -d "$1" +'%Y-%m-%d %H:%M:%S')
    local end_time=$(date -d "$2" +'%Y-%m-%d %H:%M:%S')

    if [[ "$las_flag" = 4 ||  "$las_flag" = 0 ]]; then
        condition1="1=1"
        condition4="a.event=b.event"
        condition5="a.event"
        condition6="1=1"
        condition7="1=1"
		condition8="' '"
		condition9="' '"
		
	elif [[ "$las_flag" = 2 ]]; then
        condition1="1=1"
        condition4="a.cur_event=b.event"
        condition5="a.cur_event"
        condition6="1=1"
        condition7="1=1"	
		condition8="' '"
		condition9="' '"
		
    else 
        condition1="state='active'"
        condition4="a.cur_event=b.event"
        condition5="a.cur_event"
        condition6="a.state='active'"
        condition7="las.state='active'"		
		condition8="a.xact_start_time::timestamp(0)"
		condition9="las.xact_start_time::timestamp(0)"
    fi   

    if [[ "$las_flag" = 0 ]]; then	
	psql -d postgres <<EOF

\echo '==================================='
\echo '       waitchain from gs_asp       '
\echo '==================================='
with RECURSIVE gs_asp_1 as (SELECT * from gs_asp where sample_time::timestamp(0) without time zone BETWEEN '$begin_time' AND '$end_time'),
blocking_chain AS (
    SELECT 
        sampleid,
        sessionid AS blocked_sessionid,
        block_sessionid AS blocker_sessionid,
        1 AS level,
        ARRAY[sessionid] AS path
    FROM gs_asp_1
    WHERE block_sessionid IS NOT NULL   
    UNION ALL
     SELECT 
        bc.sampleid,
        bc.blocked_sessionid,
        a.block_sessionid AS blocker_sessionid,
        bc.level + 1,
        bc.path || a.sessionid
    FROM blocking_chain bc
    JOIN gs_asp_1 a ON bc.sampleid = a.sampleid 
                  AND bc.blocker_sessionid = a.sessionid
    WHERE a.block_sessionid IS NOT NULL
      AND NOT a.sessionid = ANY(bc.path)
),
root_blockers AS (
    SELECT 
        sampleid,
        blocked_sessionid,
        blocker_sessionid AS root_blocker,
        level
    FROM blocking_chain
    WHERE NOT EXISTS (
        SELECT 1 FROM gs_asp_1 a 
        WHERE a.sampleid = blocking_chain.sampleid 
          AND a.sessionid = blocking_chain.blocker_sessionid
          AND a.block_sessionid IS NOT NULL
    )
),
blocker_stats AS (
    SELECT 
        sampleid,
        root_blocker,
        COUNT(blocked_sessionid) AS blocked_count,
        MIN(blocked_sessionid) AS example_blocked_sessionid
    FROM root_blockers
    GROUP BY sampleid, root_blocker
)
SELECT /*+set(enable_mergejoin off) set(enable_nestloop off) set(enable_index_nestloop off)*/ 
    las.sample_time::timestamp(0) without time zone sample_time,
    las.sessionid||'('||case when $condition7 then 'a' else 'iit' end||')'||'('||$condition9||')' root_block_sessid,
    bs.blocked_count as b_cnt,
    substr(las.unique_query,1,50) h_sql,
    substr(blocked_las.unique_query,1,50) w_sql
FROM blocker_stats bs
JOIN gs_asp_1 las ON bs.sampleid = las.sampleid 
                                      AND bs.root_blocker = las.sessionid
JOIN gs_asp_1 blocked_las ON bs.sampleid = blocked_las.sampleid 
                                              AND bs.example_blocked_sessionid = blocked_las.sessionid
ORDER BY bs.sampleid, bs.blocked_count DESC; 
EOF
	else 
	psql -d postgres <<EOF
\pset footer off
\echo '==================================='
\echo 'waitchain from local_active_session'
\echo '==================================='
WITH blocked_sessions AS (
    SELECT 
        sampleid,
        sample_time::timestamp(0) without time zone AS sample_time,
        final_block_sessionid,
        wait_status,
        max(sessionid) w_sessionid,
        count(*) cnt
    FROM 
        dbe_perf.local_active_session
    WHERE 
        sample_time::timestamp(0) without time zone BETWEEN '$begin_time' AND '$end_time'
        AND $condition1
        AND final_block_sessionid IS NOT NULL 
    group by sampleid,sample_time::timestamp(0) without time zone,final_block_sessionid,wait_status
)
 SELECT /*+set(enable_mergejoin off) set(enable_nestloop off) set(enable_index_nestloop off)*/ a.sample_time::timestamp(0) without time zone sample_time,b.final_block_sessionid||'('||case when $condition6 then 'a' else 'iit' end||')'||'('||$condition8||')' root_block_sessid,b.cnt as b_cnt,substr(a.unique_query,1,50) h_sql,substr(c.unique_query,1,50) w_sql
    FROM 
        dbe_perf.local_active_session a,blocked_sessions b,dbe_perf.local_active_session c
    WHERE a.sampleid=b.sampleid and b.final_block_sessionid=a.sessionid and b.sampleid=c.sampleid and b.w_sessionid=c.sessionid
    ORDER BY 
        a.sample_time::timestamp(0) without time zone,
        b.final_block_sessionid;
        
\echo '==================================='
\echo '       waitchain from gs_asp       '
\echo '==================================='
with RECURSIVE gs_asp_1 as (SELECT * from gs_asp where sample_time::timestamp(0) without time zone BETWEEN '$begin_time' AND '$end_time'),
blocking_chain AS (
    SELECT 
        sampleid,
        sessionid AS blocked_sessionid,
        block_sessionid AS blocker_sessionid,
        1 AS level,
        ARRAY[sessionid] AS path
    FROM gs_asp_1
    WHERE block_sessionid IS NOT NULL   
    UNION ALL
     SELECT 
        bc.sampleid,
        bc.blocked_sessionid,
        a.block_sessionid AS blocker_sessionid,
        bc.level + 1,
        bc.path || a.sessionid
    FROM blocking_chain bc
    JOIN gs_asp_1 a ON bc.sampleid = a.sampleid 
                  AND bc.blocker_sessionid = a.sessionid
    WHERE a.block_sessionid IS NOT NULL
      AND NOT a.sessionid = ANY(bc.path)
),
root_blockers AS (
    SELECT 
        sampleid,
        blocked_sessionid,
        blocker_sessionid AS root_blocker,
        level
    FROM blocking_chain
    WHERE NOT EXISTS (
        SELECT 1 FROM gs_asp_1 a 
        WHERE a.sampleid = blocking_chain.sampleid 
          AND a.sessionid = blocking_chain.blocker_sessionid
          AND a.block_sessionid IS NOT NULL
    )
),
blocker_stats AS (
    SELECT 
        sampleid,
        root_blocker,
        COUNT(blocked_sessionid) AS blocked_count,
        MIN(blocked_sessionid) AS example_blocked_sessionid
    FROM root_blockers
    GROUP BY sampleid, root_blocker
)
SELECT /*+set(enable_mergejoin off) set(enable_nestloop off) set(enable_index_nestloop off)*/ 
    las.sample_time::timestamp(0) without time zone sample_time,
    las.sessionid||'('||case when $condition7 then 'a' else 'iit' end||')'||'('||$condition9||')' root_block_sessid,
    bs.blocked_count as b_cnt,
    substr(las.unique_query,1,50) h_sql,
    substr(blocked_las.unique_query,1,50) w_sql
FROM blocker_stats bs
JOIN gs_asp_1 las ON bs.sampleid = las.sampleid 
                                      AND bs.root_blocker = las.sessionid
JOIN gs_asp_1 blocked_las ON bs.sampleid = blocked_las.sampleid 
                                              AND bs.example_blocked_sessionid = blocked_las.sessionid
ORDER BY bs.sampleid, bs.blocked_count DESC; 
EOF
    fi
}

