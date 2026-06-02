#!/bin/bash
# Command: workload - Collect workload information

workload_help() {
    echo "Usage: vb_tool workload <begin|end> [options]"
    echo ""
    echo "Description:"
    echo "  Collect workload information and generate performance report."
    echo ""
    echo "Commands:"
    echo "  begin              Start workload collection"
    echo "  end                End workload collection and generate report"
    echo ""
    echo "Options (only valid with 'end'):"
    echo "  -n <number>        Top N statements to display (default: 30)"
    echo "  -o <order_by>      Order statements by the specified metric (default: total_dbtime)"
    echo "                       dbtime   - Order by total DB time"
    echo "                       cpu      - Order by total CPU time"
    echo "                       io       - Order by total IO time"
    echo ""
    echo "Examples:"
    echo "  vb_tool workload begin"
    echo "  vb_tool workload end"
    echo "  vb_tool workload end -n 50"
    echo "  vb_tool workload end -n 50 -o io"
    echo "  vb_tool workload end -o cpu -n 20"
    echo ""
}
run_workload() {
    local action=""
    local top_n=30
    local order_by="total_dbtime"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)
                top_n="$2"
                shift 2
                ;;
            -o)
                order_by="$2"
                shift 2
                ;;
            begin|end)
                action="$1"
                shift
                ;;
            *)
                echo "Error: Invalid option or parameter '$1'" >&2
                workload_help
                exit 1
                ;;
        esac
    done
    
    if [ -z "$action" ]; then
        echo "Error: workload requires begin/end parameter" >&2
        workload_help
        exit 1
    fi
    
    case "$action" in
        begin)
            echo "Starting workload collection"
            rm -f /tmp/vb_tool_diskstats_bak \
                  /tmp/vb_tool_cpustat_bak \
                  /tmp/vb_tool_interrupts_bak \
                  /tmp/vb_tool_softirqs_bak \
                  /tmp/vb_tool_netdev_bak
            cp /proc/diskstats   /tmp/vb_tool_diskstats_bak
            cp /proc/stat        /tmp/vb_tool_cpustat_bak
            cp /proc/interrupts  /tmp/vb_tool_interrupts_bak
            cp /proc/softirqs    /tmp/vb_tool_softirqs_bak
            cp /proc/net/dev     /tmp/vb_tool_netdev_bak
            psql -d postgres <<EOF
DO \$\$
DECLARE
BEGIN
  BEGIN
    EXECUTE 'CREATE TABLE vb_tool_statement_bak as select * from dbe_perf.statement where 1=2';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    EXECUTE 'CREATE TABLE vb_tool_event_bak as select * from dbe_perf.wait_events where 1=2';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    EXECUTE 'CREATE TABLE vb_tool_instance_bak as select * from gs_instance_time where 1=2';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    EXECUTE 'CREATE TABLE vb_tool_pagew_bak as select * from dbe_perf.global_pagewriter_status where 1=2';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    EXECUTE 'CREATE TABLE vb_tool_database_bak as select * from pg_stat_database where 1=2';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    EXECUTE 'CREATE TABLE vb_tool_time_bak as select current_timestamp as a where 1=2';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  EXECUTE 'TRUNCATE table vb_tool_statement_bak';
  EXECUTE 'TRUNCATE table vb_tool_event_bak';
  EXECUTE 'TRUNCATE table vb_tool_instance_bak';
  EXECUTE 'TRUNCATE table vb_tool_pagew_bak';
  EXECUTE 'TRUNCATE table vb_tool_database_bak';
  EXECUTE 'TRUNCATE table vb_tool_time_bak';
  
  INSERT INTO vb_tool_time_bak SELECT now();
  INSERT INTO vb_tool_statement_bak SELECT * FROM dbe_perf.statement;
  INSERT INTO vb_tool_event_bak SELECT * FROM dbe_perf.wait_events;
  INSERT INTO vb_tool_instance_bak SELECT * FROM gs_instance_time;
  INSERT INTO vb_tool_pagew_bak SELECT * FROM dbe_perf.global_pagewriter_status;
  INSERT INTO vb_tool_database_bak SELECT * FROM pg_stat_database;
