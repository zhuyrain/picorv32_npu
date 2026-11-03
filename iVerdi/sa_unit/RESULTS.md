# 独立 PE/ACC 位宽验证 — 2026-11-03

## 1. 已完成的提交与本轮改动

按用户要求，**先将上一轮工作区提交为 `d48d9c2`**：`重构 SA/PE：级联权重加载、自由流水及南侧本地累加`。该提交保存32位阵列/32位南侧版本及其既有验证结果。

随后修改 [PE](<../../npu_rtl/pe.v>)、[SA](<../../npu_rtl/sa.v>) 和 [南侧ACC](<../../npu_rtl/sa_south_acc.v>)，解耦 `PE_PSUM_WIDTH` / `ACC_WIDTH`。本轮位宽改动仍保留在工作区，未额外提交或推送。参考向量与 [来源manifest](<reference/manifest.json>) 未改。

默认8×8：mesh/deskew为19位，南侧history/FIFO/output为48位，bias仍INT32。安全公式使用 `$clog2(ROWS*16384+1)+1`：原式在ROWS为2幂时少1位（8×(-128)×(-128)=131072，18位signed无法表示）。推导、参数范围与接口见 [README](<README.md>)。

## 2. 实际执行

工具：Synopsys VCS `V-2023.12-SP2_Full64`，SystemVerilog、`SA_CHECKS`、`+lint=all`，KDB/FSDB。

```sh
make -C iVerdi/sa_unit regress
make -C iVerdi/sa_unit test FSDB=1
```

六个顶层，各运行seed=1/7/42，共 **18场回归全部PASS、退出码0**；另有一场默认19/48配置FSDB主向量仿真，通过。六个顶层是主向量、默认ACC48协议、ACC32协议、形状/FIFO、独立mesh位宽和独立南侧边界。

### 黄金向量

| case | M×K×N | 元素/seed | 三个seed |
|---|---|---:|---|
| 1 | 32×32×16 | 512 | PASS |
| 2 | 32×27×16 | 512 | PASS |
| 3 | 32×8×16 | 512 | PASS |
| 4 | 32×8×8 | 256 | PASS |
| 5 | 8×8×8 | 64 | PASS |

每seed全部1856个最终元素一致，接受616个K行token、输出232个final向量；384个non-final更新在南侧本地完成，无顶部部分和反馈。K27按8/8/8/3并先污染权重再补零；case3–5输入全1。Python任意精度GEMM也重算全部黄金值。

计算/装载重叠写握手分别394/381/391；输出反压周期分别105/105/143。该计数不是实测系统SRAM流量或性能加速比。

### 默认48位与显式32位协议

两种ACC配置的三个seed都PASS；每场111个输入、96个最终输出，明确flush/reset丢弃2个未退休向量。保留加载ACK/bank保护、bias一次、多槽与同槽连续更新、长时间消费者阻塞、满FIFO/credit、在途持续排空、上下文错误和flush/reset检查。

- **ACC48**：INT32正/负越界不置fault，后续反向K块抵消成功，输出非零bias；合法超过INT32的最终结果可保持全48位。
- **ACC32**：相同位宽限制下的真正signed32溢出报error2、poison至last并返回0；后续抵消不能伪造成功。
- 每seed有5个credit满额阻塞周期；消费者不ready时南侧仍提交48/43/46次。mesh没有恢复全局冻结。

### 独立mesh/ACC宽度与极端值

[位宽测试](<tb_sa_widths.sv>)的五个并行实例，在三个seed下全部PASS：

| ROWS×COLS | PE_PSUM_WIDTH | ACC_WIDTH | 检查要点 |
|---|---:|---:|---|
| 1×2 | 16（自动） | 48 | +16384正端点与负符号扩展 |
| 3×3 | 17（自动） | 40 | 非2幂行数的最小宽度 |
| 8×3 | 19（自动） | 48 | +131072正端点，原18位表达式会失败 |
| 8×2 | 24（覆盖） | 56 | 两参数真正独立 |
| 8×3 | 32（覆盖） | 48 | 扩大内部宽度不改变边缘配置 |

所有实例从正常权重/激活端口送入A=B=-128，以及负partial、INT32_MIN bias、宽中间抵消和超过INT32的最终输出；填满宽FIFO再随机反压排空，逐lane比较完整ACC位宽，不只检查低32位。

### 真正宽ACC上下界

[南侧独立测试](<tb_sa_south_widths.sv>)分别以40/48/56位运行，每实例7个final边界结果检查，三个seed全PASS：

- 精确MAX/MIN端点不误报；MAX+1、MIN−1真实溢出报error2。
- 真正ACC溢出后再抵消仍poison。
- INT32正/负越界可继续宽累加并抵消，不误报。
- INT32 bias符号扩展正确，mask外端点不误触发溢出。

此单元测试将PE部分和接口宽度设为ACC宽，通过合法partial输入迅速抵达边界，**没有force或注入DUT内部状态**；它不是声称默认19位mesh单块就能产生48位峰值。

### 形状与FIFO

保留1×1/FIFO2、1×8/FIFO9、8×1/FIFO9、3×5/FIFO8、8×8/FIFO17，三个ACC槽及非法地址3检查全部PASS。其中3×5显式使用PE24/ACC40，其他为自动内部位宽/默认ACC48。覆盖最小容量、非2幂回绕、长阻塞自由排空、本地4轮K累加及flush保bias。

## 3. 日志与边界

- [完整18场回归日志](<build/regress.log>)。
- [默认48位协议](<build/tb_sa_protocol/sim_seed1.log>)、[32位协议](<build/tb_sa_protocol32/sim_seed1.log>)。
- [独立位宽日志](<build/tb_sa_widths/sim_seed1.log>)、[南侧边界日志](<build/tb_sa_south_widths/sim_seed1.log>)。
- [FSDB运行记录](<build/tb_sa_fsdb/sim_seed1.log>)、[更新后的波形](<build/tb_sa_fsdb/sa.fsdb>)，打开：`make -C iVerdi/sa_unit wave FSDB=1`。

当前构建未出现RTL宽度/符号或未命名断言lint提示；保留正常TB事件等待 `Lint-[NS]`、工具LCA提醒及已有FSDB覆盖提醒。没有启动或声称人工逐信号浏览桌面GUI。

48位对K≤4096、完整INT8与任意INT32 bias有充分数值裕量，但不是无限轮数保证，实际ACC溢出仍诊断。最终转INT32/量化需上层另行范围检查；本版输出不偷偷窄化。物理参数安全检查不依赖SA_CHECKS，但本报告没有额外列出非法参数的动态拒绝场次。

旧SoC wrapper/DMA/完整命令ABI仍未集成；ACC为寄存器数组，若映射SRAM需重审RMW、端口和时序。没有PPA/Fmax/STA/CDC或全网络签核结论。
