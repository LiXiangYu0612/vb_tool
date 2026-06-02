#!/bin/bash
# Command: collect_log - Collect logs for cluster or single node

collect_log_help() {
    echo "Usage: collect_log -b <begin_time> -e <end_time> [-n <max_xlog>] [-u <db_user>] [-g] [-z <backup_path>]"
    echo ""
    echo "Options:"
    echo "    -b    Begin time (format: 'YYYY-MM-DD HH:MM:SS'). Required."
    echo "    -e    End time (format: 'YYYY-MM-DD HH:MM:SS'). Required."
    echo "    -n    Maximum number of xlog files to collect (0-1024)."
    echo "          Set to 0 to skip xlog collection. Default: 50."
    echo "    -u    Database OS user (e.g., vastbase). Required if running as root."
    echo "          When specified, collects system logs (/var/log/messages, cron) "
    echo "          before switching to the database user context."
    echo "    -g    Cluster mode. Collect logs from all nodes in the cluster."
    echo "          If not specified, only the current node's logs are collected."
    echo "    -z    Backup catalog path; equivalent to pg_probackup -B <backup_path>."
    echo ""
    echo "Examples:"
    echo "    # Run as database user (Current node only):"
    echo "    vb_tool collect_log -b '2026-03-08 10:00:00' -e '2026-03-08 11:00:00'"
    echo ""
    echo "    # Run as root to include system logs (Cluster-wide):"
    echo "    vb_tool collect_log -b '2026-03-08 10:00:00' -e '2026-03-08 11:00:00' -u vastbase -g"
    echo ""
}
run_collect_log(){
    local begin_time=""
    local end_time=""
    local collect_type="self"  
	local max_xlog=50  # default 50
	local backup_path="/backup/backup"
    local path_is_default=true
	local local_hostname=$(hostname)
    local logname="vblog_$(date +%Y%m%d_%H%M%S)"
    local output_dir="/tmp/$logname"
    local db_user=""
    local original_args=("$@")
    local OPTIND=1
    while getopts ":b:e:n:u:z:g" opt; do
        case $opt in
            b) begin_time="$OPTARG" ;;
            e) end_time="$OPTARG" ;;
            g) collect_type="all" ;;
			n) max_xlog="$OPTARG" ;;
            u) db_user="${OPTARG//[[:space:]]/}" ;;
            z) backup_path="$OPTARG" ; path_is_default=false ;;
		   \?) echo "Invalid option: -$OPTARG" >&2; collect_log_help; exit 1 ;;
            :) echo "Option -$OPTARG requires argument" >&2; collect_log_help; exit 1 ;;
        esac
    done
    # --- Input Validation ---
    if [[ -z "$begin_time" || -z "$end_time" ]]; then
        echo "Error: begin time and end time are required"
        collect_log_help
        exit 1
    fi 
	
	if [[ ! "$max_xlog" =~ ^[0-9]+$ ]] || [ "$max_xlog" -lt 0 ] || [ "$max_xlog" -gt 1024 ]; then
        echo "Error: -n (max xlog count) must be an integer between 0 and 1024"
		collect_log_help
        exit 1
    fi
	
    if [[ ! -d "$backup_path" ]] && [[ "$path_is_default" = false ]]; then
        echo "Error: Path '$backup_path' does not exist or is not a directory."
		collect_log_help
        exit 1
    fi
    # Normalize time format and validate chronological order
    begin_time=$(date -d "$begin_time" +'%Y-%m-%d %H:%M:%S' 2>/dev/null) || { echo "Error: Invalid start time format"; exit 1; }
    end_time=$(date -d "$end_time" +'%Y-%m-%d %H:%M:%S' 2>/dev/null) || { echo "Error: Invalid end time format"; exit 1; }
    [[ $(date -d "$begin_time" +%s) -le $(date -d "$end_time" +%s) ]] || { echo "Error: Start time must be earlier than end time"; exit 1; }
    
	 # --- System Log Collection (Messages & Cron) ---
     # Strategy: Calculate independent adjusted end-times for different log types 
     # to ensure capture of the first rotation file following the requested window.
    if [ "$(id -u)" -eq 0 ]; then
        if [[ -z "$db_user" ]]; then
            echo "Error: Running as root requires -u <database_user>"
			collect_log_help
            exit 1
        fi
		
		if ! id "$db_user" >/dev/null 2>&1; then
            echo "Error: System user '$db_user' does not exist."
            exit 1
        fi

        local logname="vblog_$(date +%Y%m%d_%H%M%S)"
        local output_dir="/tmp/$logname"
        mkdir -p "$output_dir"/osinfo

        # Messages and Cron log
        echo "[INFO ] Collecting local system messages and cron logs."
        for log_type in "messages" "cron"; do
            # Locate the first file modified after the specified end_time
            local adj_end=$(find /var/log -maxdepth 1 -type f -name "${log_type}*" -newermt "$end_time" -printf "%TY-%Tm-%Td %TT\n" 2>/dev/null | sort | head -n 1)
            [ -z "$adj_end" ] && adj_end="$end_time"
            
            #echo "[INFO ] Collecting $log_type (End time adjusted to: $adj_end)"
            
            # Archive logs within the calculated range; use -C to strip absolute path prefixes
            find /var/log -maxdepth 1 -type f -name "${log_type}*" -newermt "$begin_time" ! -newermt "$adj_end" -printf "%P\0" | \
            tar -czpf "$output_dir/osinfo/${log_type}.tar.gz" --null -C /var/log -T - 2>/dev/null
        done

        # Hand over directory ownership to the database user
        chown -R "$db_user" "$output_dir"

        # --- Argument Reconstruction ---
        # Sanitize arguments by removing the -u flag and its value to prevent recursion
        local local pass_args=("collect_log")
        local skip_next=false
        for arg in "${original_args[@]}"; do
            if [ "$skip_next" = true ]; then skip_next=false; continue; fi
            if [[ "$arg" == "-u" ]]; then skip_next=true; continue; fi
			if [[ "$arg" == "collect_log" ]]; then continue; fi 
			[[ -n "$arg" ]] && pass_args+=("$arg")
        done

        echo "[INFO ] System logs collected. Switching to $db_user..."
        # Use printf %q to escape arguments safely, preserving spaces and special characters
        local quoted_args=$(printf " %q" "${pass_args[@]}")
		local script_path=$(realpath "$0")
        su - "$db_user" -c "export EXISTING_LOGNAME='$logname'; $script_path $quoted_args"
        exit $?
    fi

    # --- Database User Execution Context ---
    # Inherit directory name if passed from root session, otherwise generate new
    if [[ -n "$EXISTING_LOGNAME" ]]; then
        logname="$EXISTING_LOGNAME"
    else
        logname="vblog_$(date +%Y%m%d_%H%M%S)"
    fi
    output_dir="/tmp/$logname"
	
    case "$collect_type" in
        self)
            run_collect_log_self 
            ;;
         all)
            run_collect_log_all 
            ;;
        *)
            echo "Error: Invalid type '$collect_type'"
            collect_log_help
            exit 1
            ;;
    esac
}

