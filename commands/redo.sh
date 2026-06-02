#!/bin/bash
# Command: redo - Analyze redo log generation

redo_help() {
    echo "Options for redo:"
    echo "  Usage: vb_tool redo -f <log_file> [options]"
    echo "  Description: Analyze Vastbase WAL generation and replication lag"
    echo "    -f <file>    Vastbase log file (required)"
    echo "    -m <mode>    primary or standby (default: primary)"
    echo "    -s <file>    standby log file for replication analysis"
    echo ""
    echo "  Examples:"
    echo "    run_redo -f primary.log                    # WAL generation"
    echo "    run_redo -f standby.log -m standby        # Standby replay"
    echo "    run_redo -f primary.log -s standby.log    # Replication lag"
    echo ""
}
run_redo() {
    local log_file=""
    local mode="primary"
    local standby_log=""
    
    while getopts "f:m:s:" opt; do
      case $opt in
        f) log_file="$OPTARG" ;;
        m) mode="$OPTARG" ;;
        s) standby_log="$OPTARG" ;;
        \?) 
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires argument" >&2
            exit 1
            ;;
      esac
    done

    if [ -z "$log_file" ]; then
        echo "Error: -f (log file) parameter is required" >&2
        exit 1
    fi
    
    if [ ! -f "$log_file" ]; then
        echo "Error: Log file '$log_file' does not exist" >&2
        exit 1
    fi

    if [ "$mode" = "primary" ] && [ ! -z "$standby_log" ] && [ ! -f "$standby_log" ]; then
        echo "Error: Standby log file '$standby_log' does not exist" >&2
        exit 1
    fi
    
    if [ "$mode" = "primary" ]; then
        awk -v standby_log="$standby_log" '
        function hex_to_decimal(hex_str) {
            return strtonum("0x" hex_str)
        }

        function pg_xlog_location_diff(new_lsn, old_lsn) {
            if (new_lsn == "" || old_lsn == "") return "N/A"
            
            split(new_lsn, new_parts, "/")
            split(old_lsn, old_parts, "/")
            
            if (length(new_parts) != 2 || length(old_parts) != 2) return "N/A"
            
            new_xlogid = hex_to_decimal(new_parts[1])
            new_xrecoff = hex_to_decimal(new_parts[2])
            old_xlogid = hex_to_decimal(old_parts[1])
            old_xrecoff = hex_to_decimal(old_parts[2])
            new_total = (new_xlogid * 4294967296) + new_xrecoff
            old_total = (old_xlogid * 4294967296) + old_xrecoff
            
            diff = new_total - old_total
            if (diff < 0) return "N/A"
            return diff
        }

        function format_bytes(bytes) {
            if (bytes == "N/A") return "N/A"
            if (bytes >= 1073741824) {
                return sprintf("%.2fGB", bytes/1073741824)
            } else if (bytes >= 1048576) {
                return sprintf("%.2fMB", bytes/1048576)
            } else if (bytes >= 1024) {
                return sprintf("%.2fKB", bytes/1024)
            } else {
                return sprintf("%dB", bytes)
            }
        }

        function format_speed(bytes, seconds) {
            if (bytes == "N/A" || seconds == "N/A" || seconds <= 0) return "N/A"
            speed = bytes / seconds
            if (speed >= 1073741824) {
                return sprintf("%.2fGB/s", speed/1073741824)
            } else if (speed >= 1048576) {
                return sprintf("%.2fMB/s", speed/1048576)
            } else if (speed >= 1024) {
                return sprintf("%.2fKB/s", speed/1024)
            } else {
                return sprintf("%dB/s", speed)
            }
        }

        function time_to_seconds(time_str) {
            cmd = "date -d \"" time_str "\" +%s 2>/dev/null"
            cmd | getline epoch
            close(cmd)
            return epoch
        }

        BEGIN {
            if (standby_log != "") {
                while ((getline line < standby_log) > 0) {
                    if (line ~ /CreateRestartPoint.*newRedo:/) {
                        if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                            standby_time = substr(line, RSTART, 19)
                        }
                        if (match(line, /newRedo:([0-9A-F]+\/[0-9A-F]+)/, arr)) {
                            lsn = arr[1]
                            standby_map[lsn] = standby_time
                            standby_bytes[lsn] = pg_xlog_location_diff(lsn, "0/0")
                        }
                    }
                }
                close(standby_log)
            }
            
            header_printed = 0
            collect_slots = 0
            has_slots = 0
            slot_idx = 0
            prev_time_seconds = 0
            prev_redo_val = ""
            prev_redo_bytes = 0
            last_match_time = ""
            last_match_redo = ""
            last_match_bytes = 0
        }

        standby_log == "" && /slotname:/ && /restartlsn:/ {
            collect_slots = 1
            has_slots = 1
            
            line = $0
            sub(/.*slotname: /, "", line)
            slot = line
            sub(/,.*/, "", slot)
            
            line = $0
            sub(/.*restartlsn: /, "", line)
            lsn = line
            sub(/[ ,].*/, "", lsn)
            
            slots[slot] = lsn
            slot_list[++slot_idx] = slot
            next
        }

        standby_log == "" && collect_slots == 1 && /slotname:/ && /restartlsn:/ {
            line = $0
            sub(/.*slotname: /, "", line)
            slot = line
            sub(/,.*/, "", slot)
            
            line = $0
            sub(/.*restartlsn: /, "", line)
            lsn = line
            sub(/[ ,].*/, "", lsn)
            
            slots[slot] = lsn
            slot_list[++slot_idx] = slot
            next
        }

        /CreateCheckPoint PrintCkpXctlControlFile/ {
            if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                full_time_str = substr($0, RSTART, 19)
            }
            
            line = $0
            sub(/.*newRedo:/, "", line)
            new_redo_val = line
            sub(/[ ,].*/, "", new_redo_val)
            
            line = $0
            sub(/.*oldRedo:/, "", line)
            old_redo_val = line
            sub(/[ ,].*/, "", old_redo_val)
            
            if (full_time_str != "" && new_redo_val != "" && old_redo_val != "") {
                diff_bytes = pg_xlog_location_diff(new_redo_val, old_redo_val)
                diff_formatted = format_bytes(diff_bytes)
                
                current_redo_bytes = pg_xlog_location_diff(new_redo_val, "0/0")
                current_seconds = time_to_seconds(full_time_str)
                
                wal_speed = "N/A"
                if (prev_time_seconds > 0 && current_seconds > 0) {
                    time_interval = current_seconds - prev_time_seconds
                    if (time_interval > 0 && prev_redo_bytes > 0 && current_redo_bytes > 0) {
                        checkpoint_diff = current_redo_bytes - prev_redo_bytes
                        if (checkpoint_diff > 0) {
                            wal_speed = format_speed(checkpoint_diff, time_interval)
                        }
                    }
                }
                
                if (current_redo_bytes > 0) {
                    prev_redo_bytes = current_redo_bytes
                }
                
                replay_delay = "N/A"
                replay_speed = "N/A"
                standby_replay_time = "N/A"
                
                if (new_redo_val in standby_map) {
                    standby_time = standby_map[new_redo_val]
                    standby_replay_time = standby_time
                    current_match_bytes = standby_bytes[new_redo_val]
                    
                    standby_seconds = time_to_seconds(standby_time)
                    if (current_seconds > 0 && standby_seconds > 0) {
                        delay_seconds = standby_seconds - current_seconds
                        if (delay_seconds >= 0) {
                            if (delay_seconds >= 3600) {
                                hours = int(delay_seconds / 3600)
                                minutes = int((delay_seconds % 3600) / 60)
                                replay_delay = sprintf("%dh%dm", hours, minutes)
                            } else if (delay_seconds >= 60) {
                                minutes = int(delay_seconds / 60)
                                seconds = int(delay_seconds % 60)
                                replay_delay = sprintf("%dm%ds", minutes, seconds)
                            } else {
                                replay_delay = sprintf("%ds", delay_seconds)
                            }
                        }
                    }
                    
                    if (last_match_time != "" && last_match_bytes > 0) {
                        last_seconds = time_to_seconds(last_match_time)
                        current_standby_seconds = time_to_seconds(standby_time)
                        
                        if (last_seconds > 0 && current_standby_seconds > 0) {
                            time_diff = current_standby_seconds - last_seconds
                            bytes_diff = current_match_bytes - last_match_bytes
                            if (time_diff > 0 && bytes_diff > 0) {
                                replay_speed = format_speed(bytes_diff, time_diff)
                            }
                        }
                    }
                    
                    last_match_time = standby_time
                    last_match_redo = new_redo_val
                    last_match_bytes = current_match_bytes
                }
                
                if (!header_printed) {
                    if (standby_log != "") {
                        printf "%-20s %-20s %-15s %-15s %-20s %-15s %-15s\n", 
                               "Time", "redo_loc", "wal_gen", "wal_speed", 
                               "replay_time", "replay_delay", "replay_speed"
                        printf "%-20s %-20s %-15s %-15s %-20s %-15s %-15s\n", 
                               "--------------------", "--------------------", 
                               "---------------", "---------------",
                               "--------------------", "---------------", "---------------"
                    } else {
                        printf "%-20s %-20s %-15s %-15s", 
                               "Time", "redo_loc", "wal_gen", "wal_speed"
                        if (has_slots == 1 && slot_idx > 0) {
                            for (i = 1; i <= slot_idx; i++) {
                                printf " %-20s", slot_list[i]
                            }
                        }
                        printf "\n"
                        
                        printf "%-20s %-20s %-15s %-15s", 
                               "--------------------", "--------------------", 
                               "---------------", "---------------"
                        if (has_slots == 1 && slot_idx > 0) {
                            for (i = 1; i <= slot_idx; i++) {
                                printf " %-20s", "--------------------"
                            }
                        }
                        printf "\n"
                    }
                    header_printed = 1
                }
                
                if (standby_log != "") {
                    printf "%-20s %-20s %-15s %-15s %-20s %-15s %-15s\n", 
                           full_time_str, new_redo_val, diff_formatted, wal_speed,
                           standby_replay_time, replay_delay, replay_speed
                } else {
                    printf "%-20s %-20s %-15s %-15s", 
                           full_time_str, new_redo_val, diff_formatted, wal_speed
                    if (has_slots == 1 && slot_idx > 0) {
                        for (i = 1; i <= slot_idx; i++) {
                            slot = slot_list[i]
                            lsn_display = slots[slot]
                            printf " %-20s", lsn_display
                        }
                    }
                    printf "\n"
                }
            }
            
            prev_time_seconds = current_seconds
            prev_redo_val = new_redo_val
            collect_slots = 0
            has_slots = 0
            delete slots
            delete slot_list
            slot_idx = 0
        }

        END {
            if (!header_printed) {
                print "No checkpoint data found in log file!"
            }
        }
        ' "$log_file"
    
    elif [ "$mode" = "standby" ]; then
        printf "%-20s %-20s %-20s %-20s %-15s\n" "Time" "oldRedo" "newRedo" "replay_wal" "replay_speed"
        printf "%-20s %-20s %-20s %-20s %-15s\n" "--------------------" "--------------------" "--------------------" "--------------------" "---------------"
        
        grep "CreateRestartPoint.*newRedo:" "$log_file" | awk '
        function hex_to_decimal(hex_str) {
            return strtonum("0x" hex_str)
        }

        function pg_xlog_location_diff(new_lsn, old_lsn) {
            if (new_lsn == "" || old_lsn == "") return "N/A"
            
            split(new_lsn, new_parts, "/")
            split(old_lsn, old_parts, "/")
            
            if (length(new_parts) != 2 || length(old_parts) != 2) return "N/A"
            
            new_xlogid = hex_to_decimal(new_parts[1])
            new_xrecoff = hex_to_decimal(new_parts[2])
            old_xlogid = hex_to_decimal(old_parts[1])
            old_xrecoff = hex_to_decimal(old_parts[2])
            new_total = (new_xlogid * 4294967296) + new_xrecoff
            old_total = (old_xlogid * 4294967296) + old_xrecoff
            
            diff = new_total - old_total
            if (diff < 0) return "N/A"
            return diff
        }

        function format_bytes(bytes) {
            if (bytes == "N/A") return "N/A"
            if (bytes >= 1073741824) {
                return sprintf("%.2fGB", bytes/1073741824)
            } else if (bytes >= 1048576) {
                return sprintf("%.2fMB", bytes/1048576)
            } else if (bytes >= 1024) {
                return sprintf("%.2fKB", bytes/1024)
            } else {
                return sprintf("%dB", bytes)
            }
        }

        function format_speed(bytes, seconds) {
            if (bytes == "N/A" || seconds == "N/A" || seconds <= 0) return "N/A"
            speed = bytes / seconds
            if (speed >= 1073741824) {
                return sprintf("%.2fGB/s", speed/1073741824)
            } else if (speed >= 1048576) {
                return sprintf("%.2fMB/s", speed/1048576)
            } else if (speed >= 1024) {
                return sprintf("%.2fKB/s", speed/1024)
            } else {
                return sprintf("%dB/s", speed)
            }
        }
        
        BEGIN {
            prev_seconds = 0
            prev_redo_bytes = 0
            prev_redo_val = ""
        }
        {
            if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                time_str = substr($0, RSTART, 19)
                
                cmd = "date -d \"" time_str "\" +%s 2>/dev/null"
                cmd | getline current_seconds
                close(cmd)
            }
            
            old_redo = "N/A"
            if (match($0, /oldRedo:([0-9A-F]+\/[0-9A-F]+)/, arr)) {
                old_redo = arr[1]
            }
            
            new_redo = "N/A"
            if (match($0, /newRedo:([0-9A-F]+\/[0-9A-F]+)/, arr)) {
                new_redo = arr[1]
            }
            
            replay_wal = "N/A"
            replay_speed = "N/A"
            if (old_redo != "N/A" && new_redo != "N/A") {
                diff_bytes = pg_xlog_location_diff(new_redo, old_redo)
                replay_wal = format_bytes(diff_bytes)
                current_redo_bytes = pg_xlog_location_diff(new_redo, "0/0")
                
                if (prev_seconds > 0 && current_seconds > 0 && prev_redo_bytes > 0) {
                    time_interval = current_seconds - prev_seconds
                    bytes_diff = current_redo_bytes - prev_redo_bytes
                    if (time_interval > 0 && bytes_diff > 0) {
                        replay_speed = format_speed(bytes_diff, time_interval)
                    }
                }
                
                prev_redo_bytes = current_redo_bytes
                prev_redo_val = new_redo
            }
            
            printf "%-20s %-20s %-20s %-20s %-15s\n", time_str, old_redo, new_redo, replay_wal, replay_speed
            
            prev_seconds = current_seconds
        }'
    fi
}

