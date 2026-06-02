#!/bin/bash
# Command: sqlhc - SQL health check

sqlhc_help() {
    echo "Options for sqlhc:"
    echo "  Usage: [-o] [-s <seconds>] <unique_id>"
    echo "  Options:"
    echo "    -o: write output "
    echo "    -s: duration threshold in seconds (default 300), use EXPLAIN if duration >= threshold"
    echo "    -h, --help: show this help message"
    echo ""
}
run_sqlhc() {
local output_to_file=0
    local duration_threshold_sec=300
    local unique_id=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o)
                output_to_file=1
                shift
                ;;
            -s)
                duration_threshold_sec="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Unknown option: $1" >&2
                return 1
                ;;
            *)
                if [[ -z "$unique_id" ]]; then
                    unique_id="$1"
                    shift
                else
                    echo "Error: extra argument $1" >&2
                    return 1
                fi
                ;;
        esac
    done
    
    if [[ -z "$unique_id" ]]; then
        echo "Error: unique_id required" >&2
        return 1
    fi
    
    local log_file=""
    if [[ $output_to_file -eq 1 ]]; then
        log_file="/tmp/vb_tool_sqlhc_${unique_id}_$(date +%Y%m%d_%H%M%S).txt"
        exec 3>&2
        exec > "$log_file" 2>&1
		echo "SQLHC ... Output saved to: $log_file" > /dev/tty
    fi

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

    local py_result
    py_result=$(SQLHC_LOGFILES="$matched_logfiles" python3 - "$unique_id" << 'PYEOF'
import sys
import re
import unicodedata
import subprocess
import os
import json

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

_SQL_KW = {
    'select', 'from', 'where', 'join', 'inner', 'left', 'right', 'full',
    'outer', 'cross', 'natural', 'on', 'and', 'or', 'not', 'in', 'exists',
    'between', 'like', 'is', 'null', 'as', 'by', 'group', 'order', 'having',
    'union', 'all', 'distinct', 'case', 'when', 'then', 'else', 'end',
    'insert', 'into', 'update', 'set', 'delete', 'merge', 'using', 'matched',
    'create', 'alter', 'drop', 'table', 'view', 'index', 'with', 'recursive',
    'limit', 'offset', 'fetch', 'next', 'rows', 'only', 'row', 'partition',
    'over', 'window', 'filter', 'within', 'lateral', 'values', 'returning',
    'truncate', 'begin', 'commit', 'rollback', 'savepoint', 'grant', 'revoke',
    'pivot', 'unpivot', 'connect', 'start', 'nocycle', 'prior', 'level',
    'rownum', 'rowid', 'dual', 'if', 'else', 'do', 'loop', 'while', 'for',
    'exception', 'raise', 'declare', 'procedure', 'function', 'trigger',
    'top', 'percent', 'ties', 'nulls', 'first', 'last', 'asc', 'desc',
    'primary', 'foreign', 'key', 'references', 'unique', 'check', 'default',
    'constraint', 'index', 'replace', 'ignore', 'explain', 'analyze',
    'intersect', 'except', 'minus', 'tablesample', 'sample',
}


def normalize_user(u):
    return u.strip().lower()


def extract_tables(sql_text, default_user):
    seen = {}

    def strip_literals(s):
        out = []
        i = 0
        while i < len(s):
            if s[i] == "'":
                out.append("''")
                i += 1
                while i < len(s):
                    if s[i] == "'" and i + 1 < len(s) and s[i + 1] == "'":
                        i += 2
                    elif s[i] == "'":
                        i += 1
                        break
                    else:
                        i += 1
            elif s[i] == '"':
                out.append(s[i])
                i += 1
                while i < len(s) and s[i] != '"':
                    out.append(s[i])
                    i += 1
                if i < len(s):
                    out.append(s[i])
                    i += 1
            elif s[i] == '-' and i + 1 < len(s) and s[i + 1] == '-':
                while i < len(s) and s[i] != '\n':
                    i += 1
                out.append(' ')
            elif s[i] == '/' and i + 1 < len(s) and s[i + 1] == '*':
                i += 2
                while i < len(s) - 1 and not (s[i] == '*' and s[i + 1] == '/'):
                    i += 1
                i += 2
                out.append(' ')
            else:
                out.append(s[i])
                i += 1
        return ''.join(out)

    clean = strip_literals(sql_text)
    tokens = re.findall(
        r'"[^"]*"'
        r'|[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*'
        r'|[(),;]',
        clean
    )
    n = len(tokens)

    def is_kw(tok):
        return tok.lstrip('"').rstrip('"').lower() in _SQL_KW

    def add_table(raw):
        raw = raw.strip('"').lower()
        if raw in _SQL_KW:
            return
        parts = raw.split('.')
        if len(parts) == 1:
            owner = normalize_user(default_user)
            tname = parts[0]
        elif len(parts) == 2:
            owner, tname = parts
        else:
            owner, tname = parts[-2], parts[-1]
        if tname and tname not in _SQL_KW:
            seen[(owner, tname)] = True

    def skip_subquery(pos):
        depth = 1
        pos += 1
        while pos < n and depth > 0:
            if tokens[pos] == '(':
                depth += 1
            elif tokens[pos] == ')':
                depth -= 1
            pos += 1
        return pos

    def skip_alias(pos):
        if pos >= n:
            return pos
        if tokens[pos].upper() == 'AS':
            pos += 1
        if pos < n and tokens[pos] not in (',', '(', ')', ';') and not is_kw(tokens[pos]):
            pos += 1
        return pos

    # CTE 收集：WITH name AS ( 严格三段匹配，且前一token不能是 START
    cte_names = set()

    def collect_ctes():
        i = 0
        while i < n:
            if tokens[i].upper() == 'WITH':
                prev = tokens[i - 1].upper() if i > 0 else ''
                if prev == 'START':   # Oracle START WITH，不是CTE
                    i += 1
                    continue
                i += 1
                while i < n:
                    if tokens[i].upper() == 'RECURSIVE':
                        i += 1
                        continue
                    if is_kw(tokens[i]) or tokens[i] in ('(', ')', ',', ';'):
                        break
                    cte_name = tokens[i].lower().strip('"')
                    i += 1
                    if i >= n or tokens[i].upper() != 'AS':
                        break
                    i += 1
                    if i >= n or tokens[i] != '(':
                        break
                    cte_names.add(cte_name)
                    i = skip_subquery(i)
                    if i < n and tokens[i] == ',':
                        i += 1
                        continue
                    break
            i += 1

    collect_ctes()

    def add_table_checked(raw):
        name = raw.strip('"').lower().split('.')[-1]
        if name not in cte_names:
            add_table(raw)

    FROM_TRIGGERS = {
        'FROM', 'JOIN', 'INNER', 'LEFT', 'RIGHT', 'FULL',
        'CROSS', 'NATURAL', 'STRAIGHT_JOIN',
    }
    JOIN_NOISE = {'JOIN', 'OUTER', 'SEMI', 'ANTI', 'INTO', 'BY'}

    i = 0
    while i < n:
        tok_up = tokens[i].upper()

        if tok_up == 'UPDATE':
            j = i + 1
            if j < n and not is_kw(tokens[j]) and tokens[j] not in ('(', ')'):
                add_table_checked(tokens[j])
                j = skip_alias(j + 1)
            i = j if j > i else i + 1
            continue

        if tok_up in ('INSERT', 'MERGE'):
            j = i + 1
            if j < n and tokens[j].upper() == 'INTO':
                j += 1
            if j < n and not is_kw(tokens[j]) and tokens[j] not in ('(', ')'):
                add_table_checked(tokens[j])
                j = skip_alias(j + 1)
            i = j if j > i else i + 1
            continue

        if tok_up == 'DELETE':
            j = i + 1
            if j < n and tokens[j].upper() == 'FROM':
                j += 1
            if j < n and not is_kw(tokens[j]) and tokens[j] not in ('(', ')'):
                add_table_checked(tokens[j])
                j = skip_alias(j + 1)
            i = j if j > i else i + 1
            continue

        if tok_up in FROM_TRIGGERS:
            j = i + 1
            while j < n and tokens[j].upper() in JOIN_NOISE:
                j += 1
            while j < n:
                t = tokens[j]
                t_up = t.upper()
                if t == '(':
                    # 子查询：不跳过，让主循环自然扫描括号内部
                    i = j
                    break
                if t in (')', ';'):
                    i = j
                    break
                if t_up in _SQL_KW and t_up not in ('AS',):
                    i = j
                    break
                add_table_checked(t)
                j = skip_alias(j + 1)
                if j < n and tokens[j] == ',':
                    j += 1
                    continue
                i = j
                break
            else:
                i = j
            continue

        if tok_up == 'USING':
            j = i + 1
            if j < n and tokens[j] == '(':
                j = skip_subquery(j)
                j = skip_alias(j)
            elif j < n and not is_kw(tokens[j]):
                add_table_checked(tokens[j])
                j = skip_alias(j + 1)
            i = j if j > i else i + 1
            continue

        i += 1

    return [(o, t) for (o, t) in seen.keys() if t not in cte_names]

def display_width(s):
    w = 0
    for c in s:
        ea = unicodedata.east_asian_width(c)
        w += 2 if ea in ('W', 'F', 'A') else 1
    return w

def print_result(db_name, user_name, sql_raw, params, duration_ms, queryid=''):
    user_name  = normalize_user(user_name)
    sql_final  = replace_params(sql_raw, params) if params else sql_raw
    formatted  = format_sql(sql_final)
    tables     = extract_tables(sql_final, user_name)
    tables_str = '(' + ','.join(f"('{o}','{t}')" for o, t in tables) + ')'

    title = f'sqltext(database: {db_name}  user: {user_name})'
    sep   = '=' * display_width(title)
    print(sep)
    print(title)
    print(sep)
    print(formatted)

    meta = {
        'db':          db_name,
        'user':        user_name,
        'duration_ms': duration_ms,
        'tables':      [list(t) for t in tables],
        'sql':         sql_final,
        'queryid':     queryid,
    }
    print(f"__META__:{json.dumps(meta, ensure_ascii=False)}")
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
            duration_ms = float(m3.group(1))
            queryid     = m3.group(2) or ''
            sql_body    = m3.group(3).strip()
            full_sql, params = collect_sql_and_params(i + 1, sql_body)
            print_result(db_name, user_name, full_sql, params, duration_ms, queryid)

        m_inline = inline_statement_re.search(line) if not m3 else None
        if m_inline:
            db_name, user_name, _ = extract_meta(line)
            duration_ms = float(m_inline.group(1))
            queryid     = m_inline.group(2) or ''
            sql_body    = m_inline.group(3).strip()
            full_sql, _ = collect_sql_and_params(i + 1, sql_body)
            print_result(db_name, user_name, full_sql, None, duration_ms, queryid)

        m1 = format1_re.search(line) if not (m3 or m_inline) else None
        m2 = format2_re.search(line) if (not m1 and not m3 and not m_inline) else None
        m_exec = m1 or m2

        if m_exec:
            db_name, user_name, _ = extract_meta(line)
            sql_body = m_exec.group(1).strip()

            dm = duration_val_re.search(line)
            duration_ms = float(dm.group(1)) if dm else None

            qm = queryid_re.search(line)
            queryid = qm.group(1) if qm else ''

            full_sql, params = collect_sql_and_params(i + 1, sql_body)
            print_result(db_name, user_name, full_sql, params, duration_ms, queryid)

        elif duration_only_re.search(line) and not (m3 or m_inline):
            db_name, user_name, pid = extract_meta(line)

            dm = duration_val_re.search(line)
            duration_ms = float(dm.group(1)) if dm else None

            qm = queryid_re.search(line)
            queryid = qm.group(1) if qm else ''

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
                print_result(db_name, user_name, full_sql, None, duration_ms, queryid)

print(f"not found unique_id: {unique_id}", file=sys.stderr)
sys.exit(1)
PYEOF
    )

    local py_exit=$?
    if [[ $py_exit -ne 0 ]]; then
        echo "Error: failed to parse log for unique_id=${unique_id}" >&2
        return 1
    fi

    echo "$py_result" | grep -v '^__META__:'

    local meta_json
    meta_json=$(echo "$py_result" | grep '^__META__:' | sed 's/^__META__://')

    if [[ -z "$meta_json" ]]; then
        echo "Error: no metadata from parser" >&2
        return 1
    fi

    local db_name user_name duration_ms sql_text
    db_name=$(    echo "$meta_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['db'])")
    user_name=$(  echo "$meta_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['user'])")
    duration_ms=$(echo "$meta_json" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d['duration_ms']; print(v if v is not None else -1)")
    sql_text=$(   echo "$meta_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sql'])")

    local explain_type duration_s sql_first_word is_dml_ddl
    duration_s=$(echo "$duration_ms" | awk '{printf "%.3f", $1/1000}')
    sql_first_word=$(echo "$sql_text" | awk '{print toupper($1)}')
	
	sql_exec="$sql_text"
    while true; do
        _fw=$(echo "$sql_exec" | awk '{print toupper($1)}')
        [[ "$_fw" == "EXPLAIN" ]] || break
        sql_exec=$(echo "$sql_exec" | sed 's/^[[:space:]]*[Ee][Xx][Pp][Ll][Aa][Ii][Nn][[:space:]]*//')
        _nw=$(echo "$sql_exec" | awk '{print toupper($1)}')
        if [[ "$_nw" == "ANALYZE" || "$_nw" == "PERFORMANCE" ]]; then
            sql_exec=$(echo "$sql_exec" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')
        fi
    done

    is_dml_ddl=0
    case "$sql_first_word" in
        INSERT|DELETE|UPDATE|DROP|CREATE|MERGE|UPSERT)
            is_dml_ddl=1
            ;;
    esac

    if [[ $is_dml_ddl -eq 1 ]]; then
        explain_type="EXPLAIN"
        echo ""
        echo "SQL type is ${sql_first_word}, EXPLAIN PERFORMANCE not supported, using EXPLAIN ..."
    elif awk "BEGIN {exit !($duration_ms >= 0 && $duration_ms < $((duration_threshold_sec * 1000)))}"; then
        explain_type="EXPLAIN PERFORMANCE"
        echo ""
        echo "duration: ${duration_s}s < ${duration_threshold_sec}s, using EXPLAIN PERFORMANCE ..."
    else
        explain_type="EXPLAIN"
        echo ""
        echo "duration: ${duration_s}s >= ${duration_threshold_sec}s, using EXPLAIN ..."
    fi
    echo ""

    psql -d "$db_name" -X -q << PSQLEOF
SET search_path = ${user_name}, public;
\echo '================'
\echo '   query plan   '
\echo '================'
${explain_type}
${sql_exec}
;
PSQLEOF

    local tables_in_clause
    tables_in_clause=$(echo "$meta_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
pairs = [\"('\" + o + \"','\" + t + \"')\" for o, t in d['tables']]
print(','.join(pairs))
")

    if [[ -z "$tables_in_clause" ]]; then
        echo "Warning: no tables found, skip statistics query" >&2
        return 0
    fi

    echo ""
    psql -d "$db_name" -X << PSQLEOF
\pset footer off
\echo '================'
\echo 'table statistics'
\echo '================'
SELECT n.nspname AS "owner"
        ,c.relname AS "tab_name"
        ,CASE c.relpersistence
                WHEN 'p' THEN 'perm'
                WHEN 't' THEN 'temp'
                WHEN 'u' THEN 'unlog'
                END AS "tabtype"
        ,(select CASE p.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end from pg_partition p where p.parentid=c.oid limit 1)
         ||(CASE WHEN p2.cols is not null then '('||p2.cols||')' else '' end)
         ||(case when (select CASE p1.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end from pg_partition p,pg_partition p1 where p.parentid=c.oid and p1.parentid=p.oid limit 1) is not null
         then '-'||(select CASE p1.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end from pg_partition p,pg_partition p1 where p.parentid=c.oid and p1.parentid=p.oid limit 1)||'('||p1.cols||')'
         else '' end) parttype
        ,c.relpages
        ,c.reltuples
        ,c.relallvisible allvisible
        ,pg_catalog.pg_size_pretty(pg_catalog.pg_table_size(c.oid)) AS "size"
        ,replace(replace(replace(c.reloptions::text,'orientation','ori'),'compression','comp'),'fillfactor','fill') as options
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN (
    select lower(schema_name) schema_name,lower(name) as name,
           lower(string_agg(column_name,',' order by column_position)) cols
    from dba_subpart_key_columns
    where object_type='TABLE'
    group by schema_name,name
) p1 ON c.relname=p1.name and p1.schema_name=n.nspname
LEFT JOIN (
    select lower(schema_name) schema_name,lower(name) as name,
           lower(string_agg(column_name,',' order by column_position)) cols
    from dba_part_key_columns
    where object_type='TABLE'
    group by schema_name,name
) p2 ON c.relname=p2.name and p2.schema_name=n.nspname
WHERE c.relkind IN ('r','p','v','m','S','f','')
        AND n.nspname <> 'pg_catalog'
        AND n.nspname !~ '^pg_toast'
        AND n.nspname <> 'information_schema'
        AND ((n.nspname, c.relname) IN (${tables_in_clause}) or (n.nspname, c.relname) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})));

