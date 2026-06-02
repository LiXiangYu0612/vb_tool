#!/bin/bash
# Command: repl - display Streaming Replication lag

repl_help() {
    echo "Options for repl:"
    echo "  Usage: None"
    echo "  Description: display Streaming Replication lag"
    echo ""
}

run_repl() {
psql -d postgres -c "
COPY (
  SELECT slot_name, pg_current_xlog_location(), receiver_replay_location
  FROM pg_stat_replication a, pg_replication_slots b
  WHERE a.application_name LIKE '%'||b.slot_name||'%' 
  AND slot_type='physical'
) TO '/tmp/repl.txt' WITH DELIMITER ',';
" >/dev/null 2>&1

sleep 5

psql -d postgres -c "
WITH aa AS (
  SELECT 
    split_part(result, ',', 1) AS slot_name,
    split_part(result, ',', 2) AS prim_curr_loc,
    split_part(result, ',', 3) AS recv_replay_loc 
  FROM regexp_split_to_table('$(cat /tmp/repl.txt | paste -sd ';')', ';') AS result
)
SELECT 
  split_part(client_addr::text,'/',1)||'-'||b.slot_name||'('||
    CASE WHEN active='t' THEN 'active' ELSE 'inactive' END||')' AS replslot,
  state||'-'||
    CASE 
      WHEN sync_state='Sync' THEN sync_state||'('||sync_priority||')' 
      ELSE sync_state 
    END AS state,
  pg_current_xlog_location() AS prim_curr_loc,
  receiver_flush_location AS recv_flush_loc,
  receiver_replay_location AS recv_replay_loc,
  restart_lsn,
  pg_size_pretty(round((pg_xlog_location_diff(pg_current_xlog_location(), aa.prim_curr_loc))/5)) AS wal_rate_s,
  pg_size_pretty(round((pg_xlog_location_diff(receiver_replay_location, aa.recv_replay_loc))/5)) AS repl_rate_s,
  pg_size_pretty(pg_xlog_location_diff(pg_current_xlog_location(), receiver_replay_location)) AS repl_lag
FROM pg_stat_replication a, pg_replication_slots b, aa
WHERE a.application_name LIKE '%'||b.slot_name||'%' 
  AND slot_type='physical' 
  AND aa.slot_name=b.slot_name
"
}
