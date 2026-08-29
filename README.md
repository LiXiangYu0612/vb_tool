# vb_tool

VastBase 数据库运维脚本工具集（单文件 Bash 工具，23000+ 行）。

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

> v1.4.12 起恢复**单文件发布**（`vb_tool` 即全部功能，无外部依赖文件）。
> v1.4.11 及之前的模块化结构（`commands/` + `lib/`）保留在 tag `v1.4.11` 中。

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
- 所有命令统一支持 `-h` / `-help` / `--help` 查看各自帮助（v1.4.19 起全命令统一）。

## 命令列表（节选）

| 命令 | 说明 |
|------|------|
| `as [pid]` | 显示活跃会话信息 |
| `asp <type> -b <begin> -e <end>` | 活跃会话概要分析 (cnt/event/waitchain/sql) |
| `awr create` | 手动创建 AWR 单点快照 |
| `awr enable` / `awr disable` | 启停 cron 定时采样（间隔由 `awr config interval` 控制，默认 60 分钟） |
| `awr awrrpt begin <id> end <id>` | 生成两快照区间 AWR 报告 (HTML) |
| `awr awrdiff begin <a> end <b> begin <c> end <d>` | 两区间对比报告 |
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
| `vtop` | oratop 风格实时监控：OS（CPU/内存/网卡/数据盘 IO）+ SESS/LTX 会话与长事务 + ISTAT 负载速率（tps/逻辑物理读/redo/temp）+ EVENT 等待事件 Top5（帧间差值）+ DBMEM/MEMCTX/TOPMEM 内存 + TOPSQL（sqlid 汇总、真实 CPU% 倒序）+ LOCK final blocker（lockchain 同源）；top 式原地刷新、阈值着色、`-i`/`-n`/`--once` |

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
    ├── repl_<YYYYMMDD>.log  # pg_stat_replication 每分钟采样
    └── slot_<YYYYMMDD>.log  # pg_replication_slots 每分钟采样