END \$\$
EOF
            ;;
        end)
            local order_field=""
            local total_time_sql=""
            local total_time_label=""
            
            case "$order_by" in
                io|IO|total_iotime)
                    order_field="(a.data_io_time - COALESCE(b.data_io_time, 0))"
                    total_time_sql="ROUND((a.data_io_time - COALESCE(b.data_io_time, 0)) / 1e3) || '(' || ROUND(100*(a.data_io_time - COALESCE(b.data_io_time, 0)) / 1e3 / NULLIF(c.total_iotime, 0), 2) || '%)' AS total_iotime"
                    total_time_label="total_iotime"
                    ;;
                cpu|CPU|total_cputime)
                    order_field="(a.cpu_time - COALESCE(b.cpu_time, 0))"
                    total_time_sql="ROUND((a.cpu_time - COALESCE(b.cpu_time, 0)) / 1e3) || '(' || ROUND(100*(a.cpu_time - COALESCE(b.cpu_time, 0)) / 1e3 / NULLIF(c.total_cputime, 0), 2) || '%)' AS total_cputime"
                    total_time_label="total_cputime"
                    ;;
                dbtime|DBTIME|total_dbtime|*)
                    order_field="(a.db_time - COALESCE(b.db_time, 0))"
                    total_time_sql="ROUND((a.db_time - COALESCE(b.db_time, 0)) / 1e3) || '(' || ROUND(100*(a.db_time - COALESCE(b.db_time, 0)) / 1e3 / NULLIF(c.total_dbtime, 0), 2) || '%)' AS total_dbtime"
                    total_time_label="total_dbtime"
                    ;;
            esac

            # ---------------------------------------------------------------
            # _get_duration: elapsed seconds from DB begin snapshot
            # ---------------------------------------------------------------
            _get_duration() {
                local dur
                dur=$(psql -d postgres -tAq -c \
                    "SELECT round(EXTRACT(EPOCH FROM (now() - (SELECT a FROM vb_tool_time_bak))));" 2>/dev/null)
                if [[ -z "$dur" || "$dur" -le 0 ]]; then dur=1; fi
                echo "$dur"
            }

            # ---------------------------------------------------------------
            # _print_sysinfo: socket / core / thread / logical CPU topology
            # + per-CPU current frequency with min/max summary
            # Sources: /proc/cpuinfo, /sys/devices/system/cpu/cpuN/cpufreq/
            # ---------------------------------------------------------------
            _print_sysinfo() {
                local cpuinfo=/proc/cpuinfo
                if [ ! -f "$cpuinfo" ]; then
                    echo "  [WARN] /proc/cpuinfo not found"
                    return
                fi

                local logical_cpus sockets cores_per_socket threads_per_core total_cores
                logical_cpus=$(grep -c "^processor" "$cpuinfo")
                sockets=$(grep "^physical id" "$cpuinfo" | sort -u | wc -l)
                # If no physical id entries (VM / single socket), treat as 1
                [ "$sockets" -eq 0 ] && sockets=1
                cores_per_socket=$(grep "^cpu cores" "$cpuinfo" | head -1 | awk -F: '{print $2}' | tr -d ' ')
                [ -z "$cores_per_socket" ] && cores_per_socket=$(( logical_cpus / sockets ))
                total_cores=$(( sockets * cores_per_socket ))
                threads_per_core=$(( logical_cpus / (total_cores > 0 ? total_cores : 1) ))
                [ "$threads_per_core" -eq 0 ] && threads_per_core=1

                local model
                model=$(grep "^model name" "$cpuinfo" | head -1 | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}')

                printf "  %-22s : %s\n"  "CPU Model"             "$model"
                printf "  %-22s : %d\n"  "Sockets"               "$sockets"
                printf "  %-22s : %d\n"  "Cores per Socket"      "$cores_per_socket"
                printf "  %-22s : %d\n"  "Total Physical Cores"  "$total_cores"
                printf "  %-22s : %d\n"  "Threads per Core"      "$threads_per_core"
                printf "  %-22s : %d\n"  "Logical CPUs"          "$logical_cpus"

                # ---- current frequency summary (min / max / avg across all logical CPUs) ----
                # Priority: cpuinfo_cur_freq (hw-reported, kHz) -> scaling_cur_freq (governor, kHz)
                # Fallback:  "cpu MHz" field in /proc/cpuinfo
                local use_cpufreq=0
                [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ] && use_cpufreq=1

                # Collect all current frequencies into an awk-friendly stream, then compute
                # min/max/avg in one awk pass to avoid repeated shell arithmetic rounding.
                local freq_data=""
                for (( i=0; i<logical_cpus; i++ )); do
                    local cur_khz="" cur_mhz=""
                    local cpufreq_dir="/sys/devices/system/cpu/cpu${i}/cpufreq"
                    if [ "$use_cpufreq" -eq 1 ] && [ -d "$cpufreq_dir" ]; then
                        if [ -r "${cpufreq_dir}/cpuinfo_cur_freq" ]; then
                            cur_khz=$(cat "${cpufreq_dir}/cpuinfo_cur_freq" 2>/dev/null)
                        fi
                        if [ -z "$cur_khz" ] && [ -r "${cpufreq_dir}/scaling_cur_freq" ]; then
                            cur_khz=$(cat "${cpufreq_dir}/scaling_cur_freq" 2>/dev/null)
                        fi
                        [ -n "$cur_khz" ] && cur_mhz=$(awk "BEGIN{printf \"%.2f\", $cur_khz/1000}")
                    else
                        cur_mhz=$(awk -v proc="$i" '
                            /^processor/{p=($3==proc)}
                            p && /^cpu MHz/{gsub(/^cpu MHz[[:space:]]*:[[:space:]]*/,"");
                                           printf "%.2f", $0; exit}
                        ' "$cpuinfo")
                    fi
                    [ -n "$cur_mhz" ] && freq_data="${freq_data}${cur_mhz}\n"
                done

                echo ""
                if [ -n "$freq_data" ]; then
                    printf "$freq_data" | awk '
                        BEGIN { mn=999999; mx=0; sm=0; cnt=0 }
                        /^[0-9]/ {
                            v=$1+0; sm+=v; cnt++
                            if(v<mn) mn=v
                            if(v>mx) mx=v
                        }
                        END {
                            if(cnt==0){ print "  [WARN] Could not read CPU frequencies"; exit }
                            printf "  %-22s : %.1f MHz\n", "Freq Min", mn
                            printf "  %-22s : %.1f MHz\n", "Freq Max", mx
                            printf "  %-22s : %.1f MHz\n", "Freq Avg", sm/cnt
                        }
                    '
                else
                    echo "  [WARN] Could not read CPU frequencies"
                fi
            }

            # ---------------------------------------------------------------
            # _print_cpustats: per-CPU usage % from /proc/stat begin->end delta
            # Prints aggregate "cpu" row first, then per-core rows cpu0..cpuN
            # Columns: user% nice% sys% idle% iowait% irq% softirq% steal%
            # ---------------------------------------------------------------
            _print_cpustats() {
                local bak=/tmp/vb_tool_cpustat_bak
                if [ ! -f "$bak" ]; then
                    echo "  [WARN] No cpu stat snapshot ($bak). Did you run 'workload begin'?"
                    return
                fi

                declare -A bak_cpu
                while read -r name u ni s id iow irq si st _rest; do
                    [[ "$name" =~ ^cpu ]] || continue
                    bak_cpu["$name"]="$u $ni $s $id $iow $irq $si $st"
                done < "$bak"

                printf "  %-8s %8s %8s %8s %8s %8s %8s %9s %8s\n" \
                    "CPU" "user%" "nice%" "sys%" "idle%" "iowait%" "irq%" "softirq%" "steal%"
                printf "  %-8s %8s %8s %8s %8s %8s %8s %9s %8s\n" \
                    "--------" "--------" "--------" "--------" "--------" "--------" "--------" "---------" "--------"

                # Print "cpu" (all-core aggregate) first, then individual cores
                local print_order=()
                while read -r name _rest; do
                    [[ "$name" =~ ^cpu ]] || continue
                    print_order+=("$name")
                done < /proc/stat
                # Sort: "cpu" before "cpu0","cpu1",...
                IFS=$'\n' sorted_order=($(printf '%s\n' "${print_order[@]}" | \
                    awk '{if($0=="cpu") print "0_"$0; else {sub(/cpu/,""); print 1+0"_cpu"$0}}' | \
                    sort -t_ -k1,1n -k2,2V | awk -F_ '{print $2}'))
                unset IFS

                for name in "${sorted_order[@]}"; do
                    [ -z "${bak_cpu[$name]+_}" ] && continue
                    # Read current values from /proc/stat
                    read -r _n u ni s id iow irq si st _rest <<< \
                        "$(grep "^${name}[[:space:]]" /proc/stat | head -1)"

                    read -r bu bni bs bid biow birq bsi bst <<< "${bak_cpu[$name]}"

                    local du=$(( u   - bu   ))
                    local dni=$(( ni  - bni  ))
                    local ds=$(( s   - bs   ))
                    local did=$(( id  - bid  ))
                    local diow=$(( iow - biow ))
                    local dirq=$(( irq - birq ))
                    local dsi=$(( si  - bsi  ))
                    local dst=$(( st  - bst  ))
                    local dtotal=$(( du + dni + ds + did + diow + dirq + dsi + dst ))
                    [ "$dtotal" -le 0 ] && continue

                    # Insert separator line between aggregate and per-core rows
                    if [[ "$name" == "cpu0" ]]; then
                        printf "  %s\n" "$(printf '%-8s %8s %8s %8s %8s %8s %8s %9s %8s' \
                            "--------" "--------" "--------" "--------" "--------" "--------" "--------" "---------" "--------")"
                    fi

                    awk -v name="$name" \
                        -v du=$du -v dni=$dni -v ds=$ds -v did=$did \
                        -v diow=$diow -v dirq=$dirq -v dsi=$dsi -v dst=$dst \
                        -v dt=$dtotal \
                    'BEGIN{
                        printf "  %-8s %7.2f%% %7.2f%% %7.2f%% %7.2f%% %7.2f%% %7.2f%% %8.2f%% %7.2f%%\n",
                            name,
                            du/dt*100, dni/dt*100, ds/dt*100, did/dt*100,
                            diow/dt*100, dirq/dt*100, dsi/dt*100, dst/dt*100
                    }'
                done
            }

            # ---------------------------------------------------------------
            # _print_irqstats: NIC soft-IRQ + I/O hard-IRQ counts per CPU
            #
            # Soft-IRQ : /proc/softirqs  rows NET_RX, NET_TX
            # Hard-IRQ : /proc/interrupts lines whose description matches
            #            nvme|sata|ahci|scsi|mpt|virtio.*blk|megaraid|hpsa|fusion
            # Only rows with at least one non-zero delta CPU are printed.
            # ---------------------------------------------------------------
            _print_irqstats() {
                local sirq_bak=/tmp/vb_tool_softirqs_bak
                local hirq_bak=/tmp/vb_tool_interrupts_bak

                # ---------- helper: print a dynamic-width CPU header ----------
                _irq_hdr() {
                    local ncpu=$1 lbl_w=$2 desc_w=$3
                    [ -n "$desc_w" ] && printf "  %-${lbl_w}s %-${desc_w}s" "IRQ" "Description" \
                        || printf "  %-${lbl_w}s" "Type"
                    for ((c=0; c<ncpu; c++)); do printf " %10s" "CPU$c"; done
                    printf "\n"
                    [ -n "$desc_w" ] && printf "  %-${lbl_w}s %-${desc_w}s" \
                        "$(printf '%0.s-' $(seq 1 $lbl_w))" \
                        "$(printf '%0.s-' $(seq 1 $desc_w))" \
                        || printf "  %-${lbl_w}s" "$(printf '%0.s-' $(seq 1 $lbl_w))"
                    for ((c=0; c<ncpu; c++)); do printf " %10s" "----------"; done
                    printf "\n"
                }

                # ---- 1. NIC Soft-IRQ (NET_RX / NET_TX) ----
                echo "  -- NIC Soft-IRQ (NET_RX / NET_TX) per CPU --"
                if [ ! -f "$sirq_bak" ]; then
                    echo "  [WARN] No softirqs snapshot ($sirq_bak). Did you run 'workload begin'?"
                else
                    local ncpu
                    ncpu=$(head -1 /proc/softirqs | awk '{print NF}')
                    _irq_hdr "$ncpu" 12 ""

                    for irq_type in NET_RX NET_TX; do
                        local now_line bak_line
                        now_line=$(grep "^ *${irq_type}:" /proc/softirqs 2>/dev/null || true)
                        bak_line=$(grep "^ *${irq_type}:" "$sirq_bak"    2>/dev/null || true)
                        [ -z "$now_line" ] && continue

                        read -ra now_vals <<< "$(echo "$now_line" | awk '{$1=""; print}')"
                        read -ra bak_vals <<< "$(echo "$bak_line" | awk '{$1=""; print}')"

                        # Skip if all-zero delta
                        local any=0
                        for ((c=0; c<ncpu; c++)); do
                            (( ${now_vals[$c]:-0} - ${bak_vals[$c]:-0} > 0 )) && any=1 && break
                        done
                        [ "$any" -eq 0 ] && continue

                        printf "  %-12s" "$irq_type"
                        for ((c=0; c<ncpu; c++)); do
                            printf " %10d" $(( ${now_vals[$c]:-0} - ${bak_vals[$c]:-0} ))
                        done
                        printf "\n"
                    done
                fi
                echo ""

                # ---- 2. I/O Hard-IRQ ----
                echo "  -- I/O Hard-IRQ (nvme/sata/ahci/scsi/mpt/virtio-blk/megaraid) per CPU --"
                if [ ! -f "$hirq_bak" ]; then
                    echo "  [WARN] No interrupts snapshot ($hirq_bak). Did you run 'workload begin'?"
                    return
                fi

                local hncpu
                hncpu=$(head -1 /proc/interrupts | awk '{print NF}')
                _irq_hdr "$hncpu" 6 28

                # Build bak map: irq_id -> raw line
                declare -A bak_hirq
                while IFS= read -r line; do
                    local id
                    id=$(echo "$line" | awk '{gsub(/:$/,"",$1); print $1}')
                    [[ -z "$id" ]] && continue
                    bak_hirq["$id"]="$line"
                done < <(tail -n +2 "$hirq_bak")

                local io_pat='nvme|sata|ahci|scsi|mpt|virtio.*blk|megaraid|hpsa|fusion'
                while IFS= read -r line; do
                    local desc
                    desc=$(echo "$line" | awk -v n="$hncpu" \
                        '{for(i=n+2;i<=NF;i++) printf "%s ",$i}' | tr '[:upper:]' '[:lower:]')
                    echo "$desc" | grep -qiE "$io_pat" || continue

                    local irq_id desc_short
                    irq_id=$(echo "$line" | awk '{gsub(/:$/,"",$1); print $1}')
                    desc_short=$(echo "$line" | awk -v n="$hncpu" \
                        '{for(i=n+2;i<=NF;i++) printf "%s ",$i}' | \
                        sed 's/^ *//;s/ *$//' | cut -c1-28)

                    read -ra now_vals <<< "$(echo "$line" | \
                        awk -v n="$hncpu" '{for(i=2;i<=n+1;i++) printf "%s ",$i}')"
                    read -ra bak_vals <<< "$(echo "${bak_hirq[$irq_id]:-}" | \
                        awk -v n="$hncpu" '{for(i=2;i<=n+1;i++) printf "%s ",$i}')"

                    local any=0
                    for ((c=0; c<hncpu; c++)); do
                        (( ${now_vals[$c]:-0} - ${bak_vals[$c]:-0} > 0 )) && any=1 && break
                    done
                    [ "$any" -eq 0 ] && continue

                    printf "  %-6s %-28s" "$irq_id" "$desc_short"
                    for ((c=0; c<hncpu; c++)); do
                        printf " %10d" $(( ${now_vals[$c]:-0} - ${bak_vals[$c]:-0} ))
                    done
                    printf "\n"
                done < <(tail -n +2 /proc/interrupts)
            }

            # ---------------------------------------------------------------
            # _print_netstats: per-NIC throughput, bandwidth, errors/drops
            # Source: /proc/net/dev  (begin snapshot vs now)
            # /proc/net/dev columns after "iface:":
            #   RX: bytes pkts errs drop fifo frame compressed multicast
            #   TX: bytes pkts errs drop fifo colls  carrier  compressed
            #
            # Output per interface:
            #   RX_Mbps TX_Mbps RX_MB/s TX_MB/s RX_pkts/s TX_pkts/s
            #   RX_err   RX_drp  TX_err  TX_drp  (total counts over interval)
            # Interfaces with zero RX+TX bytes delta and zero errors are skipped.
            # ---------------------------------------------------------------
            _print_netstats() {
                local bak=/tmp/vb_tool_netdev_bak
                if [ ! -f "$bak" ]; then
                    echo "  [WARN] No net/dev snapshot ($bak). Did you run 'workload begin'?"
                    return
                fi

                local duration
                duration=$(_get_duration)

                # Build begin snapshot map
                declare -A bak_net  # iface -> "rb rp re rd tb tp te td"
                while IFS= read -r line; do
                    [[ "$line" =~ : ]] || continue
                    local iface raw
                    iface=$(echo "$line" | awk -F: '{gsub(/ /,"",$1); print $1}')
                    raw=$(echo "$line"   | awk -F: '{print $2}')
                    read -r rb rp re rd rfi rfr rco rm tb tp te td tfi tc tca tco2 <<< "$raw"
                    bak_net["$iface"]="$rb $rp $re $rd $tb $tp $te $td"
                done < "$bak"

                # ---- throughput table (no Mbps columns, err/drop on same line) ----
                printf "\n  %-14s %10s %10s %12s %12s %10s %10s %10s %10s\n" \
                    "Interface" "RX_MB/s" "TX_MB/s" "RX_pkts/s" "TX_pkts/s" \
                    "RX_err" "RX_drop" "TX_err" "TX_drop"
                printf "  %-14s %10s %10s %12s %12s %10s %10s %10s %10s\n" \
                    "--------------" "----------" "----------" "------------" "------------" \
                    "----------" "----------" "----------" "----------"

                local printed_any=0
                while IFS= read -r line; do
                    [[ "$line" =~ : ]] || continue
                    local iface raw
                    iface=$(echo "$line" | awk -F: '{gsub(/ /,"",$1); print $1}')
                    [[ "$iface" == "lo" ]] && continue
                    [ -z "${bak_net[$iface]+_}" ] && continue

                    raw=$(echo "$line" | awk -F: '{print $2}')
                    read -r rb rp re rd rfi rfr rco rm tb tp te td tfi tc tca tco2 <<< "$raw"
                    read -r brb brp bre brd btb btp bte btd <<< "${bak_net[$iface]}"

                    local d_rb=$(( rb - brb )) d_rp=$(( rp - brp ))
                    local d_re=$(( re - bre )) d_rd=$(( rd - brd ))
                    local d_tb=$(( tb - btb )) d_tp=$(( tp - btp ))
                    local d_te=$(( te - bte )) d_td=$(( td - btd ))

                    # Skip interfaces with no traffic and no errors
                    (( d_rb + d_tb + d_re + d_rd + d_te + d_td == 0 )) && continue

                    awk -v iface="$iface" \
                        -v drb=$d_rb -v drp=$d_rp \
                        -v dtb=$d_tb -v dtp=$d_tp \
                        -v dre=$d_re -v drd=$d_rd \
                        -v dte=$d_te -v dtd=$d_td \
                        -v dur=$duration \
                    'BEGIN{
                        printf "  %-14s %10.3f %10.3f %12.1f %12.1f %10d %10d %10d %10d\n",
                            iface,
                            drb/dur/1048576, dtb/dur/1048576,
                            drp/dur,         dtp/dur,
                            dre, drd, dte, dtd
                    }'
                    printed_any=1
                done < /proc/net/dev

                [ "$printed_any" -eq 0 ] && echo "  (no interface traffic detected in this interval)"

                # ---- NIC speed / duplex via ethtool ----
                echo ""
                echo "  -- NIC Link Speed & Duplex --"
                printf "  %-14s %10s %8s %s\n" "Interface" "Speed" "Duplex" "Driver"
                printf "  %-14s %10s %8s %s\n" "--------------" "----------" "--------" "------"
                while IFS= read -r line; do
                    [[ "$line" =~ : ]] || continue
                    local iface
                    iface=$(echo "$line" | awk -F: '{gsub(/ /,"",$1); print $1}')
                    [[ "$iface" == "lo" ]] && continue
                    [ -z "${bak_net[$iface]+_}" ] && continue

                    local speed duplex drv
                    if command -v ethtool &>/dev/null; then
                        speed=$(ethtool "$iface" 2>/dev/null | awk '/Speed:/{print $2}')
                        duplex=$(ethtool "$iface" 2>/dev/null | awk '/Duplex:/{print $2}')
                    fi
                    drv=$(ethtool -i "$iface" 2>/dev/null | awk '/^driver:/{print $2}')
                    [ -z "$speed"  ] && speed="N/A"
                    [ -z "$duplex" ] && duplex="N/A"
                    [ -z "$drv"    ] && drv="N/A"
                    printf "  %-14s %10s %8s %s\n" "$iface" "$speed" "$duplex" "$drv"
                done < /proc/net/dev
            }

            _print_diskstats() {
                local bak=/tmp/vb_tool_diskstats_bak
                if [ ! -f "$bak" ]; then
                    echo "  [WARN] No diskstats snapshot found ($bak). Did you run 'workload begin'?"
                    return
                fi

                local duration
                duration=$(psql -d postgres -tAq -c \
                    "SELECT round(EXTRACT(EPOCH FROM (now() - (SELECT a FROM vb_tool_time_bak))));")

                if [ -z "$duration" ] || [ "$duration" -le 0 ]; then
                    duration=1
                fi

                declare -A bak_rc bak_rs bak_rms bak_wc bak_ws bak_wms

                while read -r _ _ dev rc rm rs rms wc wm ws wms _rest; do
                    [[ "$dev" =~ ^loop ]] && continue
                    [[ "$dev" =~ ^ram  ]] && continue
                    [[ "$dev" =~ [0-9]$ ]] && [[ "$dev" =~ ^[shv]d|^nvme[0-9]+n[0-9]+p ]] && continue
                    bak_rc["$dev"]=$rc; bak_rs["$dev"]=$rs; bak_rms["$dev"]=$rms
                    bak_wc["$dev"]=$wc; bak_ws["$dev"]=$ws; bak_wms["$dev"]=$wms
                done < "$bak"

                printf "  %-12s %10s %10s %12s %12s %12s %12s\n" \
                    "Device" "R_IOPS" "W_IOPS" "R_BW(MB/s)" "W_BW(MB/s)" "R_Lat(ms)" "W_Lat(ms)"
                printf "  %-12s %10s %10s %12s %12s %12s %12s\n" \
                    "------------" "----------" "----------" "------------" "------------" "------------" "------------"

                while read -r _ _ dev rc rm rs rms wc wm ws wms _rest; do
                    [[ "$dev" =~ ^loop ]] && continue
                    [[ "$dev" =~ ^ram  ]] && continue
                    [[ "$dev" =~ [0-9]$ ]] && [[ "$dev" =~ ^[shv]d|^nvme[0-9]+n[0-9]+p ]] && continue
                    [ -z "${bak_rc[$dev]+_}" ] && continue

                    local d_rc=$(( rc  - bak_rc[$dev] ))
                    local d_rs=$(( rs  - bak_rs[$dev] ))
                    local d_rms=$(( rms - bak_rms[$dev] ))
                    local d_wc=$(( wc  - bak_wc[$dev] ))
                    local d_ws=$(( ws  - bak_ws[$dev] ))
                    local d_wms=$(( wms - bak_wms[$dev] ))

                    local r_iops=$(awk "BEGIN{printf \"%.1f\", $d_rc/$duration}")
                    local w_iops=$(awk "BEGIN{printf \"%.1f\", $d_wc/$duration}")
                    local r_bw=$(awk   "BEGIN{printf \"%.2f\", $d_rs*512/1048576/$duration}")
                    local w_bw=$(awk   "BEGIN{printf \"%.2f\", $d_ws*512/1048576/$duration}")

                    local r_lat="N/A"
                    local w_lat="N/A"
                    [ "$d_rc" -gt 0 ] && r_lat=$(awk "BEGIN{printf \"%.2f\", $d_rms/$d_rc}")
                    [ "$d_wc" -gt 0 ] && w_lat=$(awk "BEGIN{printf \"%.2f\", $d_wms/$d_wc}")

                    printf "  %-12s %10s %10s %12s %12s %12s %12s\n" \
                        "$dev" "$r_iops" "$w_iops" "$r_bw" "$w_bw" "$r_lat" "$w_lat"
                done < /proc/diskstats
            }

            psql -d postgres <<EOF