\echo '                           '
select schemaname,relname,n_tup_ins,n_tup_upd,n_tup_del,n_tup_hot_upd,n_live_tup,n_dead_tup,
       to_char(last_vacuum,'yyyy-mm-dd hh24:mi:ss') last_vacuum,
       to_char(last_analyze,'yyyy-mm-dd hh24:mi:ss') last_analyze
from pg_stat_all_tables
where ((schemaname, relname) IN (${tables_in_clause}) or (schemaname, relname) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})));

\echo '================'
\echo 'index statistics'
\echo '================'
SELECT n.nspname AS "ind_owner"
        ,c2.relname AS "tab_name"
        ,c.relname AS "ind_name"
        ,replace(am.amname||' '||decode(i.indisunique,'t','unique')||' '
            ||CASE WHEN c.relkind = 'i' and pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) ~ '\)\s*LOCAL' then 'local'
                   WHEN c.relkind = 'I' then 'global'
               ELSE NULL END,'  ',' ') ind_type
        ,decode(i.indisusable,'t','usable','unusable') status
        ,lower(REGEXP_REPLACE(TRIM(BOTH FROM SUBSTRING(pg_catalog.pg_get_indexdef(i.indexrelid, 0, true)
            FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)')),
            '(,|^)\s*([^,]+?)(?<!DESC)(?<!ASC)\b\s*(DESC|ASC)\b','\1\2','gi')) col_list
        ,c.relpages
        ,c.reltuples
        ,pg_catalog.pg_size_pretty(pg_catalog.pg_table_size(c.oid)) AS "Size"
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
LEFT JOIN pg_catalog.pg_class c2 ON i.indrelid = c2.oid
LEFT JOIN pg_catalog.pg_namespace n1 ON n1.oid = c2.relnamespace
WHERE c.relkind IN ('i','I','')
        AND n.nspname <> 'pg_catalog'
        AND n.nspname !~ '^pg_toast'
        AND n.nspname <> 'information_schema'
        AND ((n1.nspname, c2.relname) IN (${tables_in_clause}) or (n1.nspname, c2.relname) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})))
        order by 1,2;