```

> v1.4.18 起按端口分目录存储，多实例可并行采样互不干扰；旧版扁平布局在首次运行时自动迁移至 `awrs/<port>/`。

## 依赖

- VastBase/openGauss 数据库，且 PATH 中有 `psql` 客户端（工具直接调用 `psql`，无 `gsql` 兜底）
- Python 3（内嵌报告渲染等需要）
- 常用系统工具: `top`, `sar`, `iostat`, `free`, `df`, `ip`

## 版本历史

| 版本 | 日期 | 要点 |
|------|------|------|
| v2.0.8 | 2026-08-29 | 网络阻塞/丢包可观测性 + 报告阈值高亮体系：TCP 逐分钟表新增 ListenDrops/ListenOverflows/Timeouts/SynRetrans 4 列（采样器加读 /proc/net/netstat 新行类型 tcpext，仅新快照起有数据），Retrans% 阈值标色（>0.1% 粗体、>1% 红色粗体，逐分钟+System Activity 汇总）；Network Protocol Errors 补 6 项 TcpExt（OFOQueue/OFODrop/WantZeroWindowAdv/ToZeroWindowAdv/SACKReneging/MemoryPressures，零窗口/乱序队列/SACK/协议栈内存压力，老快照重出报告即生效）；新增 Softnet 节（/proc/net/softnet_stat 跨 CPU 求和，dropped/time_squeeze，awrrpt 整窗+awrdiff P1/P2/Δ）；Network 表新增 RX/TX Util % 列（ethtool Speed 解析，virtio 等无速率环境显示 -）；报告头 AWR 行改为 DB Role（采快照时 pg_is_in_recovery 落 meta.json，primary/physical standby，窗口内角色变迁显示 a -> b，备库场景可辨）；阈值高亮体系：CPU busy >50% 粗/>80% 红、磁盘 r/w_await >10ms 粗/>20ms 红、pswpin/pswpout >10/s 粗/>100/s 红、pgmajfault >5/s 粗/>50/s 红（正常工作量代理指标 pgpgin/pgpgout/pgfault 特意不标）；修复 _awr_collect 漏采 /proc/vmstat+/proc/loadavg（整窗 Memory/Paging 表自始全 0）；Cache Hit Ratio 脚注及列头星号清理 |
| v2.0.7 | 2026-08-28 | awr OS 每分钟明细+报告折叠：4 个 OS 节（CPU/Disk/Network/Memory-Paging）整窗表下新增默认收起的 Per-minute detail 折叠块（cron 每分钟采样 /proc 写 os_*.log，速率=相邻样本差÷实际秒差，含 r/b、MemUsed/Avail、zone 水位 WM Free/Min/Low/High）；Wait Events/SQL Text/Database Parameters 三整节默认折叠（原生 <details> 无 JS，TOC 锚点保留；awrdiff 同步）；Memory 明细含内核 zone 水位列（/proc/zoneinfo 全 zone 求和，旧格式日志兼容）；System Activity 表头合一；retention 清理覆盖 os_*.log(.gz)；2026-08-28/29 就地并入：TCP 逐分钟表（Opens/s/Retrans/s/Retrans%/CurrEstab）+System Activity TCP 扩展+retention 默认 8 天等，见后续 v2.0.8 前提交 |
| v2.0.6 | 2026-08-26 | 全量审计修复版（24575 行分区审查+204 实证）：`tps` 修复（\prompt 未执行致命令不可用）；`slow` 非交互场景修复（管道/cron 下提示吃掉脚本）；`vtop -i`、`awr awrrpt begin` 等 7 处缺参死循环补 guard；`mem` 修复 CTAS 标签泄漏+memory guc 节被吞；vtop DSK 段支持 LVM 逻辑卷（/dev/mapper 解析至 dm-N，此前 PGDATA 在 LV 时无 I/O 数据）+设备消失负值钳零；sqlhc 修复默认用户表统计整组空表（normalize_user 重复定义遮蔽）并堵住 EXPLAIN PERFORMANCE 误执行 DML（注释/WITH/已带 EXPLAIN 三类穿透）；ssh_setup 改追加模式不再覆盖远端 authorized_keys；lockchain/lock_details/vtop 锁树 w_chain 改 LIKE 匹配（正则 `.` 通配符误配兄弟链）+lock_details 补 2PC 持锁者；wdr_summary 整数除法、redundant_index 关联失效、sqlstat lag 前置、relxlog 列错位、tabsize 分区关联/默认库/笛卡尔、kill 白名单统一等 SQL 修复；collect_log timeline 硬编码/dbinfo 覆盖/tar 失败保护；analyze_log_v2 修复 --mode error 失效、csv 列序串列、时间戳格式兼容等 16 项；awr marker 端口前缀互撞锚定；awrrpt Cache Hit 第三列改为真窗口命中率（Window Hit%）；全局清除 31 处 `Default footer is off.` 输出污染；banner 版本号改动态；retention 默认 30→8 天（2026-08-26 就地并入） |
| v2.0.5 | 2026-08-24 | 修复 `tabsize` 输出顺序不定：内层子查询有序但外层缺 ORDER BY（与 v2.0.4 TOPMEM 同款模式），外层补 `order by tt.total_size desc`（限定列引用，避开外层 pretty 别名的字典序） |
| v2.0.4 | 2026-08-24 | 修复 vtop TOPMEM 会话内存排行未按内存降序：内层子查询有序但外层 join 缺 ORDER BY，行序不定；现携带聚合值排序输出（显示列同时省去一次重复聚合） |
| v2.0.3 | 2026-08-24 | awrrpt/awrdiff 报告头 vb_tool 版本格改为 `采集版本 / 生成版本` 双值（生成版本取运行时版本，区分"旧快照+新报告"场景） |
| v2.0.2 | 2026-08-24 | `awr show` 新增 `data dir` 行：快照根目录绝对路径（per-port） |
| v2.0.1 | 2026-08-22 | `wdr_event -E "<事件名>"` 单事件历史统计：精确忽略大小写、默认 7 天窗、明细+加权 TOTAL+max 行、三级检查（无快照/无事件提示） |
| v2.0.0 | 2026-08-21 | 生产环境加固版（vtop/awr 全面风险复查后的修复）：vtop 修复 stdin 关闭时全速刷帧死循环（nohup/管道场景对库高频冲击，现按刷新间隔休眠）；vtop 速率/字节格式化负值防护+ISTAT 实例重启计数器清零防护；vtop EVENT 段排除空闲等待（`wait cmd` 空闲霸榜且把真实等待挤出采样窗口，`none` 同排；flush data/Sort 等干活状态保留）；awr 跨库对象统计的 per-db psql 补齐连接/语句超时（防单个库挂起拖长 create 并长时间持锁）；awr 报告 html 与 repl/slot 日志统一 0600 权限（含 SQL 文本/备机地址，umask 077）；awr 孤儿快照（create 中途被杀、无 meta.json）改按目录 mtime 清理（原先永不清理累积）；修复报告 Platform 行在无 DMI 机器（容器/部分 ARM）误报 Physical（空 join 产生空格 truthy，现正确回落 cpuinfo hypervisor 判虚拟） |
| v1.4.20 | 2026-08-21 | 新增 `vtop` 实时监控命令（oratop 风格完整版：OS+SESS/LTX 长事务+ISTAT 负载速率（tps/逻辑物理读字节/redo/temp 每秒）+EVENT 等待事件 Top5（wait_events 帧间差值、RT 语义）+DBMEM/MEMCTX/TOPMEM 内存三段+TOPSQL（sqlid 汇总、top 线程真实 CPU% 排序、ET 合计）+LOCK final blocker（lockchain 同源递归 CTE、2PC 感知）；身份行含 CPU 拓扑 sockets/cores/threads/lcpu 与 vb_version()；top 式原地刷新（无闪屏）+阈值红黄着色（管道自动降级纯文本）；默认 -n 10）；awr 报告 Platform 行显示 CPU 架构（lscpu/uname -m）+物理/虚拟；awr 快照 db/*.csv 改 gzip 存储（约 7× 压缩，渲染端新旧格式混用兼容） |
| v1.4.19 | 2026-08-20 | awr 报告 OS 统计大升级 + Oracle AWR 正宗配色：磁盘表合并 lsds 设备元数据列（Size/Type/Rot/Sched/QDepth/NR_RQ/WC）+ discard/flush 统计（kernel 4.18+）；CPU Info 新增 Platform 行（物理机/虚拟机识别）；网络表新增 Speed/Duplex/Queues/RX·TX ring 列；新增 Network Protocol Errors 节（netstat -s 错误类计数器：核心 30 项固定序、0 值灰显、非零尾巴追加）；报告样式换装 Oracle AWR 原版配色（钢蓝 #336699 标题/卡其分隔线/亮蓝 #0066CC 表头白字/淡黄 #FFFFCC 隔行/棕色 #663300 链接）；大节标题右上加 ↑ Top 返回目录按钮；列名 AWR 化（Reads per Sec 等，去除所有 /s 表头）；修复 SQL 表维度为 CPU/IO Time 时列重复；lsds 新增 --raw 原始输出；全命令统一支持 -h/-help/--help |
| v1.4.18 | 2026-08-20 | awr 存储按端口分实例（`awrs/<port>/`，多实例并行采样互不干扰，旧扁平布局自动迁移）；新增全局选项 `-P <port>` 指定实例端口（仅本次调用生效）；lockchain 2PC 判据修正（`pid IS NULL` + vxid `-1/<xid>`，prepared 事务以 `P:<xid>` 显示）；`awr show` 新增 `last snap age` 存活提示（ENABLED 时显示 ok/STALE，防"crontab 还在但快照早停了"的静默故障）；修复 interval=60 时 `*/60` 触发 crontab 安装告警（改为 `0 * * * *`） |
| v1.4.17 | 2026-08-19 | 修复 `awr create -d` 报错文案：仍引导已移除的 `enable -d`，改为 `awr config interval <min>` + `awr enable` |
| v1.4.16 | 2026-08-19 | awr 增强：`list` 倒序+默认 30 条+按日期过滤；快照自动清理（保留期默认 30 天，`config retention`，0=永久，挂 create/enable 钩子）；采样间隔可配（`config interval`，enabled 下即时生效）；`awr show` 总览（吸收原 status 命令）；`enable` 移除 `-d` |
| v1.4.15 | 2026-08-18 | 修复 `GAUSSLOG` 检测：`env | grep -iw` 在 PWD/OLDPWD 含 "gausslog" 时误匹配拼坏路径，改为直接读环境变量 |
| v1.4.14 | 2026-08-18 | `sqlhc`/`sqltext` 支持压缩与轮转日志（.log.gz/.csv.gz，zgrep 预筛 + gzip 解析） |
| v1.4.13 | 2026-08-18 | awr 单点 snap 重构（Oracle 风格 snap_id + awrrpt/awrdiff + cron 采样，含 replication/slot 采样器与 `awr status`）；新增 `osw_netstat` |
| v1.4.12 | 2026-08-17 | awr 集成 baseline；恢复单文件发布 |
| v1.4.11 | 2026-05-25 | 模块化结构（commands/ + lib/） |

## License

MIT License
