# 自然排空核心验证 — 2026-11-03

## 1. 提交与改动范围

按用户要求，**先将位宽解耦工作区提交为 `0f43ecb`**，message：`解耦阵列内部部分和与南侧累加位宽`。该提交保存上一版及其18场验证结果。

随后仅对 [PE](<../../npu_rtl/pe.v>) 和 [SA](<../../npu_rtl/sa.v>) 的核心/边缘控制作自然排空改造，新增/更新验证与文档。本轮自然排空改动尚未再次提交或推送。

- PE没有flush端口、flush流水分支或权重写入的 `!flush` 条件，也没有增加kill/epoch等替代PE控制。
- 行skew、所有PE、列deskew只由reset初始化；已经接受的act/weight数据和valid每拍继续前进。
- SA顶层原有metadata/credit/load会话flush保留；新增边缘L周期计算隔离与R周期旧权重ACK隔离，计数器不连接核心寄存器enable/reset。
- **[南侧ACC](<../../npu_rtl/sa_south_acc.v>) 与 [结果FIFO](<../../npu_rtl/sa_result_fifo.v>) 源码相对 `0f43ecb` 无任何改动**，用Git diff检查确认；其既有flush原样保留。
- PE_PSUM_WIDTH / ACC_WIDTH保持独立，默认8×8为19/48，INT32 bias与宽累加语义不变。[来源向量manifest](<reference/manifest.json>)及参考数据也未修改。

## 2. 实际执行

工具：Synopsys VCS `V-2023.12-SP2_Full64`，SystemVerilog、`SA_CHECKS`、`+lint=all`，KDB/FSDB。

```sh
make -C iVerdi/sa_unit regress
make -C iVerdi/sa_unit test FSDB=1
make -C iVerdi/sa_unit test TOP=tb_sa_natural_drain FSDB=1
```

八个顶层各seed=1/7/42，**24场回归全部PASS、退出码0**。另有主向量与自然排空两个FSDB仿真，均PASS、退出码0。`git diff --check`通过。

### 原有功能/位宽回归

六个既有顶层的18场仍全部通过：

- 五组GEMM每seed全部1856个最终元素一致，616个K行token、232个final向量；K27按8/8/8/3并污染后补零，case3–5激活全1。没有部分和反馈输入。
- ACC48协议与ACC32协议各三seed：每场111个输入、96个最终输出，flush/reset取消2个未退休输出；credit满额阻塞5周期，消费者阻塞时仍有南侧提交48/43/46次。
- ACC48允许越INT32后抵消成功；ACC32真正溢出仍poison；40/48/56位ACC真实上下界及±1溢出全部通过。
- 独立PE16/17/19/24/32与ACC40/48/56组合、-128×-128正端点、负partial/负bias符号扩展、完整宽FIFO输出全部通过。
- 1×1/FIFO2、1×8/FIFO9、8×1/FIFO9、3×5/FIFO8（PE24/ACC40）、8×8/FIFO17及3槽非法地址检查全部通过。

### 新增SA自然排空定向测试

[自然排空TB](<tb_sa_natural_drain.sv>)有一个独立物理历史模型：它只在reset清空，**不在flush清空**；期望由外部成功握手的输入包计算。层次观察仅用来对比实际传播/驻留捕获，不用DUT内存值构造数学期望，也没有force修改状态。逻辑checker则按flush取消任务，并独立计时L/R窗口。

三个seed中各配置均PASS：

| 配置 | 中止期间继续经过PE的act观察次数 | 保留下来的aligned lane观察 | flush高电平期间本地weight捕获 | 计算隔离期内新weight握手 |
|---|---:|---:|---:|---:|
| 8×8 | 63 | 8 | 8 | 3 |
| 1×3 | 2 | 3 | 0 | 1 |
| 1×1 | 0 | 0 | 0 | 0 |

1×1没有剩余后续PE级需要跨flush传播，因此相应次数为0是预期边界；该配置仍验证flush与旧ACK/South提交同沿取消、窗口恢复及后续计算。

定向覆盖包括：

1. 同沿接受计算与另一bank权重，再保持flush多拍；逐PE act/bank/valid、逐hop weight data/valid/bank/target、row skew与列deskew都继续走，不被清零。
2. flush高电平期间目标PE驻留PING/PONG实际完成捕获，修复原PE误抑制写入的问题。
3. 旧排队FIFO结果取消，旧核心结果不更新ACC/FIFO/fault/credit，不出现ghost输出或计数下溢。
4. 未完成load仍按顶层旧语义取消，旧raw ACK不能恢复bank_ready；完整发齐但待ACK阶段的单拍flush、短gap后的重复flush都安全。
5. R<L时权重窗口先开放，可在计算仍隔离时开始新tile；没有把compute窗口错误地用来吞新load的合法ACK。
6. 完整重载后新计算正确，bias与未修改的完整bank保留，最终两bank可用且无fault/context残留。

### 新增纯PE定向测试

[纯PE TB](<tb_pe_natural_drain.sv>)只实例化无flush接口的PE；shadow-abort是测试台/控制器状态，不接入PE，也没有替代控制。期间持续驱动原有weight/act valid并独立建模MAC和局部权重。

seed1/7/42均PASS：66个权重包，每场shadow-abort期间20次目标本地捕获、31次权重转发，MAC检查分别57/58/58次；验证两bank读写并行及目标不匹配时只转发不覆盖。

## 3. 边缘语义、限制与可打开结果

顶层保留load会话flush意味着：本次修复“PE阻断已接受包”，**不代表外部load事务可跨flush成功完成**。半装或未ACK的tile必须排空后完整重载，不能根据物理写入已发生就冒充bank完整。详细取舍见 [README](<README.md>)。

最后flush采样沿F之后，保守窗口使新计算最早F+L+1、新权重最早F+R+1握手；flush持续或重入会重新计时。计数器只隔离边缘，核心不暂停。不把固定恢复气泡宣称成最短中止时延，也不把10ns仿真时钟当作PPA/Fmax签核。

- [完整24场回归日志](<build/regress.log>)。
- [SA自然排空seed1](<build/tb_sa_natural_drain/sim_seed1.log>)、[纯PE seed1](<build/tb_pe_natural_drain/sim_seed1.log>)。
- [自然排空FSDB运行记录](<build/tb_sa_natural_drain_fsdb/sim_seed1.log>)、[中止专用波形](<build/tb_sa_natural_drain_fsdb/sa.fsdb>)。
- [主向量FSDB运行记录](<build/tb_sa_fsdb/sim_seed1.log>)、[主向量波形](<build/tb_sa_fsdb/sa.fsdb>)。

```sh
make -C iVerdi/sa_unit wave TOP=tb_sa_natural_drain FSDB=1
```

没有宽度/符号或未命名断言lint提示；保留TB事件等待空语句、LCA提醒和已有FSDB覆盖提醒。不等同专业静态lint/物理签核，未启动或声称人工逐信号浏览GUI。

旧SoC wrapper/DMA/完整命令ABI仍未集成；ACC仍是寄存器数组。独立门控/CDC会改变固定时钟排空前提，未来必须重新设计契约。没有全网络、PPA、STA或CDC签核结论。
