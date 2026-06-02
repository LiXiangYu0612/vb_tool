#!/bin/bash
# Command: mem - display memory usage information

mem_help() {
    echo "Options for mem:"
    echo "  Usage: vb_tool mem"
    echo "  Description: display memory usage information"
    echo ""
}

run_mem() {
    echo "====================" && \
    echo " os memory monitor" && \
    echo "====================" && \
    free -m && \
    echo "====================" && \
    echo "    memory info" && \
    echo "====================" && \
    (cat /proc/meminfo | grep -i -E "shm|active|buffer|cache|free|swap|slab|srec|sunr|dirty|pagetable|top|total|ava" | \
      grep -v Cma | grep -v HugePages | grep -v Vmall | \
      awk 'BEGIN {count=0} {printf "%-20s %12s kB\t", $1, $2; count++; if(count%3==0) print ""} END {if(count%3!=0) print ""}' | \
      column -t -s $'\t') && \
    echo "====================" && \
    echo " Paging statistics" && \
    echo "====================" && \
    sar -B 1 1 | grep -v Linux | grep -v Ave && \
    echo "====================" && \
    echo "    memory frag" && \
    echo "====================" && \
    cat /proc/buddyinfo && \
    psql -d postgres<<EOF
\pset footer off
\echo ====================
\echo      memory guc
\echo ====================
select name,setting,unit,context
from pg_settings where name in (
'maintenance_work_mem','work_mem','shared_buffers','max_process_memory',
'wal_buffers','effective_cache_size','cstore_buffers','segment_buffers','temp_buffers'
,'local_syscache_threshold','max_connections'
);

\echo ====================
\echo total memory detail
\echo ====================
select memorytype,pg_size_pretty(memorymbytes*1024*1024::numeric(100,0)) size from dbe_perf.memory_node_detail where memorymbytes>0;

\echo ============================
\echo top 10 shared memory context
\echo ============================
select 
    contextname,
    count(*) context_cnt,
    pg_size_pretty(sum(totalsize)::numeric(100,0)) total_size,
    pg_size_pretty(sum(freesize)::numeric(100,0)) free_size,
    pg_size_pretty(sum(usedsize)::numeric(100,0)) used_size,
    pg_size_pretty(max(totalsize)::numeric(100,0)) max_size,
    pg_size_pretty(min(totalsize)::numeric(100,0)) min_size,
    pg_size_pretty(avg(totalsize)::numeric(100,0)) avg_size
from 
    gs_shared_memory_detail 
group by 
    contextname 
order by 
    sum(totalsize) desc 
limit 10;
\echo =============================
\echo top 10 session memory context
\echo =============================
select 
    contextname,
    count(*) context_cnt,
    pg_size_pretty(sum(totalsize)::numeric(100,0)) total_size,
    pg_size_pretty(sum(freesize)::numeric(100,0)) free_size,
    pg_size_pretty(sum(usedsize)::numeric(100,0)) used_size,
    pg_size_pretty(max(totalsize)::numeric(100,0)) max_size,
    pg_size_pretty(min(totalsize)::numeric(100,0)) min_size,
    pg_size_pretty(avg(totalsize)::numeric(100,0)) avg_size
from 
    gs_session_memory_detail 
group by 
    contextname 
order by 
    sum(totalsize) desc 
limit 10;
\echo =============================
\echo top 10 session memory used
\echo =============================
select count(*) sess_cnt,pg_size_pretty(sum(totalsize)::numeric(100,0)) sess_total_size,pg_size_pretty(avg((totalsize)::numeric(100,0))) sess_avg_size,pg_size_pretty(min((totalsize)::numeric(100,0))) sess_min_size,pg_size_pretty(max((totalsize)::numeric(100,0))) sess_max_size from
(select sessid,sum(totalsize) totalsize from gs_session_memory_detail group by sessid);

select a.sessionid,application_name,to_char(backend_start,'yyyy-mm-dd hh24:mi:ss') backend_start,state,pg_size_pretty(sum(t1.totalsize)::numeric(100,0)) total_size,substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) sql_text
 from pg_stat_activity a, gs_session_memory_detail t1  where a.sessionid = split_part(sessid,'.',2)
group by a.sessionid,application_name,state,to_char(backend_start,'yyyy-mm-dd hh24:mi:ss'),substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) order by sum(t1.totalsize) desc limit 10;
EOF
}
