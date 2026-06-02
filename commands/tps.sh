#!/bin/bash
# Command: tps - Statistics for Total Transactions and TPS

tps_help() {
    echo "Options for tps:"
    echo "  Usage: vb_tool tps"
    echo "  Description: Statistics for Total Transactions and TPS via interactive prompts"
    echo ""
    echo "  Interactive Flow:"
    echo "    1. please input begin date:  (Format: YYYY-MM-DD, Default: 2000-01-01)"
    echo "    2. please input end date:    (Format: YYYY-MM-DD, Default: trunc(sysdate)+1)"
    echo ""
    echo "  Report Columns:"
    echo "    time_range      | Time interval of the statistics (10-min window)"
    echo "    total_trans     | Total number of transactions in the range"
    echo "    tps             | Average Transactions Per Second"
    echo ""
    echo "  Examples:"
    echo "    run_tps"
    echo "    > please input begin date: 2026-03-24"
    echo "    > please input end date:   [Enter for default]"
    echo ""
}

run_tps() {
    psql -d postgres <<EOF
\pset footer off
\echo 'default begin date is '2000-01-01';default end date is trunc(sysdate)+1;'
\echo 'please input begin date: ' \prompt begin_date
\echo 'please input end date: ' \prompt end_date
select time_range,total_trans,tps from
(select st_timestamp, to_char(st_timestamp, 'mmdd hh24:mi:ss') || '--' || COALESCE(to_char(lead(st_timestamp) OVER (ORDER BY st_timestamp), 'mmdd hh24:mi:ss'),to_char(now(),'mmdd hh24:mi:ss')) time_range,
    trunc(extract(epoch FROM (COALESCE(lead(st_timestamp) OVER (ORDER BY st_timestamp), now()) - st_timestamp))) el,
	COALESCE(lead(st_xid) OVER (ORDER BY st_timestamp),(select txid_current()))-st_xid total_trans,
	round((COALESCE(lead(st_xid) OVER (ORDER BY st_timestamp),(select txid_current()))-st_xid)/trunc(extract(epoch FROM (COALESCE(lead(st_timestamp) OVER (ORDER BY st_timestamp), now()) - st_timestamp))),1) TPS
	from vb_usage_statistic) 
	where to_char(st_timestamp,'yyyy-mm-dd hh24:mi:ss')>=COALESCE(NULLIF(:'begin_date',''),'2001-01-01 00:00:01') and to_char(st_timestamp,'yyyy-mm-dd hh24:mi:ss')<=COALESCE(NULLIF(:'end_date',''),to_char(trunc(now()+1),'yyyy-mm-dd hh24:mi:ss')) and el<1000
 order by 1;
EOF
}