run_collect_log_self() {
    echo "[INFO ] Collecting logs ($begin_time ~ $end_time)..."
    run_collect_log_nodes_info "$local_hostname"

    # Logfile Check
    echo "--------------------------------------------------------------"
    if [ $? -eq 0 ]; then
        echo "[INFO ] Compressing logs ……"
	    tar -czf "/tmp/${logname}.tar.gz" -C /tmp "$logname"
        rm -rf "$output_dir"
        echo "--------------------------------------------------------------"
        echo "[SUCCESS] Logs collected to \"/tmp/${logname}.tar.gz\" . Size: $(du -sh "/tmp/${logname}.tar.gz" | cut -f1)"
    else
        echo "[ERROR] Logs collection failed!"
        exit 1
    fi
}

run_collect_log_all() {
    if command -v has_ctl &> /dev/null; then
        local host_list=$(cm_ctl view | grep nodeName | awk -F: '{gsub(/[[:space:]"]/, "", $2); print $2}' | xargs)
        if [ -z "$host_list" ]; then
            echo "[ERROR] Failed to retrieve cluster node list. Check CM configuration."
            exit 1
        fi
		echo "[INFO ] Collecting logs ($begin_time ~ $end_time)..."
        # Collect CM Params
        # Convert string to an array to count elements
        local host_array=($host_list)
        local host_count=${#host_array[@]}

        if [ "$host_count" -gt 1 ]; then
            echo "[INFO ] Multi-node cluster detected ($host_count nodes: $host_list)."
			mkdir -p $output_dir/{osinfo,dbinfo,pglog,cmlog,dbconf,ffic_log}
            cm_ctl list --param --agent > "$output_dir/dbconf/cm_agent.conf" 2>/dev/null
            cm_ctl list --param --server > "$output_dir/dbconf/cm_server.conf" 2>/dev/null
        else
            echo "[INFO ] Single node detected (1 node: $host_list)."
        fi
        for host in $host_list; do
            run_collect_log_nodes_info "$host"
        done
    else
        echo "[ERROR] Non-Has3.x environment detected. Remove '-g' to collect local logs only."
        exit 1
    fi
    
    # Final Result
    echo "[INFO ] Compressing logs ……"
	tar -czf "/tmp/${logname}.tar.gz" -C /tmp "$logname"
    rm -rf "$output_dir"
    echo "--------------------------------------------------------------"
    echo "[SUCCESS] Logs collected to \"/tmp/${logname}.tar.gz\" . Size: $(du -sh "/tmp/${logname}.tar.gz" | cut -f1)"
}

run_collect_log_pglog() {
    local begin_time="$1"
    local end_time="$2"
    local output_dir="$3"
    local LOG_DIR=$(run_collect_log_param "log_directory")   
    mkdir -p "$output_dir/pglog"	
    
    if [ -d "$LOG_DIR" ]; then
        echo "[INFO ] DB Log Directory: $LOG_DIR"
        # Find the first file modified after end_time to ensure log continuity
        local db_limit_time=$(date -d "$end_time +1 day" +'%Y-%m-%d 00:30:00')
        local real_end_time=$(find "$LOG_DIR" -maxdepth 1 -type f -newermt "$end_time" ! -newermt "$db_limit_time" -printf "%TY-%Tm-%Td %TT\n" | sort | head -n 1)
        if [ -z "$real_end_time" ]; then
            real_end_time="$end_time"
        else
            real_end_time=$(date -d "${real_end_time:0:19} 30 sec" +"%Y-%m-%d %H:%M:%S")
            echo "[INFO ] Adjusted end time for log overlap: $real_end_time"
        fi      
        cd "$LOG_DIR" && find . -maxdepth 1 -type f -newermt "$begin_time" ! -newermt "$real_end_time" -print0 | tar -czf "$output_dir/pglog/pglog.tar.gz" --null -T -
        echo "[INFO ] pg_log collection completed."
    else
        echo "[WARN ] Could not locate pg_log directory."
    fi
}

run_collect_log_nodes_info() {
    local node=$1
    [ -z "$node" ] && node=$local_hostname
    
    echo "--------------------------------------------------------------"
    echo "[INFO ] Processing Node: [$node]"
    
    local remote_cmd=$(cat <<EOF
		[ -f /etc/profile ] && . /etc/profile;
        [ -f ~/.profile ] && . ~/.profile;
        [ -f ~/.bashrc ] && . ~/.bashrc;
        [ -f ~/.Vastbase ] && . ~/.Vastbase;
	    mkdir -p $output_dir/{osinfo,dbinfo,pglog,cmlog,dbconf,ffic_log}

        # 1. OSWatcher Collection
        if pgrep -f "OSWatcherFM.sh" > /dev/null; then
            osw_path=\$(ps ux | grep OSWatcherFM.sh | grep -v grep | awk '{print \$NF}')
            if [ -n "\$osw_path" ] && [ -d "\$osw_path" ]; then
                osw_limit=\$(date -d "$end_time +1 hour" +'%Y%m%d %H:%M')
				mkdir -p $output_dir/osw
				cd "\$osw_path" && find . -type f -newermt "$begin_time" ! -newermt "\$osw_limit" -print0 | xargs -0 cp --parents -t "$output_dir/osw/" 2>/dev/null
            fi
        fi

        # 2. nmon Collection
        if pgrep -f "nmon" > /dev/null; then
            nmon_path=\$(ps ux | grep nmon | grep -F -- '-F' | grep -v grep | awk '{print \$NF}' | xargs dirname)
			if [ -n "\$nmon_path" ] && [ -d "\$nmon_path" ]; then
                nmon_limit=\$(date -d "$end_time +1 day" +'%Y-%m-%d 00:00:00')
				mkdir -p $output_dir/nmon
				#cd "\$nmon_path" && find . -maxdepth 1 -type f -newermt "$begin_time" ! -newermt "\$nmon_limit" -exec sh -c 'gzip -c "$1" > "$2/$(basename "$1").gz"' _ {} "$output_dir/nmon" \;
				cd "\$nmon_path" && find . -maxdepth 1 -type f -newermt "$begin_time" ! -newermt "\$nmon_limit" -exec sh -c '[ -n "$2" ] && [ -d "$2" ] && gzip -c "$1" > "$2/$(basename "$1").gz"' -- {} "$output_dir/nmon" \;
            fi
        fi
        
        # 3. OS Info & Dmesg
        run_collect_log_osinfo > "$output_dir/osinfo/osinfo_${node}.txt"
        dmesg -T | gzip > "$output_dir/osinfo/dmesg_${node}.log.gz" 2>/dev/null
        
        # 4. Role-based DB Info Collection
        # a. Determine status: f (Primary), t (Standby), or empty (Offline)
        primary_status=\$(timeout 2s psql -tAc "select pg_is_in_recovery()" 2>/dev/null)
             
        # b. Online-only Collection (Runs if status is 'f' or 't')
        if [[ "\$primary_status" =~ ^(f|t)$ ]]; then
            echo "[INFO ] Database online (Mode: \${primary_status}). Collecting online metrics."
            
            # Collect dbinfo 
            run_collect_log_version   >  "$output_dir/dbinfo/dbinfo_${node}.txt"
            run_collect_log_deadtups  >  "$output_dir/dbinfo/deadtups_${node}.txt"
            run_collect_log_extension >  "$output_dir/dbinfo/extensions_${node}.txt"
        
            # c. Primary-only Collection 
            if [[ "\$primary_status" == "f" ]]; then
                echo "[INFO ] Primary node detected. Collecting WDR/ASP/MEM."
                run_collect_log_asp      > "$output_dir/dbinfo/asp_${node}.txt"
                run_collect_log_mem      > "$output_dir/dbinfo/mem_${node}.txt"
                run_collect_log_wdr      > "$output_dir/dbinfo/wdr_${node}.txt"
				safe_exec "Show Backup" "vb_probackup show -B '$backup_path' > $output_dir/dbinfo/dbinfo_${node}.txt "
            fi
        else
            echo "[WARN ] Database offline or connection timeout - skipping SQL-based metrics."
        fi
		# d. Universal Collection (Runs even if DB is offline, as these functions handle errors internally)
        echo "[INFO ] Collecting base metrics..."
        run_collect_log_dbinfo  >> "$output_dir/dbinfo/dbinfo_${node}.txt"
        run_collect_log_dbfiles >  "$output_dir/dbinfo/dbfiles_${node}.txt"
		
		# 5. Backup Configuration Files
		safe_exec "Backup Configuration Files" "find $PGDATA -maxdepth 1 \( -name 'postgresql*.conf' -o -name 'pg_hba.conf' -o -name 'gaussdb.state' \) -type f -exec cp {} $output_dir/dbconf/ \;"
		
		# 6. crontab config
		safe_exec "Get Crontab Config" "crontab -l > $output_dir/dbconf/crontab_${node}.txt"
		
		# 7. Capture Process Stack
		safe_exec "Capture Process Stack (3 samples)" "run_collect_log_stack $output_dir" "30s"

		# 8. Cluster or Single-node Log Backup	
        if command -v has_ctl &> /dev/null; then		
            safe_exec "Cluster Log Backup" "run_collect_log_cmdn '$begin_time' '$end_time' '$output_dir'" "1200s"	
		else 
            safe_exec "Database Log Backup" "run_collect_log_pglog '$begin_time' '$end_time' '$output_dir'" "1200s"		
	    fi
		
		# 9.Wal Segments Backup from current node and primary node
        if [[ "$max_xlog" -gt 0 ]] && { [[ "$node" == "$local_hostname" ]] || [[ "\$primary_status" == "f" ]]; }; then
            safe_exec "Wal Segments Backup" "run_collect_log_xlog '$begin_time' '$end_time' '$max_xlog' '$output_dir'" "1800s"    
        fi
		
        # 10. Archive & Cleanup
        if [ -d "$output_dir" ]; then
            cd "$output_dir"
            tar -czf "${node}.tar.gz" * --exclude="${node}.tar.gz" 2>/dev/null
            find . -maxdepth 1 ! -name "${node}.tar.gz" ! -name "." -exec rm -rf {} +
            echo "BUNDLE_READY"
        fi
		# Ending Message
        printf "\n[INFO ] Node ${node} collection completed.\n" 
EOF
)
    # Define functions for remote shell
    local func_defs="$(declare -f run_collect_log_osinfo run_nets run_lsds run_as run_asp_cnt_query run_asp_event_query run_asp_waitchain_query run_asp_sql_query run_mem run_xloghc run_dead_tups run_wdr_event run_wdr_summary run_wdr_topsql run_collect_log_asp run_collect_log_wdr run_collect_log_mem run_collect_log_dbinfo run_collect_log_dbfiles run_memhist safe_exec run_collect_log_deadtups run_collect_log_extension run_collect_log_version run_collect_log_stack run_collect_log_cmdn run_collect_log_param run_collect_log_xlog run_collect_log_pglog)"
    local remote_cmd="${func_defs}; ${remote_cmd}"

    # Execution
    if [ "$node" == "$local_hostname" ]; then
        status=$(eval "$remote_cmd")
    else
        status=$(ssh -n "$node" "$remote_cmd")
    fi
    
    # Retrieval
    if echo "$status" | grep -q "BUNDLE_READY"; then
	    echo -e "\n[INFO ] Node [$node] collection finished."
        if [[ "$node" != "$local_hostname" && "$node" != "localhost" ]]; then
            scp "$node:$output_dir/${node}.tar.gz" "$output_dir/" >/dev/null 2>&1
            ssh "$node" "rm -rf $output_dir /tmp/vb_funcs_*" >/dev/null 2>&1
			echo "[INFO ] Transfer and clean up node [$node] info finished..."	
            echo "--------------------------------------------------------------"			
		else 
		   rm -f /tmp/vb_funcs_*
        fi
    else
        echo -e "\n[ERROR] Node [$node] collection failed or interrupted."
    fi
}

run_collect_log_osinfo() {
	echo "========== Operating System Metrics Report =========="
    # Hardware & Release
    safe_exec "OS Release & Kernel Version" "cat /etc/os-release && uname -a"
    safe_exec "CPU Architecture Details" "lscpu"
    safe_exec "Memory capacity/usage" "free -m"
    safe_exec "Memory Info" "cat /proc/meminfo"
    # Storage & Network
    safe_exec "Disk Partition Usage" "df -h"
    safe_exec "Block Device Topology" "lsblk"
	safe_exec "DISK Statistics" "run_lsds" "5s"
    safe_exec "Network Interface Configuration" "/usr/sbin/ip a"
    safe_exec "Network Connectivity Test" "run_nets" "3s"
    # Resource Limits
    safe_exec "User Shell Limits (ulimit)" "ulimit -a"
    local v_pid=$(pgrep -n vastbase)
    if [ -n "$v_pid" ]; then
        safe_exec "Database Process Resource Limits (PID: $v_pid)" "cat /proc/$v_pid/limits"
    else
        echo -e "\n[SKIP] Vastbase process not running. Process limits skipped."
    fi
    safe_exec "User Process List" "ps ux" 
    # Kernel Parameters
    safe_exec "Static Kernel Config (/etc/sysctl.conf)" "grep '^[a-z]' /etc/sysctl.conf"
    safe_exec "Runtime Kernel Parameters (sysctl -a)" "/usr/sbin/sysctl -a" "10s"
}

run_collect_log_asp() {
    echo "========== Active Session Profile (ASP) =========="
    local v_pid=$(pgrep -n vastbase)
    [ -z "$v_pid" ] && { echo "[SKIP] Vastbase process not found"; return; }

    safe_exec "Current Active Sessions" "run_as $v_pid"
    # Batch execute ASP analytics
    for metric in cnt event waitchain sql; do
        safe_exec "ASP ${metric^^} Analysis" "run_asp_${metric}_query '$begin_time' '$end_time'" "30s"
    done
}

run_collect_log_mem() {
    echo "========== Database System Memory Info =========="
    safe_exec "Memory Stats" "run_mem"
    
    local wdr_status=$(timeout 2s psql -tAc "select current_setting('enable_wdr_snapshot')" 2>/dev/null)
    if [[ "$wdr_status" == "on" ]]; then
        safe_exec "Memory History (WDR)" "run_memhist -b '$begin_time' -e '$end_time'"
    else
        echo "[SKIP] WDR disabled or DB unreachable. Skipping memhist."
    fi
}

run_collect_log_wdr() {
    local wdr_status=$(timeout 2s psql -tAc "select current_setting('enable_wdr_snapshot')" 2>/dev/null)
    if [[ "$wdr_status" == "on" ]]; then
        echo "========== WDR Reports =========="
        for report in summary event topsql; do
            safe_exec "WDR ${report^^}" "run_wdr_${report} -b '$begin_time' -e '$end_time'" "60s"
        done
    else
        echo "[SKIP] WDR disabled. Skipping WDR reports."
    fi
}

run_collect_log_dbinfo() {
	# DB Compatibility
    safe_exec "DB Compatibility " "psql -d postgres -tAc 'show sql_compatibility'"
    # Cluster Stack Info
    if command -v gs_om >/dev/null; then
        safe_exec "Cluster Detail (gs_om)" "gs_om -t status --detail && gs_om -t query"
    fi
    
    if command -v cm_ctl >/dev/null; then
        safe_exec "Cluster Manager View (cm_ctl)" "cm_ctl view"
    fi
    
    # Instance & Object Info
    safe_exec "Node Instance Status (gs_ctl)" "gs_ctl query"
	safe_exec "Replication Infos" "psql -d postgres -c 'select * from pg_replication_slots'"
    safe_exec "Database Catalog List" "psql -d postgres -c '\l+'"
    safe_exec "XLOG/WAL Health Check" "run_xloghc"
    safe_exec "Table Bloat & Dead Tuples" "run_dead_tups -d postgres"
}

run_collect_log_deadtups() {
    echo "========== Vastbase Database Dead Tuples Check =========="
    local db_list=$(psql -tAc "select datname from pg_database where not datistemplate")
    for db in $db_list; do
        safe_exec "Dead Tuples Check: $db" "run_dead_tups -d $db"
    done
}

run_collect_log_extension() {
    echo "========== Vastbase Database Extensions Check =========="
    local db_list=$(psql -tAc "select datname from pg_database where not datistemplate")
    for db in $db_list; do
        safe_exec "Database Extensions Check: $db" "psql -d $db -c '\dx'"
    done
}

run_collect_log_version() {
    echo "========== Vastbase Database Status Report =========="
    # 1. Output binary versions for psql and cm_ctl
    echo "--- Binary Versions ---"
    psql -V 2>&1
    if command -v cm_ctl >/dev/null; then
        cm_ctl -V 2>&1
    fi

    echo -e "\n--- Database Internal Version ---"
    
    # 2. Calculate the "vers" weight based on available pg_proc functions
    local vers
    vers=$(psql -d postgres -tAc "SELECT coalesce(sum(CASE proname WHEN 'vb_version' THEN 1 WHEN 'pw_version' THEN 2 WHEN 'version' THEN 4 ELSE 0 END), 0) FROM pg_proc WHERE proname IN ('vb_version','pw_version','version');" 2>/dev/null)
    
    # Fallback: if psql fails or returns empty, force vers to 0 to trigger version.cfg check
    [ -z "$vers" ] && vers=0

    # 3. Execute version query based on the calculated weight
    case "$vers" in
        1|3|5|7)
            # Contains vb_version()
            psql -d postgres -c "SELECT vb_version();"
            ;;
        2|6)
            # Contains pw_version()
            psql -d postgres -c "SELECT pw_version();"
            ;;
        4)
            # Contains only standard version()
            psql -d postgres -c "SELECT version();"
            ;;
        0|*)
            # Fallback to config file if no functions are found
            if [ -f "$GAUSSHOME/version.cfg" ]; then
                echo "Source: $GAUSSHOME/version.cfg"
                cat "$GAUSSHOME/version.cfg"
            else
                echo "Error: version.cfg not found at \$GAUSSHOME ($GAUSSHOME)"
            fi
            ;;
    esac
}

