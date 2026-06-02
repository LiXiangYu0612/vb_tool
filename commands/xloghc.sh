#!/bin/bash
# Command: xloghc - XLOG health check

xloghc_help() {
    echo "Options for xloghc:"
    echo "  Usage: vb_tool xloghc"
    echo "  Description: display xlog health check information"
    echo ""
}
run_xloghc() {
    psql -q -d postgres -c "
DO \$\$
DECLARE
    db_role varchar;
    current_redo_lsn varchar;
    checkpoint_redo_lsn varchar;
    checkpoint_lsn1 varchar;
    cbmtrackedlsn varchar;
    min_restart_lsn varchar;
    min_standby_replay_location varchar;
    min_need_archive varchar;
    last_archive_done varchar;
    max_xlog varchar;
    timeline_id1 integer;
    min_xlog1 varchar;
    xlog_count integer;
    keep_xlog_count integer;
    total_xlog_size numeric;
    checkpoint_lsn_lag varchar;
    cbmtracked_lsn_lag varchar;
    min_xlog_time varchar;
    max_xlog_time varchar;
    TYPE setting_rec IS RECORD (
        name text,
        setting text
    );
    rec setting_rec;
    diff_ckpt_count numeric;
    diff_arch_count numeric;
    diff_restart_count numeric;
    diff_cbm_count numeric;
    diff_replay_count numeric;
    healthy_state varchar;
    xlog_count_limit numeric;
    v_cnt integer;
    db_version varchar;
BEGIN

    min_xlog_time='';
    max_xlog_time='';
    
    select count(*) into v_cnt from pg_proc where proname='vb_version';
    IF v_cnt>0 then
    select replace(replace(REGEXP_SUBSTR(vb_version(), '^(.*?)(?= compiled)', 1, 1, NULL, 1),'(',''),')','')||' patch '||REGEXP_SUBSTR(vb_version(), 'patch:(\d+)', 1, 1, NULL, 1)||' commit '||REGEXP_SUBSTR(vb_version(), 'commit (\S+)', 1, 1, NULL, 1) into db_version;
    ELSE
    select count(*) into v_cnt from pg_proc where proname='pw_version';
    IF v_cnt>0 then 
    select replace(replace(REGEXP_SUBSTR(pw_version(), '^(.*?)(?= compiled)', 1, 1, NULL, 1),'(',''),')','')||' commit '||REGEXP_SUBSTR(pw_version(), 'commit (\S+)', 1, 1, NULL, 1) into db_version;
    ELSE
    select replace(replace(REGEXP_SUBSTR(version(), '^(.*?)(?= compiled)', 1, 1, NULL, 1),'(',''),')','')||' commit '||REGEXP_SUBSTR(version(), 'commit (\S+)', 1, 1, NULL, 1) into db_version;
    END IF;
    END IF;
    
    select (select setting+1 from pg_settings where name='wal_keep_segments') +
           (select 2*setting from pg_settings where name='checkpoint_segments') into xlog_count_limit;
           
    select decode(pg_is_in_recovery(), 'f', 'Primary', 'Standby'),
           decode(pg_is_in_recovery(), 'f', pg_current_xlog_location(),(select receiver_received_location from pg_stat_get_wal_receiver())) current_redo_lsn,
		   upper(COALESCE(nullif(substr(to_hex(redo_lsn), 1, length(to_hex(redo_lsn))-8),''), '0') || '/' || (case when redo_lsn < 4294967295 then substr(lpad(to_hex(redo_lsn),8,0), -8) else substr(to_hex(redo_lsn), -8) end )) checkpoint_redo_lsn,
           upper(COALESCE(nullif(substr(to_hex(checkpoint_lsn), 1, length(to_hex(checkpoint_lsn))-8),''), '0') || '/' || (case when redo_lsn < 4294967295 then substr(lpad(to_hex(checkpoint_lsn),8,0), -8) else substr(to_hex(checkpoint_lsn), -8) end)) checkpoint_lsn1,
            decode(COALESCE(nullif(ltrim(regexp_substr(pg_cbm_tracked_location(), '[^/]+', 1, 1), '0'),''), '0') || '/' || regexp_substr(pg_cbm_tracked_location(), '[^/]+', 1, 2),
                  '0/', '', COALESCE(nullif(ltrim(regexp_substr(pg_cbm_tracked_location(), '[^/]+', 1, 1), '0'),''), '0') || '/' || regexp_substr(pg_cbm_tracked_location(), '[^/]+', 1, 2)) cbmtrackedlsn,
           (select min(restart_lsn) from pg_replication_slots) min_restart_lsn,
           decode(pg_is_in_recovery(), 'f', (select min(receiver_replay_location) from pg_stat_get_wal_senders()),
           (select min(receiver_replay_location) from pg_stat_get_wal_receiver())) min_standby_replay_location,
           (select * from pg_ls_dir('pg_xlog/archive_status/') where pg_ls_dir  not like '%backup%' and pg_ls_dir like '%ready' order by 1 limit 1),
           (select * from pg_ls_dir('pg_xlog/archive_status/') where pg_ls_dir  not like '%backup%' and pg_ls_dir like '%done' order by 1 desc limit 1),
           timeline_id
    from pg_control_checkpoint()
    into db_role, current_redo_lsn, checkpoint_redo_lsn, checkpoint_lsn1, cbmtrackedlsn, min_restart_lsn,
         min_standby_replay_location, min_need_archive, last_archive_done, timeline_id1;
    
    select count(*) into v_cnt from pg_proc where proname='pg_ls_waldir';
    
    IF v_cnt>0 then 
    
        select name,modification from (select name , modification  from pg_ls_waldir() where name not like '%backup%' and length(name)=24 order by 1 limit 10) order by 1 limit 1 into min_xlog1,min_xlog_time;
        select name max_xlog, modification max_xlog_time from pg_ls_waldir() where name not like '%backup%' order by 2 desc limit 1 into max_xlog,max_xlog_time;
        select count(*) xlog_count, sum(size) total_xlog_size from pg_ls_waldir() where name not like '%backup%' into xlog_count,total_xlog_size;
             
    ELSE
    
        select * from pg_ls_dir('pg_xlog') where pg_ls_dir  not like '%backup%' and pg_ls_dir not like '%archive_s%' order by 1 limit 1 into min_xlog1;
        select lpad(timeline_id1, 8, '0') ||
                           lpad(regexp_substr(current_redo_lsn, '[^/]+', 1, 1), 8, '0') ||
                           lpad(substr(regexp_substr(current_redo_lsn, '[^/]+', 1, 2), 1, 2), 8, '0') into max_xlog;
        select count(*),count(*)*16*1024*1024 from pg_ls_dir('pg_xlog') where pg_ls_dir  not like '%backup%' and pg_ls_dir not like '%archive_s%' into xlog_count,total_xlog_size;
    
    END IF;
    
    select 1+to_number(substr(max_xlog,9,8)||substr(max_xlog,-2,2),'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')-to_number(substr(min_xlog1,9,8)||substr(min_xlog1,-2,2),'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx') into keep_xlog_count;
    select round(pg_xlog_location_diff(current_redo_lsn, checkpoint_redo_lsn)/16/1024/1024) into diff_ckpt_count;
    select round(COALESCE(pg_xlog_location_diff(current_redo_lsn, cbmtrackedlsn)/16/1024/1024, 0)) into diff_cbm_count;
    select round(COALESCE(pg_xlog_location_diff(current_redo_lsn, min_restart_lsn)/16/1024/1024, 0)) into diff_restart_count;
    select round(COALESCE(pg_xlog_location_diff(current_redo_lsn, min_standby_replay_location)/16/1024/1024, 0)) into diff_replay_count;
    select COALESCE(to_number(substr(max_xlog, 9, 8) || substr(max_xlog, -2, 2), 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx') -
               to_number(substr(COALESCE(replace(min_need_archive, '.ready', ''), replace(last_archive_done, '.done', '')), 9, 8) ||
                         substr(COALESCE(replace(min_need_archive, '.ready', ''), replace(last_archive_done, '.done', '')),-2, 2),
               'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), 0) into diff_arch_count;

    if diff_ckpt_count >= xlog_count_limit then
        healthy_state = '                    checkpoint lag,keep '||diff_ckpt_count||' xlogs'||CHR(10) ||healthy_state;
    end if;
    if diff_cbm_count >= xlog_count_limit then
        healthy_state = '                    cbm lag,keep '||diff_cbm_count||' xlogs'|| CHR(10) ||healthy_state;
    end if;
    if diff_restart_count >= xlog_count_limit then
        healthy_state = '                    restart lsn lag,keep '||diff_restart_count||' xlogs' || CHR(10) || healthy_state;
    end if;
    if diff_arch_count >= xlog_count_limit then
        healthy_state = '                    archive lag,keep '||diff_arch_count||' xlogs' || CHR(10) || healthy_state;
    end if;
    if diff_replay_count >= xlog_count_limit then
        healthy_state = '                    standby replay lag, keep '||diff_replay_count||' xlogs '|| CHR(10) || healthy_state;
    end if;

    RAISE INFO 'Xlog Healthy Summary:';
    RAISE INFO '---------------------';
    RAISE INFO '  Pgxc Node Name: %', (select get_nodename());
    RAISE INFO '   Database Role: %', db_role;
    RAISE INFO 'Database Version: %', db_version;
    RAISE INFO '    Current Redo: %, Last Modify Time: %', max_xlog, max_xlog_time;
    RAISE INFO '     Oldest Xlog: %, Last Modify Time: %', min_xlog1, min_xlog_time;
    RAISE INFO ' Keep Xlog Count: %', keep_xlog_count;
    RAISE INFO 'Total Xlog Count: %', xlog_count;
    RAISE INFO '  Keep Xlog Size: %', pg_size_pretty(keep_xlog_count*16*1024*1024::numeric);
    RAISE INFO ' Total Xlog Size: %', pg_size_pretty(total_xlog_size);
    RAISE INFO '   Health Status: %', rtrim(ltrim(COALESCE(healthy_state, 'healthy')), ',');
    RAISE INFO '                    ';
    RAISE INFO 'Xlog Healthy Detail:';
    RAISE INFO '---------------------';
    RAISE INFO 'Current Redo LSN: %, Checkpoint Redo LSN: %, Checkpoint LSN: %', current_redo_lsn, checkpoint_redo_lsn, checkpoint_lsn1;
    RAISE INFO 'CBM Tracked LSN: %, CBM Tracked WAL: %', cbmtrackedlsn, decode(lpad(timeline_id1, 8, '0') ||
                           lpad(regexp_substr(cbmtrackedlsn, '[^/]+', 1, 1), 8, '0') ||
                           lpad(substr(regexp_substr(cbmtrackedlsn, '[^/]+', 1, 2), 1, 2), 8, '0'), lpad(timeline_id1, 8, '0'),NULL,lpad(timeline_id1, 8, '0') ||
                           lpad(regexp_substr(cbmtrackedlsn, '[^/]+', 1, 1), 8, '0') ||
                           lpad(substr(regexp_substr(cbmtrackedlsn, '[^/]+', 1, 2), 1, 2), 8, '0'));
    RAISE INFO 'Min Restart LSN: %, Min Restart WAL: %', min_restart_lsn,
               decode(lpad(timeline_id1, 8, '0') ||
                    lpad(regexp_substr(min_restart_lsn, '[^/]+', 1, 1), 8, '0') ||
                    lpad(substr(regexp_substr(min_restart_lsn, '[^/]+', 1, 2), 1, 2), 8, '0'), lpad(timeline_id1, 8, '0'),NULL,lpad(timeline_id1, 8, '0') ||
                    lpad(regexp_substr(min_restart_lsn, '[^/]+', 1, 1), 8, '0') ||
                    lpad(substr(regexp_substr(min_restart_lsn, '[^/]+', 1, 2), 1, 2), 8, '0'));
    RAISE INFO 'Min Standby Replay LSN: %, Min Standby Replay WAL: %', min_standby_replay_location,
                decode(lpad(timeline_id1, 8, '0') ||
                    lpad(regexp_substr(min_standby_replay_location, '[^/]+', 1, 1), 8, '0') ||
                    lpad(substr(regexp_substr(min_standby_replay_location, '[^/]+', 1, 2), 1, 2), 8, '0'),lpad(timeline_id1, 8, '0'), NULL,lpad(timeline_id1, 8, '0') ||
                    lpad(regexp_substr(min_standby_replay_location, '[^/]+', 1, 1), 8, '0') ||
                    lpad(substr(regexp_substr(min_standby_replay_location, '[^/]+', 1, 2), 1, 2), 8, '0'));
    RAISE INFO 'Min Need Archive: %, Last Archive Done: %', replace(min_need_archive, '.ready', ''),
               replace(last_archive_done, '.done', '');
    
    select count(*) into v_cnt from pg_proc where proname='gs_xlog_keepers';
    
    IF v_cnt>0 then 
    RAISE INFO '                    ';
    FOR i IN (select keeptype,keepsegment,describe from gs_xlog_keepers() order by 2) LOOP
    RAISE INFO '%: % (%)',lpad(i.keeptype,25,' '),i.keepsegment,i.describe;
    END LOOP;
    END IF;
    
    RAISE INFO '                    ';
    RAISE INFO '  Guc Parameter(checkpoint):';
    FOR rec IN
        SELECT name, decode(unit, '8kB', setting*8 || 'kB', setting || COALESCE(unit, ' ')) setting
        FROM pg_settings
        WHERE name in ('enable_incremental_checkpoint', 'checkpoint_completion_target', 'checkpoint_segments',
                        'checkpoint_timeout', 'checkpoint_wait_timeout', 'pagewriter_thread_num',
                        'pagewriter_sleep', 'bgwrite_sleep', 'bgwrite_delay', 'max_io_capacity')
    LOOP
        RAISE INFO '%: %', lpad(rec.name, 35, ' '), rec.setting;
    END LOOP;

    RAISE INFO '  Guc Parameter(archive):';
    FOR rec IN
        SELECT name, decode(unit, '8kB', setting*8 || 'kB', setting || COALESCE(unit, ' ')) setting
        FROM pg_settings
        WHERE name in ('archive_command', 'archive_mode', 'archive_interval', 'max_standby_archive_delay')
    LOOP
        RAISE INFO '%: %', lpad(rec.name, 35, ' '), rec.setting;
    END LOOP;

    RAISE INFO '  Guc Parameter(wal):';
    FOR rec IN
        SELECT name, decode(unit, '8kB', setting*8 || 'kB', setting || COALESCE(unit, ' ')) setting
        FROM pg_settings
        WHERE name in ('advance_xlog_file_num', 'enable_xlog_prune', 'max_size_for_xlog_prune', 'max_wal_senders',
                        'wal_keep_segments', 'recovery_min_apply_delay', 'wal_flush_delay', 'wal_flush_timeout')
    LOOP
        RAISE INFO '%: %', lpad(rec.name, 35, ' '), rec.setting;
    END LOOP;

    RAISE INFO '  Guc Parameter(cbm/dcf/repl):';
    FOR rec IN
        SELECT name, decode(unit, '8kB', setting*8 || 'kB', setting || COALESCE(unit, ' ')) setting
        FROM pg_settings
        WHERE (name IN ('enable_cbm_tracking', 'enable_dcf', 'recovery_max_workers', 'recovery_parse_workers', 'recovery_redo_workers')
               OR name LIKE 'replconninfo%') AND LENGTH(setting) > 0
    LOOP
        IF rec.name LIKE 'replconninfo%' THEN
            RAISE INFO '%: %', lpad(rec.name, 35, ' '), substr(rec.setting, 1, 100);
            RAISE INFO '%', lpad(' ', 37, ' ') || substr(rec.setting, 101, 100);
        ELSE
            RAISE INFO '%: %', lpad(rec.name, 35, ' '), rec.setting;
        END IF;
    END LOOP;
END \$\$;
" 2>&1 | awk '{gsub(/INFO:/, ""); print}'
}
