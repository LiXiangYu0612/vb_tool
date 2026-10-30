# vb_tool

VastBase 数据库运维工具集，单文件 Bash 实现。

## 安装

```bash
git clone https://github.com/LiXiangYu0612/vb_tool.git
cd vb_tool
chmod +x vb_tool
```

将 `vb_tool` 加入 PATH 即可直接使用：

```bash
export PATH=/path/to/vb_tool:$PATH
```

> `vb_tool` 即全部功能，无外部依赖文件。

## 使用方法

```bash
vb_tool <command> [options]
```

查看完整帮助：

```bash
vb_tool --help
vb_tool list
```

## 全局选项

- `-P <port>`：所有连接数据库的命令均可用，指定实例端口（仅本次调用生效，等同临时设置 `PGPORT`；支持前置、尾置、粘连 `-P5433` 三种写法）。不带 `-P` 时连接当前 `$PGPORT` 环境变量指向的实例。
- 各命令支持 `-h` / `-help` / `--help` 查看帮助。例外：`awr` 的子命令（`list/show/delete/config`）无参数即显示用法，`-h` 会被当作参数解析。

## 命令列表（节选）

| 命令 | 说明 |
|------|------|
| `as [pid]` | 显示活跃会话信息 |
| `asp <type> -b <begin> -e <end>` | 活跃会话概要分析 (cnt/event/waitchain/sql) |
| `se <event_name>` / `se -l [keyword]` | 等待事件知识库（oerr 风格）：输入事件名（支持缩写、部分匹配、带空格）回显事件全称、含义、源码级触发点、等待原因与解决方案；覆盖 417 个事件（LOCK/IO/STATUS/LWLOCK），纯离线 |
| `awr create` | 手动创建 AWR 单点快照（主库/备库均可，备库自动切换备库侧数据源） |
| `awr enable` / `awr disable` | 启停 cron 定时采样（间隔由 `awr config interval` 控制，默认 60 分钟） |
| `awr awrrpt begin <id> end <id>` | 生成两快照区间 AWR 报告 (HTML) |
| `awr awrdiff begin <a> end <b> begin <c> end <d>` | 两区间对比报告 |
| `awr awrdiff begin <x> end <y> baseline <id>` | 当前窗口 vs 基线对比（P1=基线参照，Δ=当前−基线） |
| `awr baseline begin <id> end <id>` | 登记基线：把两端点快照与窗口内的分钟采样日志复制为自包含副本（`awrs/<port>/baselines/<id>/`），不受自动清理影响；要求 begin < end 且两端同一 DB uptime |
| `awr baseline info` | 列出已登记基线（id/端点/窗口/创建时间/STATUS） |
| `awr baseline report <id>` | 生成基线窗口报告（同 awrrpt 链；默认名 `baseline_{db}_{b}_{e}.html`；SQL 文本自动回退主库共享库） |
| `awr baseline delete <id>` | 删除基线副本（主库无感知） |
| `awr topsql begin <id> end <id> [-m <dim>] [-n N]` | 屏幕输出区间 Top SQL（wdr_topsql 同款列；`-m` 可选 dbtime / cpu / io / plan / lreads / preads / memory / spill / calls / rows，默认 dbtime；`-n` 默认 10；不生成文件） |
| `awr event begin <id> end <id> [-E <event>]` | 屏幕输出 Top 等待事件（CPU 时间+事件按总等待排序前 5 行，wdr_event 风格；-E 只看指定事件，忽略大小写） |
| `awr summary begin <id> end <id>` | 屏幕输出单行负载概要（dbtime/aas/tps/iops/mbps/wal_mb/s 等 12 列，wdr_summary 风格；iops/mbps/wal 需快照含 file_iostat，老快照显示 '-'） |
| `awr tabstat begin <id> end <id> -d <db> -s <schema> -t <table>` | 屏幕输出单表区间扫描/DML 增量与存活/死元组（wdr_tabstat 风格，任意库的表均可） |
| `awr cpu begin <id> end <id>` | 屏幕输出区间**每分钟 CPU** 明细（busy/user/.../idle + r/b，awrrpt CPU per-minute detail 同源同列；需 `awr enable` 采样） |
| `awr io begin <id> end <id>` | 屏幕输出区间**每分钟每设备 IO** 明细（r/s w/s rB/s wB/s + r/w await，awrrpt Disk I/O per-minute detail 同源同列；空闲设备分钟隐藏） |
| `awr page begin <id> end <id>` | 屏幕输出区间**每分钟缺页/内存**明细（pgpgin/pgfault 等 + MemUsed/MemAvail + 水位，awrrpt Memory/Paging per-minute detail 同源同列） |
| `awr replstat begin <id> end <id>` | 屏幕输出区间**每分钟复制状态**（sent/write/flush/replay LSN + net/fsync/apply/total 字节 lag；全零健康分钟隐藏，awrrpt Replication Stat 同源同列） |
| `awr replslot begin <id> end <id>` | 屏幕输出区间**每分钟复制槽**样本（slot/type/active/restart_lsn 等，awrrpt Replication Slots 同源同列） |
| `awr replay begin <id> end <id>` | 屏幕输出区间**每分钟 WAL 回放**明细（**备库侧**：state/peer + sent/received/flush/replay LSN + 四段字节 lag + sync%/channel，awrrpt Wal Receiver 同源同列；每分钟全显不隐藏；主库无 walreceiver 显示提示） |
| `awr ltx begin <id> end <id>` | 屏幕输出区间长事务监控（每 5 分钟一行，awrrpt 同源同列） |
| `awr pagew begin <id> end <id>` | 屏幕输出区间 pagewriter 刷脏序列（每 5 分钟一行，需 `awr enable` 采样） |
| `awr sqlhist <sql_id> begin <id> end <id>` | 单条 SQL 在窗口内的逐区间执行历史 |
| `awr list [YYYY-MM-DD]` | 快照清单（snap_id 倒序，默认最新 30 条；指定日期列出全天） |
| `awr show` | 总览：运行状态 / 采样间隔 / 保留期 / 最老最新快照 |
| `awr delete until <time>` | 手动按时间清理快照 / 采样日志 / HTML 报告 |
| `awr config retention <days>` | 保留期（默认 8 天，0=永久；改小立即清理过期数据） |
| `awr config interval <min>` | 采样间隔（1-60 分钟，默认 60；enabled 状态下改完即时生效） |
| `analyze_log` / `analyze_log_v2` | 数据库日志分析（v2 输出 HTML 报告） |
| `wdr_summary` / `wdr_topsql` / `wdr_tabstat` / `wdr_event` | WDR 报告数据提取分析 |
| `osw_netstat` | 解析 OSWbb oswnetstat 归档（v8/zzz/gz/批量） |
| `collect_log` | 收集集群或单节点日志 |
| `tps` / `tabstat` / `tabsize` / `sqlstat` | 性能与对象统计 |
| `lock_details` / `lockchain` | 锁等待分析 |
| `sqlhc` | SQL 健康检查（支持 .log/.csv 及其 .gz 压缩日志） |
| `vtop` | oratop 风格实时监控：主屏显示 OS 与数据库两块，11 个子屏（`s` 会话、`l` 长事务、`a` 负载速率、`e` 等待事件、`x` WAL、`r` 复制、`m` 内存、`t` TOPSQL、`k` 锁、`g` 线程栈），跨帧增量、阈值着色、终端能力自适应；`-i` / `--once` / `--color` / `--no-color` / `--plain` |