run_collect_log_stack() {
    local target_dir="$1"  # Receive output_dir as the first argument

    # 1. Preparation
    mkdir -p "$target_dir/stack"
    echo "Collecting 3 stack samples using 'gs_ctl stack -D \$PGDATA'"

    # 2. Loop to collect 3 samples
    for i in {1..3}; do
        local timestamp=$(date '+%H%M%S')
        # Since we don't use PID, we use a generic name with timestamp
        local filename="gs_stack_${timestamp}.txt"
        
        echo "[$i/3] Capturing to $filename..."
        
        # gs_ctl stack identifies the process automatically via the data directory
        gs_ctl stack -D "$PGDATA" > "$target_dir/stack/$filename" 2>&1
        
        # Sleep 1s between samples
        [ $i -lt 3 ] && sleep 1
    done

    # Explicitly return 0 to ensure safe_exec shows [OK]
    return 0
}

run_collect_log_dbfiles() {
    echo "========== Environment & Config Files =========="
    safe_exec "PGDATA Directory Listing" "ls -al $PGDATA"
    safe_exec "User .bashrc" "cat ~/.bashrc"
    safe_exec "Vastbase Profile Search" "res=\$(find ~ -maxdepth 1 -type f -iname '.vastbase*' -exec printf '\n-- File: {} --\n' \; -exec cat {} \;); [ -z \"\$res\" ] && echo '[INFO] No profiles found.' || echo \"\$res\""
}