\echo '                                  '
select schemaname,relname tab_name,indexrelname index_name,idx_scan,idx_tup_read,idx_tup_fetch
from pg_stat_all_indexes
where ((schemaname, relname) IN (${tables_in_clause}) or (schemaname, relname) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})))
order by 1,2;

\echo '================='
\echo 'column statistics'
\echo '================='
SELECT
    relname AS tab_name,
    t.attname AS col_name,
    CASE
        WHEN t.type LIKE '%without time zone%' THEN replace(t.type, ' without time zone', '')
        WHEN t.type LIKE '%with time zone%' THEN replace(replace(t.type, ' with time zone', ''), 'timestamp', 'timestamptz')
        ELSE t.type
    END AS type,
    decode(attstorage, 'p', 'plain', 'e', 'external', 'm', 'main', 'x', 'extended') AS attstorage,
    decode(attnotnull, 'true', 'not null', round(null_frac, 5)) AS nullfreq,
    avg_width,
    round(n_distinct, 5) AS n_dist,
    round(correlation, 5) AS corr,
    t1.top3_freqs
FROM (
    SELECT
        c.relname,
        a.attname,
        a.attnum,
        pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
        a.attnotnull,
        b.null_frac,
        b.avg_width,
        b.n_distinct,
        b.correlation,
        a.attstorage,
        d.nspname
    FROM pg_catalog.pg_attribute a
    JOIN pg_class c ON a.attrelid = c.oid
    JOIN pg_catalog.pg_namespace d ON c.relnamespace = d.oid
    LEFT JOIN pg_catalog.pg_stats b ON a.attname = b.attname
        AND c.relname = b.tablename
        AND b.schemaname = d.nspname
    WHERE a.attrelid = c.oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND (d.nspname, c.relname) IN (${tables_in_clause})
) t
LEFT JOIN (
    SELECT
        tablename,
        schemaname,
        attname,
        CONCAT(
            COALESCE(split_part(val_string, '|', 1), '') ||
            CASE WHEN split_part(val_string, '|', 1)  is not null  and split_part(val_string, '|', 1) is distinct from ''
                 THEN '(' || COALESCE(split_part(freq_string, '|', 1)::NUMERIC::TEXT, '0') || ')'
                 ELSE ''
            END,
            CASE WHEN split_part(val_string, '|', 2)  is not null  and split_part(val_string, '|', 2) is distinct from ''
                 THEN CHR(10) || split_part(val_string, '|', 2) ||
                      '(' || COALESCE(split_part(freq_string, '|', 2)::NUMERIC::TEXT, '0') || ')'
                 ELSE ''
            END,
            CASE WHEN split_part(val_string, '|', 3)  is not null  and split_part(val_string, '|', 3) is distinct from ''
                 THEN CHR(10) || split_part(val_string, '|', 3) ||
                      '(' || COALESCE(split_part(freq_string, '|', 3)::NUMERIC::TEXT, '0') || ')'
                 ELSE ''
            END
        ) AS top3_freqs
    FROM (
        SELECT
            tablename,
            schemaname,
            attname,
            array_to_string(most_common_vals, '|') AS val_string,
            array_to_string(most_common_freqs, '|') AS freq_string
        FROM pg_stats
        WHERE ((schemaname, tablename) IN (${tables_in_clause}) or (schemaname, tablename) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})))
            AND most_common_freqs IS NOT NULL
    ) t2
) t1 ON t.attname = t1.attname
    AND t.relname = t1.tablename
    AND t.nspname = t1.schemaname