\pset footer off
\echo '================================================================================'
\echo '                        VASTBASE WORKLOAD REPORT'
\echo '================================================================================'
\echo ''

select a::timestamp(0) begin_time,now()::timestamp(0) end_time,round(EXTRACT(EPOCH FROM (now() - (SELECT a FROM vb_tool_time_bak)))) duration from vb_tool_time_bak;
EOF
echo "=========================================="
echo "       OS PERFORMANCE STATISTICS          "
echo "=========================================="
			echo ""
            echo "1. CPU TOPOLOGY"
            echo "==============="
            _print_sysinfo

            echo ""
            echo "2. CPU USAGE STATISTICS"
            echo "======================="
            _print_cpustats

            echo ""
            echo "3. DISK I/O STATISTICS"
            echo "======================"
			run_lsds
			echo ""
            _print_diskstats

            echo ""
            echo "4. INTERRUPT STATISTICS "
            echo "========================"
            _print_irqstats

            echo ""
            echo "5. NETWORK INTERFACE STATISTICS"
            echo "==============================="
            _print_netstats
echo ""
echo "=========================================="
echo "     VASTBASE PERFORMANCE STATISTICS      "
echo "=========================================="
psql -d postgres <<EOF
\pset footer off
\echo '1. INSTANCE TIME STATISTICS'
\echo '==========================='
SELECT 
    CASE 
        WHEN a.stat_name = 'DB_TIME' THEN 'DB Time'
        WHEN a.stat_name = 'CPU_TIME' THEN 'CPU Time'
        WHEN a.stat_name = 'EXECUTION_TIME' THEN 'SQL Execution Time'
        WHEN a.stat_name = 'PARSE_TIME' THEN 'Parse Time'
        WHEN a.stat_name = 'PLAN_TIME' THEN 'Plan Time'
        WHEN a.stat_name = 'REWRITE_TIME' THEN 'Rewrite Time'
        WHEN a.stat_name = 'PL_EXECUTION_TIME' THEN 'PL/SQL Execution Time'
        WHEN a.stat_name = 'PL_COMPILATION_TIME' THEN 'PL/SQL Compilation Time'
        WHEN a.stat_name = 'NET_SEND_TIME' THEN 'Network Send Time'
        WHEN a.stat_name = 'DATA_IO_TIME' THEN 'Data IO Time'
        ELSE a.stat_name
    END as "Time Category",
    round((a.value - b.value)/1000000.0, 2) as "Time (seconds)",
    CASE 
        WHEN (SELECT value FROM gs_instance_time WHERE stat_name='DB_TIME') - (SELECT value FROM vb_tool_instance_bak WHERE stat_name='DB_TIME') > 0 
        THEN round((a.value - b.value) * 100.0 / ((SELECT value FROM gs_instance_time WHERE stat_name='DB_TIME') - (SELECT value FROM vb_tool_instance_bak WHERE stat_name='DB_TIME')), 2)
        ELSE 0
    END as "Percentage of DB Time (%)"
