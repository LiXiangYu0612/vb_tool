#!/bin/bash
# Command: net - display network information

net_help() {
    echo "Options for net:"
    echo "  Usage: vb_tool net"
    echo "  Description: display network information"
    echo ""
}

run_net() {
    export -f run_nets  
    watch -n 1 "bash -c run_nets"
	watch -t -n 1 "echo \"Every 1.0s: run_net\"; echo; bash -c run_nets"
}

run_nets() {
    local PORT=${PGPORT:-5432}
    
    echo "--- Socket Statistics ---"
    /usr/sbin/ss -s | awk '/^Total:|^TCP:|^Transport/ || ($1 == "TCP" && $2 ~ /^[0-9]+$/)'
    echo ""

    echo "--- Top 5 Connections (Port: $PORT) ---"
    printf '%-20s %-16s %-12s %-6s\n' "Local_Addr" "Remote_IP" "State" "Count"
    /usr/sbin/ss -tan4 sport = :$PORT | awk 'NR>1 && $1 != "LISTEN" {
        split($4, l, ":"); split($5, r, ":");
        key = l[1]":"l[2] " " r[1] " " $1;
        count[key]++
    } END { for (k in count) print count[k], k }' | sort -rn | head -5 | \
    while read -r cnt addr ip state; do
        printf '%-20s %-16s %-12s %-6s\n' "$addr" "$ip" "$state" "$cnt"
    done
    echo ""

    echo "--- Listening Sockets (Port: $PORT) ---"
    /usr/sbin/ss -lnt4 sport = :$PORT
    echo ""

    echo "--- Network Stats ---"
    /bin/netstat -s 2>/dev/null | grep -iE 'drop|over|err|lost|fail|retran|prune' | \
    grep -vE 'message failed|^[[:space:]]*0'
    echo ""

    echo "--- Interface Stats Summary ---"
    printf "%-10s %-15s %-8s %-8s %-8s %-8s %-8s\n" "IFACE" "IP" "RX_ERR" "RX_DRP" "TX_ERR" "TX_DRP" "COLL"
    echo "-----------------------------------------------------------------------"
    
    while read -r line; do
        [[ "$line" =~ ":" ]] || continue
        iface=$(echo "$line" | cut -d: -f1 | sed 's/ //g')
        [[ "$iface" == "lo" || "$iface" =~ "virbr" ]] && continue
        
        ip=$(/usr/sbin/ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        [ -z "$ip" ] && ip="-"
        
        stats=$(grep -w "$iface" /proc/net/dev)
        rx_err=$(echo "$stats" | awk '{print $4}')
        rx_drp=$(echo "$stats" | awk '{print $5}')
        tx_err=$(echo "$stats" | awk '{print $12}')
        tx_drp=$(echo "$stats" | awk '{print $13}')
        coll=$(echo "$stats" | awk '{print $15}')
        
        printf "%-10s %-15s %-8s %-8s %-8s %-8s %-8s\n" "$iface" "$ip" "$rx_err" "$rx_drp" "$tx_err" "$tx_drp" "$coll"
    done < /proc/net/dev
    echo ""

    echo "--- Interface Throughput ---"
    /bin/sar -n DEV 1 1 2>/dev/null | sed -n '/IFACE/,/^\$/p' | grep -v virbr | grep -v lo | grep -v Average
}