完整命令见 `vb_tool list`。

## AWR 快照存储

默认 `~/.vb_tool/awrs/`（`VB_TOOL_HOME` 可覆盖），并按数据库端口分实例隔离：

```
~/.vb_tool/awrs/
└── <port>/                  # 按实例隔离（$PGPORT，默认 5432）
    ├── sequence             # snap_id 序列
    ├── retention            # 保留天数（默认 8，0=永久）
    ├── interval             # 采样间隔分钟（默认 60）
    ├── snap_<id>/           # 每快照: meta.json + os/ + db/*.csv
    ├── repl_<YYYYMMDD>.log  # pg_stat_replication 每分钟采样（主库侧）
    ├── slot_<YYYYMMDD>.log  # pg_replication_slots 每分钟采样（主库侧）
    ├── walrcv_<YYYYMMDD>.log # pg_stat_get_wal_receiver 每分钟采样（备库侧）
    └── os_<YYYYMMDD>.log    # OS 计数器每分钟采样（/proc，主备库都采）
```

> 快照按端口分目录存储，多实例可并行采样互不干扰；旧版扁平布局在首次运行时自动迁移。

## 依赖

- VastBase 数据库，且 PATH 中有 `psql` 客户端（工具直接调用 `psql`）
- Python 3（内嵌报告渲染等需要）
- 常用系统工具: `top`, `sar`, `iostat`, `free`, `df`, `ip`

