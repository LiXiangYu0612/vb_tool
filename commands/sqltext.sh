#!/bin/bash
# Command: sqltext - Display SQL text from slow log

sqltext_help() {
    echo "Options for text:"
    echo "  Usage: vb_tool sqltext [unique_query_id]"
    echo "  Description: display sqltext from postgresql slow log"
    echo ""
}
run_sqltext() {
    local unique_id="$1"

    local gauss_log
    gauss_log=$(env | grep -iw GAUSSLOG | cut -d'=' -f2)
    if [[ -z "$gauss_log" ]]; then
        echo "Error: not found GAUSSLOG path" >&2
        return 1
    fi
    if [[ ! -d "$gauss_log" ]]; then
        echo "Error: GAUSSLOG path not exits: $gauss_log" >&2
        return 1
    fi

    local logfiles
    logfiles=$(find "$gauss_log" -name "*.log" -type f -printf '%T@ %p\n' 2>/dev/null | \
               sort -rn | \
               head -n 50 | \
               cut -d' ' -f2-)

    if [[ -z "$logfiles" ]]; then
        echo "Warning: $gauss_log not found postgresql log" >&2
        return 1
    fi

    local grep_hits
    grep_hits=$(echo "$logfiles" | xargs grep -l "$unique_id" 2>/dev/null)

    if [[ -z "$grep_hits" ]]; then
        echo "Error: not found unique_id=${unique_id} in any log file" >&2
        return 1
    fi

    local matched_logfiles
    matched_logfiles=$(echo "$logfiles" | grep -Fx -f <(echo "$grep_hits"))

    SQLHC_LOGFILES="$matched_logfiles" python3 - "$unique_id" << 'PYEOF'
import sys
import re
import unicodedata
import subprocess
import os

unique_id = sys.argv[1]
logfiles = os.environ.get('SQLHC_LOGFILES', '').strip().splitlines()

def get_log_line_prefix():
    try:
        p = subprocess.Popen(
            ['psql', '-t', '-A', '-c', "SHOW log_line_prefix", '-d', 'postgres'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
        )
        stdout, _ = p.communicate(timeout=5)
        if p.returncode == 0 and stdout.strip():
            return stdout.strip()
    except Exception:
        pass

    try:
        p = subprocess.Popen(
            ['psql', '-t', '-A', '-c', "SHOW config_file", '-d', 'postgres'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
        )
        stdout, _ = p.communicate(timeout=5)
        if p.returncode == 0:
            config_file = stdout.strip()
            if config_file and os.path.exists(config_file):
                with open(config_file, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith('log_line_prefix') and not line.startswith('#'):
                            parts = line.split('=', 1)
                            if len(parts) == 2:
                                return parts[1].strip().strip("'\"")
    except Exception:
        pass

    val = os.environ.get('PGLOG_LINE_PREFIX', '')
    if val:
        return val

    print("ERROR: Cannot determine log_line_prefix", file=sys.stderr)
    sys.exit(1)

def parse_log_line_prefix(prefix):
    PLACEHOLDER_PATTERNS = {
        '%m': (r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+(?:\s+\S+)?', False),
        '%t': (r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\s+\S+)?',       False),
        '%u': (r'(\S+)',          True),
        '%d': (r'(\S+)',          True),
        '%p': (r'(\d+|\[\d+\])', True),
        '%h': (r'\S+',            False),
        '%r': (r'\S+',            False),
        '%l': (r'\d+',            False),
        '%s': (r'\S+',            False),
        '%c': (r'\S+',            False),
        '%x': (r'\S+',            False),
        '%v': (r'\S+',            False),
        '%n': (r'\S+',            False),
        '%i': (r'\S*',            False),
        '%e': (r'\S+',            False),
        '%q': (r'',               False),
        '%%': (r'%',              False),
    }
    regex_parts = []
    capture_order = []
    i = 0
    while i < len(prefix):
        if prefix[i] == '%' and i + 1 < len(prefix):
            ph = prefix[i:i+2]
            if ph in PLACEHOLDER_PATTERNS:
                pat, capture = PLACEHOLDER_PATTERNS[ph]
            else:
                pat, capture = (r'\S+', False)
            regex_parts.append(pat)
            if capture:
                capture_order.append(ph)
            i += 2
        else:
            regex_parts.append(re.escape(prefix[i]))
            i += 1

    full_pattern = (
        r'^' +
        ''.join(regex_parts) +
        r'(?:\s+\d+)?'
        r'\s*(?:\[\w+\])?\s*'
        r'(?:LOG|ERROR|WARNING|FATAL|PANIC|DEBUG\d*|INFO|NOTICE|DETAIL)'
        r':\s+'
    )
    compiled = re.compile(full_pattern)

    user_idx = db_idx = pid_idx = None
    for idx, ph in enumerate(capture_order, 1):
        if ph == '%u' and user_idx is None: user_idx = idx
        elif ph == '%d' and db_idx   is None: db_idx   = idx
        elif ph == '%p' and pid_idx  is None: pid_idx  = idx

    if user_idx is None:
        print(f"ERROR: log_line_prefix '{prefix}' missing %u", file=sys.stderr)
        sys.exit(1)
    if db_idx is None:
        print(f"ERROR: log_line_prefix '{prefix}' missing %d", file=sys.stderr)
        sys.exit(1)

    return compiled, user_idx, db_idx, pid_idx

log_line_prefix = get_log_line_prefix()
header_re, user_idx, db_idx, pid_idx = parse_log_line_prefix(log_line_prefix)

def extract_meta(line):
    m = header_re.match(line)
    if not m:
        return 'unknown', 'unknown', None
    g = m.groups()
    db   = g[db_idx   - 1] if db_idx   <= len(g) else 'unknown'
    user = g[user_idx - 1] if user_idx <= len(g) else 'unknown'
    pid  = g[pid_idx  - 1].strip('[]') if (pid_idx and pid_idx <= len(g)) else None
    return db, user, pid

def normalize_user(user):
    return 'public' if user.lower() == 'vastbase' else user

KW_NEWLINE = re.compile(
    r'\b('
    r'SELECT|FROM'
    r'|LEFT\s+OUTER\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+OUTER\s+JOIN'
    r'|LEFT\s+JOIN|RIGHT\s+JOIN|INNER\s+JOIN|CROSS\s+JOIN|JOIN'
    r'|WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|LIMIT|OFFSET'
    r'|ON\b|SET|VALUES|INSERT\s+INTO|UPDATE|DELETE\s+FROM'
    r'|WITH|UNION\s+ALL|UNION|INTERSECT|EXCEPT'
    r')\b',
    re.IGNORECASE
)

def format_sql(sql):
    sql = ' '.join(sql.split())
    def repl(m):
        return '\n' + re.sub(r'\s+', ' ', m.group(0).upper())
    sql = KW_NEWLINE.sub(repl, sql)
    lines = [ln.strip() for ln in sql.split('\n')]
    return '\n'.join(ln for ln in lines if ln).strip()

def parse_params(text):
    result = {}
    token_re = re.compile(r'\$(\d+)\s*=\s*')
    matches = list(token_re.finditer(text))
    for k, m in enumerate(matches):
        idx = int(m.group(1))
        val_start = m.end()
        val_end   = matches[k + 1].start() if k + 1 < len(matches) else len(text)
        val = text[val_start:val_end].strip().rstrip(',').strip()
        result[idx] = val
    return result

def replace_params(sql, params):
    for idx in sorted(params.keys(), reverse=True):
        sql = sql.replace('$' + str(idx), params[idx])
    return sql

def display_width(s):
    w = 0
    for c in s:
        ea = unicodedata.east_asian_width(c)
        w += 2 if ea in ('W', 'F', 'A') else 1
    return w

def print_sql_text(db_name, user_name, sql_raw, params):
    user_name  = normalize_user(user_name)
    sql_final  = replace_params(sql_raw, params) if params else sql_raw
    formatted  = format_sql(sql_final)

    title = f'sqltext(database: {db_name}  user: {user_name})'
    sep   = '=' * display_width(title)
    print(sep)
    print(title)
    print(sep)
    print(formatted)
    sys.exit(0)

uid_esc          = re.escape(unique_id)
duration_val_re  = re.compile(r'duration:\s+([\d.]+)\s+ms',  re.IGNORECASE)
queryid_re       = re.compile(r'\bqueryid\s+(\d+)',           re.IGNORECASE)

format1_re = re.compile(
    r'\bunique\s+id\s+' + uid_esc +
    r'\s+(?:bind|execute)\s+\S+:\s*(.+)$',
    re.IGNORECASE
)
format2_re = re.compile(
    r'(?:LOG|INFO):\s+(?:execute|bind)\s+\S+\s+unique\s+id\s+' + uid_esc +
    r'\s*:\s*(.+)$',
    re.IGNORECASE
)
format3_re = re.compile(
    r'(?:LOG|INFO):\s+duration:\s+([\d.]+)\s+ms'
    r'(?:\s+queryid\s+(\d+))?'
    r'.*?\bunique\s+id\s+' + uid_esc +
    r'\s+execute\s+\S+:\s*(.+)$',
    re.IGNORECASE
)
inline_statement_re = re.compile(
    r'(?:LOG|INFO):\s+duration:\s+([\d.]+)\s+ms'
    r'(?:\s+queryid\s+(\d+))?'
    r'.*?\bunique\s+id\s+' + uid_esc +
    r'\s+statement:\s+(.+)$',
    re.IGNORECASE
)
duration_only_re = re.compile(
    r'(?:LOG|INFO):\s+duration:.*?\bunique\s+id\s+' + uid_esc + r'\s*$',
    re.IGNORECASE
)
statement_re = re.compile(r'(?:LOG|INFO):\s+statement:\s+(.+)$', re.IGNORECASE)
detail_re    = re.compile(r'DETAIL:\s+parameters:\s+(.+)$',       re.IGNORECASE)

for logfile in logfiles:
    try:
        fh = open(logfile, 'rb')
    except Exception:
        continue

    with fh:
        lines = [l.decode('latin-1').rstrip('\r\n') for l in fh]

    n = len(lines)

    for i, line in enumerate(lines):
        if unique_id not in line:
            continue

        def collect_sql_and_params(start_idx, sql_body):
            cont = []
            detail_text = None
            j = start_idx
            while j < n:
                ln = lines[j]
                dp = detail_re.search(ln)
                if dp:
                    detail_text = dp.group(1)
                    j += 1
                    while j < n and not header_re.match(lines[j]):
                        if not detail_re.search(lines[j]):
                            detail_text += lines[j]
                        j += 1
                    break
                if header_re.match(ln):
                    break
                cont.append(ln.strip())
                j += 1
            full_sql = ' '.join([sql_body] + [c for c in cont if c])
            params = parse_params(detail_text) if detail_text else None
            return full_sql, params

        m3 = format3_re.search(line)
        if m3:
            db_name, user_name, _ = extract_meta(line)
            sql_body = m3.group(3).strip()
            full_sql, params = collect_sql_and_params(i + 1, sql_body)
            print_sql_text(db_name, user_name, full_sql, params)

        m_inline = inline_statement_re.search(line) if not m3 else None
        if m_inline:
            db_name, user_name, _ = extract_meta(line)
            sql_body = m_inline.group(3).strip()
            full_sql, _ = collect_sql_and_params(i + 1, sql_body)
            print_sql_text(db_name, user_name, full_sql, None)

        m1 = format1_re.search(line) if not (m3 or m_inline) else None
        m2 = format2_re.search(line) if (not m1 and not m3 and not m_inline) else None
        m_exec = m1 or m2

        if m_exec:
            db_name, user_name, _ = extract_meta(line)
            sql_body = m_exec.group(1).strip()
            full_sql, params = collect_sql_and_params(i + 1, sql_body)
            print_sql_text(db_name, user_name, full_sql, params)

        elif duration_only_re.search(line) and not (m3 or m_inline):
            db_name, user_name, pid = extract_meta(line)
            full_sql = None
            for j in range(i - 1, max(i - 10000, -1), -1):
                prev = lines[j]
                if pid:
                    _, _, prev_pid = extract_meta(prev)
                    if prev_pid and prev_pid != pid:
                        continue
                sm = statement_re.search(prev)
                if sm:
                    sql_head = sm.group(1).strip()
                    cont = []
                    for k in range(j + 1, i):
                        if header_re.match(lines[k]):
                            break
                        cont.append(lines[k].strip())
                    full_sql = ' '.join([sql_head] + cont)
                    break
            if full_sql:
                print_sql_text(db_name, user_name, full_sql, None)

print(f"not found unique_id: {unique_id}", file=sys.stderr)
sys.exit(1)
PYEOF

    local py_exit=$?
    if [[ $py_exit -ne 0 ]]; then
        echo "Error: failed to parse log for unique_id=${unique_id}" >&2
        return 1
    fi
}
