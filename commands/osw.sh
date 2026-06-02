#!/bin/bash
# Command: osw - OSWatcher system monitoring

osw_help() {
    echo "Options for osw:"
    echo "  Usage: vb_tool osw [interval] [duration]"
    echo "  Description: collect system performance data similar to OSWatcher"
    echo "  Options:"
    echo "    interval: collection interval in seconds (default: 3)"
    echo "    duration: total collection duration in seconds (default: 60)"
    echo "  Output: system performance data saved to osw_<hostname>_<ip>_<timestamp>.log"
    echo ""
}
run_osw() {
    local interval=${1:-3}
    local duration=${2:-60}
    local timestamp=$(date +'%Y%m%d_%H%M%S')
    local hostname=$(hostname)
    local ip=$(hostname -I | awk '{print $1}')
    local output_file="osw_${hostname}_${ip}_${timestamp}.log"
    local start_time=$(date +'%Y-%m-%d %H:%M:%S')
    local start_seconds=$(date -d "$start_time" +%s)
    local end_seconds=$((start_seconds + duration))
    local end_time=$(date -d @$end_seconds +'%Y-%m-%d %H:%M:%S')
    
    # Validate parameters
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        echo "Error: interval must be a positive integer" >&2
        return 1
    fi
    
    if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -lt 1 ]; then
        echo "Error: duration must be a positive integer" >&2
        return 1
    fi
    
    # Print start information
    echo "====================================================================="
    echo "OSW Collection Started"
    echo "====================================================================="
    echo "Start Time: $start_time"
    echo "End Time:   $end_time"
    echo "Interval:   $interval seconds"
    echo "Duration:   $duration seconds"
    echo "====================================================================="
    
    # Get detailed OS information
    local os_info=$(cat /etc/os-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null || echo "Unknown")
    local os_name=$(echo "$os_info" | grep -E '^(NAME|PRETTY_NAME)=' | head -1 | cut -d= -f2 | tr -d '"')
    local os_version=$(echo "$os_info" | grep -E '^(VERSION|VERSION_ID)=' | head -1 | cut -d= -f2 | tr -d '"')
    if [ -z "$os_name" ]; then
        os_name=$(uname -s)
        os_version=$(uname -r)
    fi
    
    # Initialize output file
    echo "OSW Collection Report" > "$output_file"
    echo "=====================" >> "$output_file"
    echo "Start Time: $start_time" >> "$output_file"
    echo "End Time:   $end_time" >> "$output_file"
    echo "Interval:   $interval seconds" >> "$output_file"
    echo "Duration:   $duration seconds" >> "$output_file"
    echo "Hostname:   $(hostname)" >> "$output_file"
    echo "Platform:   $os_name $os_version" >> "$output_file"
    echo "Kernel:     $(uname -r)" >> "$output_file"
    echo "=====================" >> "$output_file"
    echo "" >> "$output_file"
    
    # Create temporary directory for parallel collection
    local temp_dir=$(mktemp -d)
    
    # Part 1: Static system information (run once)
    echo "Static System Information:" >> "$output_file"
    echo "========================" >> "$output_file"
    echo "" >> "$output_file"
    
    # System Uptime
    if command -v uptime >/dev/null 2>&1; then
        echo "=== System Uptime ===" >> "$output_file"
        uptime >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # CPU Information
    if command -v lscpu >/dev/null 2>&1; then
        echo "=== CPU Information ===" >> "$output_file"
        lscpu | head -10 >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Memory Information
    if command -v free >/dev/null 2>&1; then
        echo "=== Memory Information ===" >> "$output_file"
        free -h >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Disk Information
    if command -v df >/dev/null 2>&1; then
        echo "=== Disk Information ===" >> "$output_file"
        df -h >> "$output_file"
        echo "" >> "$output_file"
        
        echo "=== Disk Inode Information ===" >> "$output_file"
        df -i >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Block Devices
    if command -v lsblk >/dev/null 2>&1; then
        echo "=== Block Devices ===" >> "$output_file"
        lsblk >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Disk Type Information (SSD vs HDD)
    echo "=== Disk Type Information ===" >> "$output_file"
    if command -v lsblk >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
        for device in $(lsblk -d -o NAME | grep -v NAME); do
            if [ -f "/sys/block/$device/queue/rotational" ]; then
                local rotational=$(cat "/sys/block/$device/queue/rotational" 2>/dev/null)
                if [ "$rotational" == "0" ]; then
                    echo "$device: SSD" >> "$output_file"
                elif [ "$rotational" == "1" ]; then
                    echo "$device: HDD" >> "$output_file"
                else
                    echo "$device: Unknown" >> "$output_file"
                fi
            else
                echo "$device: Information not available" >> "$output_file"
            fi
        done
    else
        echo "Disk type information not available" >> "$output_file"
    fi
    echo "" >> "$output_file"
    
    # Network Connections
    if command -v netstat >/dev/null 2>&1; then
        echo "=== Network Connections ===" >> "$output_file"
        netstat -tuln >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Process List (top processes)
    if command -v ps >/dev/null 2>&1; then
        echo "=== Top Processes ===" >> "$output_file"
        ps -eo pid,ppid,user,pcpu,pmem,cmd --sort=-pcpu | head -20 >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Network Interface Configuration
    if command -v ip >/dev/null 2>&1; then
        echo "=== Network Interface Configuration ===" >> "$output_file"
        ip -s -s addr >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Part 2: Dynamic performance data (run with interval)
    echo "Dynamic Performance Data:" >> "$output_file"
    echo "========================" >> "$output_file"
    echo "" >> "$output_file"
    
    # Calculate number of samples
    local samples=$((duration / interval))
    if [ $((duration % interval)) -gt 0 ]; then
        samples=$((samples + 1))
    fi
    
    # Define dynamic commands by category
    local dynamic_commands=()
    local cmd_names=()
    local cmd_categories=()
    
    # CPU-related commands
    if command -v mpstat >/dev/null 2>&1; then
        dynamic_commands+=('mpstat -P ALL $interval $samples')
        cmd_names+=('mpstat')
        cmd_categories+=('cpu')
    fi
    
    if command -v sar >/dev/null 2>&1; then
        dynamic_commands+=('sar -u $interval $samples')
        cmd_names+=('sar-cpu')
        cmd_categories+=('cpu')
    fi
    
    if command -v top >/dev/null 2>&1; then
        dynamic_commands+=('top -b -n $((samples + 1)) -d $interval | grep -A 20 "Tasks:"')
        cmd_names+=('top')
        cmd_categories+=('cpu')
    fi
    
    # CPU context switch and thread CPU
    if command -v pidstat >/dev/null 2>&1; then
        dynamic_commands+=('pidstat -tw $interval $samples')
        cmd_names+=('pidstat-tw')
        cmd_categories+=('cpu')
    fi
    
    # Memory-related commands
    if command -v vmstat >/dev/null 2>&1; then
        dynamic_commands+=('vmstat $interval $samples')
        cmd_names+=('vmstat')
        cmd_categories+=('memory')
    fi
    
    if command -v sar >/dev/null 2>&1; then
        dynamic_commands+=('sar -r $interval $samples')
        cmd_names+=('sar-mem')
        cmd_categories+=('memory')
    fi
    
    # Memory detailed information
    if [ -f "/proc/meminfo" ]; then
        dynamic_commands+=('cat /proc/meminfo')
        cmd_names+=('meminfo')
        cmd_categories+=('memory')
    fi
    
    # Disk I/O-related commands
    if command -v iostat >/dev/null 2>&1; then
        dynamic_commands+=('iostat -xk $interval $samples')
        cmd_names+=('iostat')
        cmd_categories+=('io')
    fi
    
    if command -v sar >/dev/null 2>&1; then
        dynamic_commands+=('sar -d $interval $samples')
        cmd_names+=('sar-disk')
        cmd_categories+=('io')
    fi
    
    if command -v pidstat >/dev/null 2>&1; then
        dynamic_commands+=('pidstat -d $interval $samples')
        cmd_names+=('pidstat-disk')
        cmd_categories+=('io')
    fi
    
    # Network-related commands
    if command -v sar >/dev/null 2>&1; then
        dynamic_commands+=('sar -n DEV $interval $samples')
        cmd_names+=('sar-net')
        cmd_categories+=('network')
    fi
    
    # Network statistics
    if command -v netstat >/dev/null 2>&1; then
        dynamic_commands+=('netstat -s')
        cmd_names+=('netstat-s')
        cmd_categories+=('network')
    fi
    
    # Process-related commands
    if command -v pidstat >/dev/null 2>&1; then
        dynamic_commands+=('pidstat $interval $samples')
        cmd_names+=('pidstat')
        cmd_categories+=('process')
    fi
    
    # Run dynamic commands in parallel with better synchronization
    echo "Running dynamic performance collection..." >&2
    
    local pids=()
    local temp_files=()
    
    # Prepare all temporary files
    for i in "${!dynamic_commands[@]}"; do
        local cmd_name=${cmd_names[$i]}
        local temp_file="$temp_dir/$cmd_name.txt"
        temp_files+="$temp_file"
    done
    
    # Execute all commands in parallel
    for i in "${!dynamic_commands[@]}"; do
        local cmd=${dynamic_commands[$i]}
        local cmd_name=${cmd_names[$i]}
        local temp_file="$temp_dir/$cmd_name.txt"
        
        # Execute command in background with proper environment
        (eval "$cmd" > "$temp_file" 2>&1) &
        pids+=($!)
    done
    
    # Wait for all commands to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Collect and organize results by category
    local categories=('cpu' 'memory' 'io' 'network' 'process')
    local category_names=('CPU Performance' 'Memory Usage' 'Disk I/O' 'Network Activity' 'Process Statistics')
    
    for i in "${!categories[@]}"; do
        local category=${categories[$i]}
        local category_name=${category_names[$i]}
        local has_data=0
        
        # Check if any commands in this category have data
        for j in "${!cmd_categories[@]}"; do
            if [ "${cmd_categories[$j]}" == "$category" ]; then
                local cmd_name=${cmd_names[$j]}
                local temp_file="$temp_dir/$cmd_name.txt"
                if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
                    has_data=1
                    break
                fi
            fi
        done
        
        # If data exists for this category, output it
        if [ $has_data -eq 1 ]; then
            echo "=====================================================================" >> "$output_file"
            echo "=== $category_name ===" >> "$output_file"
            echo "=====================================================================" >> "$output_file"
            echo "" >> "$output_file"
            
            for j in "${!cmd_categories[@]}"; do
                if [ "${cmd_categories[$j]}" == "$category" ]; then
                    local cmd_name=${cmd_names[$j]}
                    local temp_file="$temp_dir/$cmd_name.txt"
                    
                    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
                        echo "--- $cmd_name ---" >> "$output_file"
                        echo "" >> "$output_file"
                        cat "$temp_file" >> "$output_file"
                        echo "" >> "$output_file"
                    fi
                fi
            done
        fi
    done
    
    # Clean up temporary directory
    rm -rf "$temp_dir"
    
    # Print completion information
    echo "====================================================================="
    echo "OSW Collection Completed"
    echo "====================================================================="
    echo "Start Time: $start_time"
    echo "End Time:   $(date +'%Y-%m-%d %H:%M:%S')"
    echo "Output File: $output_file"
    echo "====================================================================="
    
    # Add completion information to output file
    echo "=====================================================================" >> "$output_file"
    echo "OSW Collection Completed" >> "$output_file"
    echo "=====================================================================" >> "$output_file"
    echo "End Time:   $(date +'%Y-%m-%d %H:%M:%S')" >> "$output_file"
    echo "Output File: $output_file" >> "$output_file"
    echo "=====================================================================" >> "$output_file"
    
    return 0
}