FROM gs_instance_time a, vb_tool_instance_bak b 
WHERE a.stat_id = b.stat_id
ORDER BY 
    CASE a.stat_name
        WHEN 'DB_TIME' THEN 1
        WHEN 'CPU_TIME' THEN 2
        WHEN 'EXECUTION_TIME' THEN 3
        WHEN 'DATA_IO_TIME' THEN 4
        WHEN 'PARSE_TIME' THEN 5
        WHEN 'PLAN_TIME' THEN 6
        WHEN 'REWRITE_TIME' THEN 7
        WHEN 'NET_SEND_TIME' THEN 8
        WHEN 'PL_EXECUTION_TIME' THEN 9
        WHEN 'PL_COMPILATION_TIME' THEN 10
        ELSE 11
    END;

\echo ''
\echo '2. LOAD PROFILE'
\echo '======================'
WITH x AS (
    SELECT 
        sum(a.xact_commit + a.xact_rollback - b.xact_commit - b.xact_rollback) as transactions,
        sum(a.blks_read - b.blks_read) as blocks_read,
        sum(a.blks_hit - b.blks_hit) as blocks_hit,
        sum(a.deadlocks - b.deadlocks) as deadlocks,
        sum(a.temp_bytes - b.temp_bytes) as tempbytes,
        CASE 
            WHEN sum(a.blks_read - b.blks_read + a.blks_hit - b.blks_hit) > 0 
            THEN round(sum(a.blks_hit - b.blks_hit) * 100.0 / sum(a.blks_read - b.blks_read + a.blks_hit - b.blks_hit), 2)
            ELSE 100
        END as hit_ratio
    FROM pg_stat_database a, vb_tool_database_bak b 
    WHERE a.datid = b.datid 
      AND a.datname NOT IN ('template0', 'template1')
),
y AS (
    SELECT 
        (a.pgwr_actual_flush_total_num - b.pgwr_actual_flush_total_num) as pages_flushed,
        (a.remain_dirty_page_num - b.remain_dirty_page_num) as remaining_dirty_pages_diff,
        pg_xlog_location_diff(a.current_xlog_insert_lsn, b.current_xlog_insert_lsn) as xlog_diff
    FROM dbe_perf.global_pagewriter_status a, vb_tool_pagew_bak b 
    WHERE a.node_name = b.node_name
),
z AS (
    SELECT round(EXTRACT(EPOCH FROM (now() - (SELECT a FROM vb_tool_time_bak)))) as duration 
    FROM vb_tool_time_bak
)
SELECT 
    'Transactions' as metric,
    x.transactions as total,
    round(x.transactions / z.duration, 2) as per_second