ORDER BY t.nspname, t.relname, t.attnum;

\echo '===================='
\echo 'partition statistics'
\echo '===================='
select n.nspname schema_name,c.relname tab_name,partitionno partno,p.relname part_name,
       CASE p.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end parttype,
       cols partkey,p.relpages,p.reltuples,
       pg_size_pretty(pg_partition_size(p.parentid,p.oid)) as size,boundaries
from pg_partition p
    ,pg_class c
    ,(select lower(schema_name) schema_name,lower(name) as name,
             lower(string_agg(column_name,',' order by column_position)) cols
      from dba_part_key_columns
      where object_type='TABLE'
      group by schema_name,name) p1
    ,pg_namespace n
where p.parttype in ('p')
  and c.oid=p.parentid
  and p.subpartitionno is null
  and p1.name=c.relname
  and n.oid=c.relnamespace
  and p1.schema_name=n.nspname
  and ((n.nspname, c.relname) IN (${tables_in_clause}) or (n.nspname, c.relname) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})))
order by 1,2,3;

\echo '======================='
\echo 'subpartition statistics'
\echo '======================='
select c.relname tab_name,p.relname part_name,ps.relname subpart_name,
       CASE p.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end||'('||p1.cols||')-'
       ||CASE ps.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end||'('||p2.cols||')' part_type,
       ps.relpages,ps.reltuples,
       pg_size_pretty(pg_partition_size(ps.parentid,ps.oid)) as size,
       p.boundaries partbound,ps.boundaries subpartbound