run_collect_log_param() {
    local param_name=$1
    # Default path; modify according to your environment
    local pgdata_dir=${PGDATA:-"/data/vastdata"} 
    local param_value=""

    # 1. Attempt retrieval via psql (Online Method)
    # -t: tuples only, -A: unaligned, -c: execute command
    param_value=$(psql -tAc "show $param_name" 2>/dev/null)

    # 2. Fallback to configuration files if psql fails or returns empty (Offline Method)
    if [[ -z "$param_value" ]]; then
        # Read files in reverse using 'tac' as PostgreSQL honors the last defined setting.
        # Search scope: postgresql.base.conf and postgresql.conf
        param_value=$(tac "$pgdata_dir/postgresql.base.conf" "$pgdata_dir/postgresql.conf" 2>/dev/null | \
                      grep -E "^[[:space:]]*$param_name" | head -n 1 | \
                      sed -E "s/^[[:space:]]*$param_name[[:space:]]*=[[:space:]]*['\"]?([^'\"]*)['\"?].*/\1/")
    fi

    # 3. Path Resolution Logic (Append PGDATA if the value is a relative directory/file path)
    if [[ -n "$param_value" ]]; then
        if [[ "$param_name" == *"directory"* || "$param_name" == *"file"* ]]; then
            if [[ "$param_value" != /* ]]; then
                param_value="$pgdata_dir/$param_value"
            fi
        fi
        echo "$param_value"
    else
        return 1 # Return non-zero status if parameter is not found
    fi
}

run_collect_log_cmdn() {
    local begin_time="$1"
    local end_time="$2"
    local output_dir="$3"

    # Define a helper to process and back up leaf nodes
    # Usage: process_leaf <absolute_path> <relative_path> <target_root>
    process_leaf() {
        local leaf_path="$1"
        local rel_path="$2"
        local dst_root="$3"

        # 1. Independent Cut-off Calibration
        # Locate the first file modified after end_time to ensure continuity
        local first_after
        first_after=$(find "$leaf_path" -maxdepth 1 -type f -newermt "$end_time" 2>/dev/null | head -n 1)
        
        local final_cutoff="$end_time"
        [[ -n "$first_after" ]] && final_cutoff=$(stat -c '%y' "$first_after")

        # 2. Execution of Copy via Relative Pathing
        # Using -exec ... + minimizes process forks for better throughput
        (
            cd "$GAUSSLOG" || exit
            find "$rel_path" -maxdepth 1 -type f -newermt "$begin_time" ! -newermt "$final_cutoff" \
                -exec cp --parents -t "$dst_root" {} + 2>/dev/null
        )
    }

    echo "[INFO ] Initiating hierarchical log harvest from $GAUSSLOG..."
    # Identify leaf directories (depth 1-3) and delegate to process_leaf
    # Logic: Find directories that contain files but no sub-directories
    # This replaces manual recursion with a highly optimized C-level scan
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        
        # Determine category and destination
        local rel_dir="${dir#$GAUSSLOG/}"
        local top_level="${rel_dir%%/*}"
        local target_path="$output_dir/cmlog"
        
        [[ "$top_level" == "pg_log" ]] && target_path="$output_dir/pglog"
		[[ "$top_level" == "ffic_log" ]] && target_path="$output_dir/ffic_log"
        
        # Only process relevant categories: bin, cm, om, pg_log
        case "$top_level" in
            bin|cm|om|pg_log)
                process_leaf "$dir" "$rel_dir" "$target_path"
                ;;
        esac
    done < <(find "$GAUSSLOG" -mindepth 1 -maxdepth 3 -type d \
             -exec sh -c 'ls -d "$1"/*/ >/dev/null 2>&1 || echo "$1"' _ {} \;)
}

run_collect_log_xlog() {
    # Description: Collects PostgreSQL WAL (xlog) files within a specific time range,
    #              considering both local and archived directories.
	local begin_time="$1"
	local end_time="$2"
	local max_xlog="$3"
    local output_dir="$4"
    local temp_list=$(mktemp)

    # 1. Resolve WAL Source Path
    # Prioritizes custom configuration before falling back to default PGDATA locations.
    local wal_dir=$(run_collect_log_param "vb_wal_directory")
    [[ -z "$wal_dir" ]] && wal_dir="$PGDATA/pg_xlog"

    # 2. Establish WAL Filename Boundary
    # Converts the latest LSN to a 24-character hex string to filter out pre-allocated future files.
    local raw_lsn=$(pg_controldata | awk -F': +' '/Latest checkpoint location/ {print $2}')
    local lsn_high="${raw_lsn%/*}"
    local lsn_low="${raw_lsn#*/}"
	local lsn_low_padded=$(printf "%08s" "$lsn_low" | tr ' ' '0')
	local boundary_wal=$(printf "00000001%08X000000%02X" "0x$lsn_high" "0x${lsn_low_padded:0:2}")

    # 3. Timestamp Normalization (End Time Calibration)
    # Buffers the search window to ensure files modified shortly after the end_time are considered.
    local search_limit
    search_limit=$(date -d "$end_time + 1 hour" +"%Y-%m-%d %H:%M:%S")
    local adj_end_ts_raw
    adj_end_ts_raw=$(find "$wal_dir" -maxdepth 1 -type f -newermt "$end_time" ! -newermt "$search_limit" -printf "%T@\n" | sort -n | head -1)
    
    local adj_end_ts
    adj_end_ts=$( [[ -n "$adj_end_ts_raw" ]] && echo "${adj_end_ts_raw%.*}" || date -d "$end_time" +%s )

    # 4. Local WAL Discovery
    # Scans the active WAL directory and filters by the LSN boundary.
    find "$wal_dir" -maxdepth 1 -type f -newermt "$begin_time" ! -newermt "@$adj_end_ts" -printf "%f\t%p\n" | \
        awk -v boundary="$boundary_wal" '$1 <= boundary {print $2}' | \
        head -n "$max_xlog" > "$temp_list"

    # 5. Archive Retrieval Decision Logic
    # If the local count is insufficient and archive_mode is enabled, probe the archive repository.
    local current_count
    current_count=$(wc -l < "$temp_list")
    local archive_mode
    archive_mode=$(run_collect_log_param "archive_mode")

    if [[ "$archive_mode" == "on" && "$current_count" -lt "$max_xlog" ]]; then
        # Check if the earliest required WAL has already been recycled from local storage.
        local oldest_valid_local
        oldest_valid_local=$(find "$wal_dir" -maxdepth 1 -type f -not -newermt "$begin_time" -printf "%f\n" | \
            awk -v boundary="$boundary_wal" '$1 <= boundary {print $1}' | head -1)

        if [[ -z "$oldest_valid_local" ]]; then
            local arch_path=""
            local arch_dest
            arch_dest=$(run_collect_log_param "archive_dest")
            
            # Resolve archive path from destination or by parsing the archive command.
            if [[ -n "$arch_dest" ]]; then
                arch_path="$arch_dest"
            else
                local arch_cmd
                arch_cmd=$(run_collect_log_param "archive_command")
                # Extract path components (supports custom instance-based directory structures).
                if [[ "$arch_cmd" =~ "-B" ]]; then
                    local b_p=$(echo "$arch_cmd" | sed -n 's/.*-B \([^ ]*\).*/\1/p')
                    local inst=$(echo "$arch_cmd" | sed -n 's/.*--instance \([^ ]*\).*/\1/p')
                    arch_path="${b_p}/wal/${inst}"
                else
                    arch_path=$(echo "$arch_cmd" | awk '{print $3}' | xargs dirname 2>/dev/null)
                fi
            fi

            # Append segments found in the archive repository.
            if [[ -d "$arch_path" ]]; then
                find "$arch_path" -maxdepth 1 -type f -newermt "$begin_time" ! -newermt "@$adj_end_ts" | \
                    head -n "$((max_xlog - current_count))" >> "$temp_list"
            fi
        fi
    fi

    # 6. Consolidation and Compression
    local final_dir="$output_dir/xlog"
    mkdir -p "$final_dir"

    sort -u "$temp_list" | head -n "$max_xlog" | xargs -I {} cp -p {} "$final_dir/"

    if [[ -n "$(ls -A "$final_dir" 2>/dev/null)" ]]; then
        tar -czf "$output_dir/wal_segments_backup.tar.gz" -C "$output_dir" xlog
        echo "[INFO ] Successfully collected $(ls "$final_dir" | wc -l) WAL segment(s)."
    else
        echo "[WARN ] No WAL segments found within the specified time range."
    fi

    rm -f "$temp_list"
	rm -f "$output_dir/wal_segments_backup.tar.gz"
}