FROM x, z
UNION ALL
SELECT 
    'Blocks Read(blocks)',
    x.blocks_read,
    round(x.blocks_read / z.duration, 2)
FROM x, z
UNION ALL
SELECT 
    'Deadlocks',
    x.deadlocks,
    NULL
FROM x, z
UNION ALL
SELECT 
    'Hit Ratio (%)',
    x.hit_ratio,
    NULL  
FROM x, z
UNION ALL
SELECT 
    'Blocks Hit(blocks)',
    x.blocks_hit,
    round(x.blocks_hit / z.duration, 2)
FROM x, z
UNION ALL
SELECT 
    'Pages Flushed(blocks)',
    y.pages_flushed,
    round(y.pages_flushed / z.duration, 2)
FROM y, z
UNION ALL
SELECT 
    'Remaining Dirty Pages diff(blocks)',
    y.remaining_dirty_pages_diff,
    round(y.remaining_dirty_pages_diff / z.duration, 2)
FROM y, z
UNION ALL
SELECT 
    'Redo Size(Byte)',
    y.xlog_diff,
    round(y.xlog_diff / z.duration, 2)
FROM y, z
UNION ALL
SELECT 
    'Temp Size(Byte)',
    x.tempbytes,
    round(x.tempbytes / z.duration, 2)