from pg_partition p
    ,pg_partition ps
    ,pg_class c
    ,pg_namespace n
    ,(select lower(schema_name) schema_name,lower(name) as name,
             lower(string_agg(column_name,',' order by column_position)) cols
      from dba_part_key_columns
      where object_type='TABLE' group by schema_name,name) p1
    ,(select lower(schema_name) schema_name,lower(name) as name,
             lower(string_agg(column_name,',' order by column_position)) cols
      from dba_subpart_key_columns
      where object_type='TABLE' group by schema_name,name) p2
where (p.parttype='s' or (p.parttype='p' and p.subpartitionno is not null))
  and c.oid=p.parentid
  and c.relname=p1.name
  and n.oid=c.relnamespace
  and p1.schema_name=n.nspname
  and ps.parentid=p.oid
  and ((n.nspname, c.relname) IN (${tables_in_clause}) or (n.nspname, c.relname) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})))
order by 1,2,3;

\echo '==================='
\echo 'extended statistics'
\echo '==================='
SELECT a.schemaname as owner
        ,a.tablename tab_name
        ,a.attname
        ,null_frac
        ,avg_width
        ,n_distinct
        ,n_dndistinct
        ,top3_freqs
FROM (
        SELECT schemaname,tablename,attname,null_frac,avg_width,n_distinct,n_dndistinct
        FROM pg_catalog.pg_ext_stats
        WHERE (schemaname, tablename) IN (${tables_in_clause})
        ) a