## 版本历史

| 版本 | 日期 | 要点 |
|------|------|------|
| v2.5.18 | 2026-10-30 | awr：TCP Sockets / Conntrack 章节并入 DB Process 的 Per-minute detail 折叠表（默认收起）——LISTEN Recv-Q、TCP Total、四个常见 TCP 状态、FIN-WAIT-1/2（FW1/FW2 双数）、Conntrack Used/Limit、postmaster 数据目录 reg fd 三桶 DBFile/TempFile/XLog（live(deleted) 格式），罕见 TCP 状态出现非零才动态加列；采样器新增每分钟 dbfd 行；RX Missed 并入网卡表当列；Bond 空节标注；sqltext explain search_path 补 public 兜底 |
| v2.5.17 | 2026-10-26 | awr 对象统计对全局共享目录表去重（统一归 postgres 一行）；awr topsql 新增 plan / memory / spill 三个排序维度 |
| v2.5.16 | 2026-10-21 | pagewriter 刷脏监控：5 分钟采样、`awr pagew` 命令、报告 Pagewriter Status 节；MSSQL 兼容模式下 size 列别名报错修复 |
| v2.5.15 | 2026-10-20 | awrrpt 自动生成配对日志分析报告（`awronly` 可跳过），双产物打包；awr create 输出采集明细；兼容 G100 2.2.10 视图差异 |
| v2.5.13 | 2026-10-15 | 对象级 I/O 榜与 Top SQL 内存 / 落盘榜；Load Profile 新增 SQL calls；SQL id 可点击；内存上下文按家族归并 |
| v2.5.12 | 2026-10-11 | 产品化审查批：输出英文化、vtop 备库读数修复、日志读取改流式（大日志不再占用大量内存） |
| v2.5.11 | 2026-10-10 | 审计修复 12 项：wdr 计数器回退防护、awr 引导文案、vtop 子屏状态与临时文件清理、asp 状态过滤等 |
| v2.5.10 | 2026-10-10 | sqlstat plan_hash 算法统一；vtop topsql 与 as 对齐；vtop REPL 优先显示同步备库；sqlhc 日志搜索限定 pg_log；awr sqlhist 修复 |
| v2.5.9 | 2026-09-29 | awr list 主机名列移到末列；vtop 新增 g（线程栈）子屏 |
| v2.5.8 | 2026-09-28 | vtop 新增 11 个子屏与跨帧增量；主屏 OS 区改版；审计修复 14 处；sqlhc 反查真实 schema |
| v2.5.7 | 2026-09-20 | DB 进程 fd 分类：PGDATA 与 PGHOME 双树 + 表空间注册表；新增 TAB 命令补全安装 |
| v2.5.6 | 2026-09-20 | fd 分类改为类型与目录两层，溢出目录行恒显示；sqlhc 日志搜索增强 |
| v2.5.4 | 2026-09-17 | DB Process 节新增 Open FDs 分类与监听端口 TCP 状态；OS 统计指标项大小写统一 |
| v2.5.3 | 2026-09-17 | awr sqlhist 修复（按 sql_id 过滤、列错位）与输出格式统一 |
| v2.5.2 | 2026-09-17 | 新增 awr sqlhist；collect_log 集成 AWR 报告；sqlhc 嵌套视图展开 |
| v2.5.1 | 2026-09-17 | sqlhc 视图递归展开到基表；dmesg 上下文行与 gawk 能力守护 |
| v2.5.0 | 2026-09-17 | 新增 DB Process、OS Kernel Parameters、Kernel Messages 三节；物理读改用 fileIOStat 直计数器 |
| v2.4.9 | 2026-09-16 | 移除 Top 10 文件 I/O 四表，Load Profile 新增物理 I/O 四行；ASH 子表无条件渲染 |
| v2.4.8 | 2026-09-16 | 后台线程 CPU% 改按单线程采集；新增 Filesystem Usage 小节 |
| v2.4.7 | 2026-09-14 | Max Session Memory Sample 增加 client_info 列 |
| v2.4.6 | 2026-09-14 | 表级 I/O 榜列头改为 dbname / schema / object 三列；内存采样列精简 |
| v2.4.5 | 2026-09-14 | 新增表级 Top-10 文件 I/O 与 Max Session Memory Sample；Load Profile 增 WAL 与 pagewriter 行 |
| v2.4.4 | 2026-09-13 | 新增 awr ltx 屏幕报告；修复屏幕报告取不到采样日志目录 |
| v2.4.3 | 2026-09-13 | 全命令分发器硬化：数据错误不再打印满屏帮助 |
| v2.4.2 | 2026-09-13 | awr 输入校验硬化：begin >= end 明确报错，区分数据错与参数错 |
| v2.4.1 | 2026-09-13 | awr 屏幕报告按快照分组渲染，多快照窗口速度明显提升 |
| v2.4.0 | 2026-09-11 | awr baseline 基线命令族；快照核心数据守卫；若干行为修正 |
| v2.3.1 | 2026-09-09 | se 知识库改为 gzip + base64 内嵌，脚本体积缩小约 290KB |
| v2.3.0 | 2026-09-09 | 新增 se 等待事件知识库：417 个事件，含全称、含义、源码级触发点与解决方案 |
| v2.2.0 | 2026-09-09 | awr 屏幕报告新增 cpu / io / page / replstat / replslot / replay 六命令；statement 采集瘦身 |
| v2.1.0 | 2026-09-08 | awr 屏幕报告四命令（topsql / event / summary / tabstat）；新增 file_iostat 采集；ASH 数据源改用函数 |
| v2.0.11 | 2026-09-03 | 报告头新增 OS Version；awrdiff 等窗守卫；数据库未启动时不产生快照 |
| v2.0.10 | 2026-09-02 | 支持备库快照：ASH 走 local_active_session，新增 walreceiver 采样 |
| v2.0.9 | 2026-08-31 | awrrpt 新增 Active Session History 节；TCP RTT 可观测 |
| v2.0.8 | 2026-08-29 | 网络阻塞与丢包可观测性；报告阈值着色；报告头显示数据库角色 |
| v2.0.7 | 2026-08-28 | OS 每分钟明细与报告折叠 |
| v2.0.6 | 2026-08-26 | 全量审计修复：tps / slow / mem / vtop / sqlhc / ssh_setup / 锁分析等 |
| v2.0.5 | 2026-08-24 | tabsize 输出顺序固定 |
| v2.0.4 | 2026-08-24 | vtop 会话内存排行按内存降序 |
| v2.0.3 | 2026-08-24 | 报告头拆分采集版本与生成版本 |
| v2.0.2 | 2026-08-24 | awr show 显示数据目录 |
| v2.0.1 | 2026-08-22 | wdr_event 支持 -E 单事件历史统计 |
| v2.0.0 | 2026-08-21 | 生产加固：vtop 刷新与状态防护、awr 超时与文件权限、孤儿快照清理 |
| v1.4.20 | 2026-08-21 | 新增 vtop 实时监控；快照 CSV 改 gzip 存储 |
| v1.4.19 | 2026-08-20 | awr OS 统计增强；报告换 Oracle AWR 配色；lsds 支持 --raw |
| v1.4.18 | 2026-08-20 | awr 存储按端口隔离；全局选项 -P；lockchain 2PC 判据修正 |
| v1.4.17 | 2026-08-19 | 修正 awr create -d 的报错文案 |
| v1.4.16 | 2026-08-19 | awr 快照清单排序与按日期过滤、自动清理、采样间隔可配 |
| v1.4.15 | 2026-08-18 | 修复 GAUSSLOG 环境变量检测 |
| v1.4.14 | 2026-08-18 | sqlhc / sqltext 支持压缩与轮转日志 |
| v1.4.13 | 2026-08-18 | awr 快照体系重构；新增 osw_netstat |
| v1.4.12 | 2026-08-17 | awr 集成 baseline；恢复单文件发布 |
| v1.4.11 | 2026-05-25 | 模块化结构（commands/ + lib/） |

## License

MIT License