FROM x, z;

\echo ''
\echo '3. WAIT EVENT STATISTICS'
\echo '========================'
SELECT 
    a.event as "Wait Event",
    a.type as "Wait Type",
    (a.wait - c.wait) as "Total Waits",
    round((a.total_wait_time - c.total_wait_time)/1000000.0, 2) as "Total Wait Time (s)",
    CASE 
        WHEN (a.wait - c.wait) > 0 
        THEN round((a.total_wait_time - c.total_wait_time)/1000.0/(a.wait - c.wait), 2)
        ELSE 0
    END as "Avg Wait Time (ms)"
FROM dbe_perf.wait_events a, vb_tool_event_bak c
WHERE a.event = c.event
  AND a.wait > c.wait
  AND a.event not in ('wait cmd','none')
ORDER BY (a.total_wait_time - c.total_wait_time) DESC
LIMIT 10;

\echo ''
\echo '4. STATEMENT STATISTICS (TOP ${top_n} BY ${total_time_label}(ms))'
\echo '================================================================'
WITH statement_bak AS (
    SELECT last_updated, user_name, n_calls, unique_sql_id, db_time, 
           n_soft_parse, n_hard_parse, 
           sort_spill_size + hash_spill_size AS temp_used, 
           total_elapse_time, execution_time, cpu_time, data_io_time, 
           parse_time, plan_time, rewrite_time, pl_execution_time, 
           n_blocks_fetched, n_blocks_hit, 
           n_returned_rows + n_tuples_inserted + n_tuples_updated + n_tuples_deleted AS n_returned_rows
    FROM vb_tool_statement_bak
),
statement_now AS (
    SELECT user_name, n_calls, unique_sql_id, db_time, n_soft_parse, n_hard_parse,
           sort_spill_size + hash_spill_size AS temp_used, total_elapse_time, 
           execution_time, cpu_time, data_io_time, parse_time, plan_time, 
           rewrite_time, pl_execution_time, n_blocks_fetched, n_blocks_hit,
           n_returned_rows + n_tuples_inserted + n_tuples_updated + n_tuples_deleted AS n_returned_rows,
           last_updated
    FROM dbe_perf.statement 
    WHERE last_updated > (SELECT MAX(last_updated) FROM statement_bak)
),
total_times AS (
     SELECT 
        ROUND(MAX(CASE WHEN a.stat_name = 'DB_TIME' THEN (a.value - b.value) END) / 1000.0, 2) AS total_dbtime,
        ROUND(MAX(CASE WHEN a.stat_name = 'DATA_IO_TIME' THEN (a.value - b.value) END) / 1000.0, 2) AS total_iotime,
        ROUND(MAX(CASE WHEN a.stat_name = 'CPU_TIME' THEN (a.value - b.value) END) / 1000.0, 2) AS total_cputime
    FROM gs_instance_time a, vb_tool_instance_bak b
    WHERE a.stat_id = b.stat_id
)
SELECT a.user_name,
       a.unique_sql_id,
       a.n_calls - COALESCE(b.n_calls, 0) AS n_calls,
       a.n_soft_parse - COALESCE(b.n_soft_parse, 0) AS n_soft,
       a.n_hard_parse - COALESCE(b.n_hard_parse, 0) AS n_hard,
       ${total_time_sql},
       ROUND((a.db_time - COALESCE(b.db_time, 0)) / 1e3 / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_db,
       ROUND((a.execution_time - COALESCE(b.execution_time, 0)) / 1e3 / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_et,
       ROUND(((a.parse_time + a.plan_time + a.rewrite_time) - COALESCE(b.parse_time + b.plan_time + b.rewrite_time, 0)) / 1e3 / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_parse,
       ROUND((a.cpu_time - COALESCE(b.cpu_time, 0)) / 1e3 / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_cpu,
       ROUND((a.data_io_time - COALESCE(b.data_io_time, 0)) / 1e3 / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_io,
       ROUND((a.n_blocks_fetched - COALESCE(b.n_blocks_fetched, 0)) / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_cr,
       ROUND((a.n_blocks_fetched - COALESCE(b.n_blocks_fetched, 0) - a.n_blocks_hit + COALESCE(b.n_blocks_hit, 0)) / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_pr,
       ROUND((a.n_returned_rows - COALESCE(b.n_returned_rows, 0)) / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_rows,
       ROUND((a.temp_used - COALESCE(b.temp_used, 0)) / GREATEST((a.n_calls - COALESCE(b.n_calls, 0)), 1), 1) AS avg_temp
FROM statement_now a 
LEFT JOIN statement_bak b ON a.user_name = b.user_name AND a.unique_sql_id = b.unique_sql_id
CROSS JOIN total_times c  
WHERE a.n_calls > COALESCE(b.n_calls, 0) 
ORDER BY ${order_field} DESC 
LIMIT ${top_n};
EOF
            echo ""
            echo "================================================================================"
            echo "                           END OF WORKLOAD REPORT"
            echo "================================================================================"
            ;;
        *)
            echo "Error: Invalid parameter '$action'. Use 'begin' or 'end'." >&2
            workload_help
            exit 1
            ;;
    esac
}