LEFT JOIN (
        SELECT tablename,schemaname,attname,
               string_agg(top3_freq::TEXT,',' ORDER BY top3_freq DESC) top3_freqs
        FROM (
                SELECT tablename,schemaname,attname,
                       round(UNNEST(most_common_freqs)::DECIMAL,4) top3_freq,
                       row_number() OVER (PARTITION BY tablename,attname
                           ORDER BY round(UNNEST(most_common_freqs)::DECIMAL,4) DESC) rn
                FROM pg_catalog.pg_ext_stats
                WHERE ((schemaname, tablename) IN (${tables_in_clause}) or (schemaname, tablename) IN (select table_schema,table_name from information_schema.view_table_usage where (view_schema,view_name) IN (${tables_in_clause})))
                ) d
        WHERE rn <= 3
        GROUP BY attname,tablename,schemaname
        ) b ON a.attname=b.attname and a.tablename=b.tablename and a.schemaname=b.schemaname;
PSQLEOF

    psql -d postgres -X -v "unique_sql_id=${unique_id}" << 'PSQLEOF'
\pset footer off
\echo '======================'
\echo 'sqltext from statement'
\echo '======================'
\echo '                          '
SELECT query FROM dbe_perf.statement WHERE unique_sql_id=:'unique_sql_id';
\echo '=============================='
\echo 'sqlplan from statement_history'
\echo '=============================='
\echo '                          '
SELECT to_char(max(start_time),'yyyy-mm-dd hh24:mi:ss') last_exec_time,
       ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
) plan_hash_value,
       max(query_plan) query_plan
