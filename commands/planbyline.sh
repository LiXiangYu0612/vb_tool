#!/bin/bash
# Command: planbyline - Analyze execution plan by line

planbyline_help() {
    echo "Usage: vb_tool planbyline [file]"
    echo "Description: Analyze execution plan and output self-time ratio by line."
    echo ""
}
planbyline() {
    if [ ! -f "$1" ]; then
        planbyline_help
        return 1
    fi

    cat "$1" | awk '
    BEGIN {
        r_line = 0; f_div = 0; m_t = 0; idx = 0;
    }
    {
        if ($0 ~ /^----/) {
            if (f_div == 0) { r_line = 0; f_div = 1; next; }
        }
        r_line++;
        
        if ($0 ~ /actual time=/) {
            match($0, /^[ ]*/);
            ind = RLENGTH;
            
            s_p = index($0, "actual time=") + 12;
            s_s = substr($0, s_p);
            d_p = index(s_s, "..");
            sp_p = index(s_s, " ");
            c_t = substr(s_s, d_p + 2, sp_p - d_p - 2) + 0;
            if (c_t > m_t) m_t = c_t;

            c_lp = "";
            if ($0 ~ /loops=/) {
                lp_i = index($0, "loops=") + 6;
                lp_s = substr($0, lp_i); gsub(/\).*/, "", lp_s);
                c_lp = lp_s;
            }

            op_p = $0;
            sub(/^[ ]*->[ ]*/, "", op_p);
            sub(/^[ ]*/, "", op_p);
            cp = index(op_p, "  (");
            op_n = (cp > 0) ? substr(op_p, 1, cp - 1) : op_p;

            if (op_n != "") {
                idx++;
                i_arr[idx] = ind;
                t_arr[idx] = c_t;
                l_str[idx] = r_line;
                o_arr[idx] = op_n;
                
                if ((op_n ~ /Scan/ || op_n ~ /Node/) && c_lp != "") {
                    o_arr[idx] = o_arr[idx] " (loops=" c_lp ")";
                }

                for (px = idx - 1; px >= 1; px--) {
                    if (i_arr[px] < ind) {
                        p_idx[idx] = px;
                        c_ord[px]++;
                        if (o_arr[px] ~ /Nested Loop/ && c_ord[px] == 2) {
                            l_str[px] = l_str[px] "->" r_line;
                            o_arr[px] = o_arr[px] " (loops=" c_lp ")";
                        }
                        break;
                    }
                }
            }
        }
    }
    END {
        if (idx == 0) exit 1;
        for (i = 1; i <= idx; i++) {
            n_sum = 0;
            for (j = i + 1; j <= idx; j++) {
                if (i_arr[j] <= i_arr[i]) break;
                if (p_idx[j] == i) n_sum += t_arr[j];
            }
            res_s[i] = t_arr[i] - n_sum;
            if (res_s[i] < 0) res_s[i] = 0;
        }
        for (i = 1; i <= idx; i++) {
            rat = (m_t > 0) ? (res_s[i] / m_t * 100) : 0;
            printf "%.3f|%.2f%%|%s|%s\n", res_s[i], rat, l_str[i], o_arr[i];
        }
    }' | sort -rn -t'|' -k1 | awk -F'|' '
    BEGIN {
        printf "%-8s | %-15s | %-8s | %s\n", "Ratio(%)", "Self Time(ms)", "Line", "Operation";
        print "--------------------------------------------------------------------------------------------------------------------------------";
    }
    {
        printf "%-8s | %-15.3f | %-8s | %s\n", $2, $1, $3, $4;
    }'
    return ${PIPESTATUS[0]}
}