FROM dbe_perf.statement_history
WHERE unique_query_id=:'unique_sql_id'
group by ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
) order by 1;
\echo '======================'
\echo 'sqlstat from statement'
\echo '======================'
\echo '                          '
SELECT user_name,n_calls,
round(db_time/1e3/n_calls,1) avg_db_ms,
round(execution_time/1e3/n_calls,1) avg_et_ms,
round(cpu_time/1e3/n_calls,1) avg_cpu_ms,
round(data_io_time/1e3/n_calls,1) avg_io_ms,
round((parse_time+plan_time+rewrite_time)/1e3/n_calls,1) avg_plan_ms,
round(pl_execution_time/1e3/n_calls,1) avg_plsql_ms,
round(sort_time/1e3/n_calls,1) a_sort_ms,
round(hash_time/1e3/n_calls,1) a_hash_ms,
round(n_blocks_fetched/n_calls,1) avg_cr,
round((n_blocks_fetched-n_blocks_hit)/n_calls,1) avg_pr,
round((n_returned_rows+n_tuples_inserted+n_tuples_updated+n_tuples_deleted)/n_calls,1) avg_rows
FROM dbe_perf.statement WHERE unique_sql_id=:'unique_sql_id';
\echo '====================================='
\echo 'slow statement_history from sysdate-3'
\echo '====================================='
\echo '                                   '
select user_name,ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
) plan_hash_value,count(*) execs,
round(avg(db_time)/1e3,1) avg_db_ms,
round(avg(execution_time)/1e3,1) avg_et_ms,
round(avg(cpu_time)/1e3,1) avg_cpu_ms,
round(avg(data_io_time)/1e3,1) avg_io_ms,
round(avg(lock_wait_time)/1e3,1) lock_wait_ms,
round(avg(lwlock_wait_time)/1e3,1) lwlock_wait_ms,
round(avg(n_blocks_fetched),1) avg_cr,
round(avg(n_blocks_fetched-n_blocks_hit),1) avg_pr,
round(avg(n_returned_rows+n_tuples_inserted+n_tuples_updated+n_tuples_deleted),1) avg_rows
from dbe_perf.statement_history
where unique_query_id=:'unique_sql_id' and is_slow_sql='t' and start_time>now()-3
group by ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
),user_name;
\echo '=============================='
\echo 'sqlstat history from sysdate-3'
\echo '=============================='
\echo '                              '
select snap_user_name uname,snap_time,n_calls,avg_db_ms,avg_et_ms,avg_cpu_ms,avg_io_ms,avg_cr,avg_pr,avg_rows from
(select snap_user_name,snap_time,n_calls,
round(db_time/1e3/n_calls,1) avg_db_ms,
round(execution_time/1e3/n_calls,1) avg_et_ms,
round(cpu_time/1e3/n_calls,1) avg_cpu_ms,
round(data_io_time/1e3/n_calls,1) avg_io_ms,
round(n_blocks_fetched/n_calls,1) avg_cr,
round((n_blocks_fetched-n_blocks_hit)/n_calls,1) avg_pr,
round((n_returned_rows+n_insert_rows+n_update_rows+n_delete_rows)/n_calls,1) avg_rows
from
(SELECT snap_user_name,to_char(start_ts,'yyyy-mm-dd hh24:mi:ss') snap_time,
    snap_n_calls-coalesce(lag(snap_n_calls)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_calls,
    snap_db_time-coalesce(lag(snap_db_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) db_time,
    snap_execution_time-coalesce(lag(snap_execution_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) execution_time,
    snap_cpu_time-coalesce(lag(snap_cpu_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) cpu_time,
    snap_data_io_time-coalesce(lag(snap_data_io_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) data_io_time,
    snap_n_blocks_fetched-coalesce(lag(snap_n_blocks_fetched)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_blocks_fetched,
    snap_n_blocks_hit-coalesce(lag(snap_n_blocks_hit)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_blocks_hit,
    snap_n_returned_rows-coalesce(lag(snap_n_returned_rows)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_returned_rows,
    snap_n_tuples_inserted-coalesce(lag(snap_n_tuples_inserted)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_insert_rows,
    snap_n_tuples_updated-coalesce(lag(snap_n_tuples_updated)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_update_rows,
    snap_n_tuples_deleted-coalesce(lag(snap_n_tuples_deleted)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_delete_rows
    FROM snapshot.snap_summary_statement a,snapshot.snapshot b
    WHERE snap_unique_sql_id=:'unique_sql_id'
      and a.snapshot_id=b.snapshot_id
      and start_ts>now()-3) where n_calls>0 order by 2) where snap_time<(select max(start_ts) from snapshot.snapshot);
\echo '=========================='
\echo '        opt params        '
\echo '=========================='
select vb_version();

SELECT name,
       decode(unit, '8kB', setting*8||'kB', setting||COALESCE(unit,' ')) setting,
       context,
       short_desc
FROM pg_settings
WHERE (
    lower(short_desc) LIKE '%plan%'
    OR lower(short_desc) LIKE '%rewrite%'
    OR lower(short_desc) LIKE '%expr%'
    OR lower(short_desc) LIKE '%from-list%'
    OR name LIKE 'geqo%'
    OR name LIKE '%cost%'
    OR short_desc LIKE '%partition%'
    OR short_desc LIKE '%elimination%'
    OR name IN ('work_mem', 'shared_buffers')   
    OR category LIKE 'Query Tuning%'
    OR short_desc LIKE '%targetlist%'
)
AND name NOT IN ('num_internal_lock_partitions', 'partition_lock_upgrade_timeout', 'log_max_size')
ORDER BY CASE WHEN short_desc LIKE '%planner%' THEN 'planner' ELSE short_desc END;

PSQLEOF
}


