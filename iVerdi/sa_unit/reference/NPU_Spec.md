# NPU 软硬协同规格：存储、命令队列与 DMA 控制边界

> 状态：**设计提案 v0.2，已结合外部硬件工作树静态审查；Q0/Q1 均未实现，不代表现有 RTL 已支持新 ABI。**
> 日期：2026-11-01。目标：PicoRV32 裸机环境；先修复/验证现有控制边界，按需给整任务加队列，再扩展到解耦 GEMM 与固定 PE 预算的组合式阵列。
> 本次仅修改本文；外部硬件仓库只读，未构建、未仿真、未改动源码或配置。以下 RTL 风险是静态发现/推导，不冒充已复现失败。
> 审查基线：硬件 HEAD `d1299002ef3a4b6e9213bc58c30619c2a93bb3de`，分支 `feature_resnet`；工作树顶层有用户原有的 `FPGA` 宏修改。实际工作树内容优先于 README 和 HEAD 默认配置。

## 0. 结论与实施选择

**先学 Gemmini 的“存储对象 + 命令依赖 + 分层循环”，不要只学 FIFO，也不要照搬完整 Gemmini。**

结合实际 RTL，区分两条路线，避免把“大重构”说成“补一个 FIFO”：

- **短期建议 Q0 / LEGACY_TASK_QUEUE**：先给现有完整卷积任务做原子快照、按序排队、完成计数，不改变滑窗/PE 数据格式，不宣称独立 LD/EX/ST 调度。详细改造顺序见第14节。
- **研究型目标 Q1 / QUEUE_V1**：保留下面的显式 GEMM、local SP/ACC、三引擎队列设计，属于显著数据通路重构。只有研究确需独立tile映射/重构时再走这条路线。

**两条路线共同的前置门槛：消除旧 CSR 的 0x100 镜像、禁止 busy 期间重启/改 live config、建立不丢数据的流控及可靠完成/故障语义。**

以下第4–13节若未特别注明，均规定 Q1，而不是已经存在的功能；Q0 不自动继承 Q1 的矩阵格式/局部地址/跨K部分和能力。

Q1 提案作出以下选择：

1. 保留现有 canonical 一次启动式接口作为 LEGACY；新增独立 Q1，先修复完整地址译码，再靠 ID/能力位识别，不能让旧固件误启动新语义。
2. Q1 使用 **CPU 写 16 个暂存字 + 一次 SUBMIT 原子提交**，分发到 LD、EX、ST 三个同步 FIFO；每类 FIFO 深度 8，另有 1 条活动命令。
3. Q1 不读取内存链表，不实现通用 scatter/gather，也不做通用 ROB 地址比较。**软件负责缓冲区依赖分析，硬件执行三个完成序号条件。**
4. Q1 硬件负责二维步长搬运、字节拼接、尾块补零/写掩码、AXI 协议与背压、片上 SRAM 仲裁、跨 K 块宽部分和、最终 requant 和完成/错误语义。
5. Q1 首先固定一个 **8×8 WS 子阵列、8×8×8 物理计算块**。这是验证控制边界的起点，不是把现有 64×8 RTL 宣称成 8×8，也不是最终 256 PE 论文对比。
6. Q1 接受显式 `A[M,K]`、`B[K,N]`；卷积 im2col、OHWI→B 转换先由软件完成。MaxPool、Add、GAP 先交给 CPU。
7. 内存描述符环、硬件循环展开、隐式 im2col、写回池化和四子阵列重构均为后续独立能力，不能用“加 FIFO”概括这些工作。

**最小正确版本不等于最高性能版本。** 对 PicoRV32，小块命令注入本身可能是主要瓶颈；第 11 节给出可量化例子。

## 1. 现有硬件：工作树静态核查结果

### 1.1 基线与可复现边界

只读审查仓库 [picorv32_npu](<A:/file/Projects/VScode/Verilog/picorv32_npu/>)，HEAD `d1299002ef3a4b6e9213bc58c30619c2a93bb3de`。审查开始时唯一 Git 修改为 [SoC 顶层](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L1-L5>) 第 3 行启用 `FPGA` 宏；本文读取的是这份工作树，不是擅自恢复到 HEAD 后审查。

- 顶层 FPGA 分支选择 **64×8**，非 FPGA 分支选择 **4×4**：[参数实例](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L727-L735>)。不能再按硬件 README 的“FPGA 4×4、仿真 64×64”描述当前源码。
- [SA](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/sa.v#L161-L170>) 在 FPGA 条件下每 PE 权重深度为 9，非 FPGA 为 64；模块缺省值不是最终实例值。不同文件中的宏和实际编译单元/文件顺序仍须统一：顶层内 `define` 不能替代整个构建的明确全局 profile。
- [VCS 清单](<A:/file/Projects/VScode/Verilog/picorv32_npu/iVerdi/Makefile.vcs#L79-L109>) 没有显式加入 `+define+VCS`，而 [时钟/复位产生](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L38-L71>) 受条件宏控制。本文未预处理、综合或运行，因此不声称当前磁盘配置能直接通过 VCS，也不把条件分支等同于已部署比特流。
- 下述“已实现”表示源码有该逻辑，不表示本次动态验证通过；风险以静态推导表述。软件 [CPU HWC 黄金](<../C/resnet/cpu/main_im2col_hwc.c#L1-L8>) 与新 Q0/Q1 的 RTL 验收仍是三件不同的事。

### 1.2 实际拓扑：已经有部分重叠，但不是 Gemmini 存储架构

```text
CPU clk_pico -> AXI-Lite CDC -> 单事务仲裁互联 -> 共享 SRAM / NPU CSR / UART
                                  ^
                                  | 32-bit AXI Full
                           NPU wrapper，clk 域
                   Bias/Weight 读主控 + 激活行预取（共用读口）
                                  |
                四行 line buffer -> skew -> 64×8 WS PE
                                  |
                  每列 bottom ACC -> PPU -> deskew
                                  |
                  输出数据 FIFO -> 独立 AXI 写回 FSM
```

- [AXI CDC 与 CPU](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L309-L383>)：CPU 在 `clk_pico`，NPU/互联/SRAM 在 `clk`。代码时钟注释/仿真产生器给出 100/200MHz，但这不是实测 Fmax 或部署时钟保证。
- [主 FSM、读口 MUX 与预取握手](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L577-L663>)：Bias→Weight→滑窗计算由主 FSM 组织；激活预取和输出写回分别有 FSM，可在计算期间工作。`ASYNC READ`/`req_load_row` 在这里是**同一 clk 域的后台并行/翻转握手**，不是异步时钟 FIFO。
- [读口路由](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L649-L657>)：Bias/Weight 与激活预取共享一个物理 AR/R 口；不是三个读 DMA。
- [互联仲裁](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/axi_interconnect.v#L477-L518>) 按读/写请求 round-robin，单个全局事务 FSM 持有 grant 至 B 或末尾 R；[响应状态](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/axi_interconnect.v#L675-L756>) 证明它不是可让 CPU/NPU/读/写同时前进的非阻塞 crossbar。NPU QoS 接 15 不等于此仲裁器采用 QoS 最高优先级。

因此：当前可以重叠“阵列计算”和部分后台搬运，但系统总线上有效读写事务仍串行；不能仅加三个命令 FIFO 就获得三路存储并发。

### 1.3 真实存储容量与组织

| 对象 | 已核查源码事实 | 对规格的约束 |
|---|---|---|
| 系统 SRAM | [顶层实例](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L851-L858>) 512KiB；[互联译码](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L598-L606>) 19 位，范围 `[0,0x80000)` | 与 [软件链接脚本](<../RISCV/custom.lds#L7>) 一致；旧 1MB/2MB 注释不能当容量 |
| SRAM 通路 | [Port A](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L861-L890>) 在非 FPGA 顶层被接零；CPU/NPU 均经互联到 Port B | “双端口 SRAM 模块”不等于当前系统分配了 CPU/NPU 独立端口 |
| line buffer | [实例参数](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L409-L431>) 为 line_width 最大 34、IC4 groups 最大 16；[四个数组](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_line_buffer.v#L37-L46>) 为 4×34×512bit=8704B | 三行窗口+一行预取，寄存器式滚动/选择；不是任意地址可读写的 tile scratchpad |
| 权重 | [PE 局部数组](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/pe.v#L43-L53>) 和 [按四行分组配置](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/sa.v#L105-L109>) | FPGA profile 64×8×9 个 INT8 槽；深度/分组需要受控，不能直接接 B[K,N] DMA |
| Bias/权重入口 | [每列两个 32-bit 数组](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L620-L628>) | 64×8 profile 各 8 个 word，非独立 SRAM tile |
| 部分和 | [bottom ACC](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_bottom_acc.v#L42-L87>) 每列一个 32-bit 寄存器及窗口计数 | 不是多 M/N tile 的 accumulator SRAM；没有跨任务 K 分块宽部分和接口 |
| 输出 FIFO | [实例](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L528-L545>) `ADDR_WIDTH=6`，宽度 `SYS_COLS*8`；[内部实现](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_sync_fifo.v#L25-L48>) 64 个 BRAM 槽，外加 FWFT 输出寄存器 | 这是**数据 FIFO，不是命令 FIFO**；64×8 时每个数据项为 8B/一个像素通道片 |

line buffer、PE 权重、ACC 均不保证全局 reset 后数据清零：[line buffer reset](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_line_buffer.v#L58-L76>) 主要重置指针，[PE reset](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/pe.v#L58-L65>) 不清权重数组，[ACC reset](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_bottom_acc.v#L53-L64>) 仅清 valid，靠 preload 对齐状态。Q1 的 local 地址与 bank 容量全部属于新增设计，不得映射成这些现有对象的“别名”。

### 1.4 LEGACY CSR 精确契约与窗口别名

[CSR 字段/状态提取](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L124-L192>)、[写译码](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L250-L286>) 和 [读译码](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L329-L347>) 为依据：

| 偏移 | 实际语义/有效字段 |
|---|---|
| `+0x00` | 读 bit2=DONE、bit1=BUSY、bit0恒0；写 bit0=START 脉冲、bit2=W1C DONE。**DONE 不是 bit1** |
| `+0x04/08/0C/10` | ACT/WEIGHT/BIAS/OUT 系统字节基址，32-bit，不做合法范围/对齐检查 |
| `+0x14` | H[31:16]、W[15:0]，unsigned16 |
| `+0x18` | 每行输入 word 数[31:16]、权重 word 数[15:0]；1 word=4B |
| `+0x1C` | 输出像素步长 bytes[31:23]；line buffer 读切片末索引[22:19]；每 PE 权重循环数[18:11]；行宽[10:4]；写 IC4 group 末索引[3:0] |
| `+0x20` | OC[31:24]；四列一组门控[23:8]；[7:6]未用；ky_skew[5]；pad[4]；kx/ky末索引[3:2]/[1:0] |
| `+0x24` | zero point[31:16]、multiplier[15:0]，二者均**零扩展**到32bit，非 signed16 符号扩展 |
| `+0x28` | drain[31:22]、FIFO阈值[21:12]、[11:6]未用、shift[5:1]、ReLU[0] |

普通配置CSR保存并读回全32bit（**CTRL_STATUS除外，它返回合成状态**），不代表保留位被使用；字段有多少位也不代表所有编码都能合法执行。读写从口虽然暴露 AXI4-Full 边带，但当前只处理单次 AW/W→B 和 AR→一拍 R，忽略 burst 元数据与 WSTRB，RRESP/BRESP 恒 OKAY；只应使用对齐 32-bit、full strobe、LEN=0 访问。未知缩减索引读 `0xDEADBEEF`，写忽略。

**阻断级迁移问题：硬件只用地址 `[7:2]` 译码，整个 4KiB aperture 每 0x100 镜像一次，低两位也忽略。**

| 上一版 Q1 地址 | 现有 RTL 实际访问 |
|---|---|
| `+0x100 Q_ID` | 旧 CTRL_STATUS（只读探测不会命中新 magic） |
| `+0x110 Q_CTRL` | 旧 OUT_BASE，绝不是 ENABLE/RESET |
| `+0x120 Q_SUBMIT` | 旧 CFG_SPATIAL，会破坏空间配置 |
| `+0x124 RC` | 旧 CFG_QUANT |
| `+0x200 PERF[0]` | 又一次旧 CTRL_STATUS |

所以先改为完整 `[11:0]` 字节偏移/对齐译码，再分配独立窗口；保留的是 canonical LEGACY `+0x00..+0x28`，**不保留与新窗口冲突的历史镜像**。新驱动必须先只读 ID，匹配版本后才写新窗口；现有硬件不匹配就返回 unsupported。不得为了试探先写 ENABLE、RESET、SUBMIT。

### 1.5 START、live config、DONE 与 reset

- 主 FSM 仅在 IDLE 接受 START：[主控启动](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L761-L799>)；但 [写回 FSM](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1198-L1207>) 与 [预取 FSM](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1363-L1370>) 不管 busy 都响应 START。**busy 时重复 start 不是安全忽略，会清握手/重置指针，可能破坏在途 AXI。**
- 配置 CSR busy 时仍可写，各字段为 live wire；不存在整任务 active snapshot。不能让 CPU 用旧 CSR 配置下一个排队任务。
- START 自清，但不清 sticky DONE，也不清输出 FIFO 等全部状态。安全旧驱动应先等 idle、清旧 DONE、配齐参数、再 START，启动后直到完成不可改 live config。
- 内部 set DONE 与 W1C 同拍时，[后执行的 W1C](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L238-L274>) 优先；Q1 要求 set-dominant 是新增行为。
- 当前 [完成条件](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1111-L1123>) 是软件 drain 计数达到后，FIFO empty 且写 FSM idle；写 FSM [确实等过 B 握手](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1290-L1307>)，不是发完 WLAST 就 DONE。但它没有检查 RRESP/BRESP，没有把预取/所有读在途计入完成证明；固定 drain 不能当协议性排空。
- 只有全局 rst_n，没有 CSR soft reset/abort/quiesce/epoch。FPGA [互联复位](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L608-L613>) 与 NPU resetn 是不同输入；复位一方不等于另方已排空，未来故障恢复需要系统级协调。

### 1.6 DMA 与背压已有能力及缺口

- 已有读/写的 4KiB 边界、最大 256 beats 分片计算：[读计算器](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L665-L711>)、[写计算器](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1133-L1160>)。地址/长度流水后等待准备计数；这是可复用基础，不应写成“目前完全不支持 burst”。
- DMA 为 32-bit、INCR、SIZE=2、ID=0、non-cacheable；读指针每 beat 四字节，支持的是连续行/权重流，不是通用二维矩形、gather 或字节 aligner。
- [输出 word 数](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1214-L1247>) 用 `OC>>2` 且 WSTRB 固定1111：当前没有任意 OC 尾 mask。OC=1/2/3 会得到零 word 数；OC=10 也不是“自动写10字节”。旧路线必须 pad 到4的倍数并保护分配；64×8 实例每次安全候选 OC=4/8，不能配10/16。
- [FIFO](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_sync_fifo.v#L43-L56>) 满时直接压掉新写，没有向 PPU 返回 ready，也没有 overflow sticky。`almost_full` [只计 BRAM 指针差](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_sync_fifo.v#L99-L103>)，不含已预取 FWFT 项；阈值单位是输出像素数据项，不是32-bit AXI word。
- [背压采样](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L1000-L1074>) 在窗口边界禁止新 act_valid，不会冻结已经进入 skew/PE/PPU/deskew 的数据；必须推导不可停顿 headroom。阈值0会阻止计算，超过64会失去保护，40只是已用配置，不是任意 profile 的安全证明。
- RRESP/BRESP 和返回 ID 未被用于错误处理；RLAST 被信任，没有完整 expected-beat 协议检查。新 Q0/Q1 的 FAULT、watchdog、合法性拒绝均需新增。

### 1.7 数值路径不是完整 bit-true 契约

- [PE](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/pe.v#L115-L153>) 的乘积16bit、psum32bit；[bottom ACC](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_bottom_acc.v#L66-L87>) 窗口32bit累加，没有溢出拒绝，也没有可保留跨任务部分和 SRAM。Q1 的 ACC48 是结构改造，不是改一个 CSR 即可获得。
- [PPU](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_ppu.v#L94-L137>) 虽然有64bit乘积、算术右移，但右移后先存入32bit `shifted_s4`，再32bit加零点，最后 [饱和](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_ppu.v#L149-L160>)。若移位后的值超32bit，会在饱和前窄化而改变符号/数值。
- 静态反例：`acc=32769`、multiplier=65535、shift=0、zp=0，数学上应clip为+127；现有32bit窄化得到`0x80007FFF`，成为负数，最终clip=-127（若ReLU则0）。此为位宽推导，本文未仿真复现。
- 当前 Tiny 的 Conv1/2/3/FC multiplier 均落在16bit范围，但残差 Add 主分支 multiplier=66934，超过旧 CSR 的65535；旧数据通路也没有 Add/GAP/Pool。不能通过塞入旧量化寄存器宣称支持全部 Tiny。

### 1.8 IRQ、内存可见性与故障可恢复性

- [IRQ 接线](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L311-L328>) 实际是 **irq[4]**，不是旧 README 图里的bit5；`npu_done_level` 从 clk 直接进 CPU clk_pico，没有看到 IRQ 电平同步器。AXI CDC 已有不意味着 IRQ CDC 已解决。
- [PicoRV32 pending/waitirq](<A:/file/Projects/VScode/Verilog/picorv32_npu/picorv32.v#L1538-L1555>)：有pending则返回位图，否则等待；waitirq看所有 pending，不等于原子的“检查任务后睡眠”。ISR先消费事件、重复/合并唤醒、重新锁存的电平都需处理。Q1首版仍以完成计数+轮询为准，不能只数IRQ。
- [CPU AXI adapter](<A:/file/Projects/VScode/Verilog/picorv32_npu/picorv32.v#L2731-L2787>) 无 RRESP/BRESP 输入；SLVERR不能成为软件唯一错误报告方式。新命令错误必须可读 RC/FAULT，不能指望自动总线异常。
- 当前实例没有 D-cache；CPU store 等 B，CDC 反映 [下游真实 B 后才返回](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/axil_cdc_wr.v#L184-L210>)；[SRAM 写](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/axi_dp_sram_hybrid.v#L465-L479>) 实际提交在响应之前。对这套组合，正常完成的 CPU 写→后续doorbell和NPU写完成→CPU读已有源码层面的排序依据，不再是完全未知。更换cache/bridge后仍按第10节重新建约。
- 核心识别标准FENCE funct3=000，且 [默认开启64bit cycle计数](<A:/file/Projects/VScode/Verilog/picorv32_npu/picorv32.v#L2518-L2542>)；无 cache 时FENCE没有独立刷缓存机制。WFI、mret、通用特权CSR不可当现成支持。可用rdcycle测CPU域周期，不能把它直接当NPU域周期。
- **CPU deadline不能保证处理总线卡死**：现有互联一个NPU burst若永远等R/B，会连CPU取指/CSR也阻塞；CPU可能根本没机会执行超时检查。必须有互联之外仍运行的watchdog/协调复位路径。Q1本地watchdog能诊断但不自动取消外部已接受事务。

补充软件边界：[HWC 数据](<../C/resnet/cpu/test_vector_hwc.h#L5-L12>) 无通道补齐/打包；[首层矩阵](<../C/resnet/cpu/test_vector_hwc_im2col.h#L5-L29>) 仅A/B；[Tiny 平台头文件](<../C/resnet/npu.h>) 仍未启用NPU CSR宏。旧 packed卷积、CPU HWC黄金与Q1矩阵不能混为一种布局。

## 2. 对原讨论的核查与修正

### 2.1 正确的主线

Gemmini 确实采用访问/执行解耦，包含 LoadController、ExecuteController、StoreController；输入 scratchpad 与宽 accumulator 分开；写回 DMA 中有池化比较逻辑。这些方向适合借鉴。证据见 [G1] 的 DAE、Scratchpad、DMA 小节及论文 [G7]。

### 2.2 不能照搬的表述

| 原讨论中的表述 | 更准确的结论 | 对本设计的影响 |
|---|---|---|
| 三个控制器“完全独立、没有紧耦合，只靠 token” | 共享 SRAM、带宽和仲裁；Reservation Station/ROB 记录片上地址范围及跨控制器依赖，按依赖条件发射。并发不是无条件的。[G1][G2][G3] | 仅放三个 FIFO 不会自动解决 RAW/WAR/WAW；必须明确依赖责任 |
| RoCC 指令直接进入三个 FIFO | 正常路径包含命令入口、可选/高层循环展开、Reservation Station，再发射给各控制器；控制器还有内部队列。[G2] | 分开“CPU 接口”“任务调度”“DMA 数据通路”三层 |
| 不经过 AXI，所以指令几乎瞬间发完 | RoCC 是命令接口，仍有 ready/valid 背压、CPU 发射和队列容量限制；数据搬运仍经过存储系统。MMIO 也并非天然极慢，具体取决于互联实现 | 不预设 FIFO 可消除 CPU 成本，必须测注入周期 |
| 必须加异步 FIFO | 仅跨不同时钟域才需要可靠 CDC；同一时钟域用同步 FIFO | 默认同步。跨域版必须处理原子命令、Gray 指针、复位和完成事件同步 |
| 写 src、len、pad 各一次便压入任务 | 多次寄存器写不是原子命令；若每次都入队会得到半配置任务 | 必须有 shadow/staging + COMMIT/SUBMIT，提交时快照所有字段 |
| mvin/mvin2/mvin3 对应三个独立读 DMA | 它们是三套独立加载配置上下文，适用于 A/B/D 的不同 stride；LoadController 选择上下文。不能据此推出三个读引擎。[G1][G4] | Q1 每条命令自带 stride，先只实现一个读 DMA和一个写 DMA |
| 所有 tiling 和底层命令展开都由 C 完成 | 软件选择大块/外层划分；`gemmini_loop_ws` 发高层配置和循环命令；硬件 LoopMatmul/LoopConv 用 FSM 展开、双缓冲并调节命令投放。[G1][G2][G5] | 软件与硬件循环不是非黑即白；先测 Q1，再决定 Q2 是否加硬件 loop |
| DMA 做池化不消耗 MAC，所以几乎免费 | 不占阵列 MAC，但占 SRAM 读端口、比较器、窗口控制、缓冲和写回时间；文档标为实验性且要求 NHWC。[G1][G6] | 第一版 CPU 池化；融合池化必须另立语义/布局/跨块契约 |
| FIFO 比 descriptor ring 更“标准”，后者很复杂不划算 | 两者解决不同问题；RoCC FIFO 不等于 MMIO FIFO。固定长度 ring 可以很简单，但增加命令取数、发布一致性和错误处理 | Q1 选 FIFO 是缩小验证面，不是证明 ring 不值得做 |
| DMA 一旦负责 padding，就可以直接从 HWC 获得任意 im2col tile | GEMM 尾部补零与卷积滑窗补零不同；HWC→im2col 常需要多维地址生成、边界判断和数据复用，普通 2D DMA 不够 | Q1 显式 im2col；隐式 im2col 为独立 Q2 能力 |

补充两点容易遗漏的知识：

- Gemmini 的本地地址是 **行寻址并带特殊位**，系统内存地址是字节地址；不能直接搬它的地址编码到本工程。[G1]
- Gemmini 的默认缩放实现不等同于本工程的整数 `MULT/SHIFT` 契约。借鉴架构不等于复用数值语义。[G1][G7]

版本审慎性：截至检索时，官方 [issue #409](<https://github.com/ucb-bar/gemmini/issues/409>) 有用户报告同址 mvin 完成乱序，涉及本次固定的源码版本；它仍是未关闭、未有维护者确认的报告，不是本文复现的结果。该报告再次说明：**按序发射 ≠ 按序完成；设计目标 ≠ 正确性证明。** 本规格选择每个引擎一条活动命令以降低这一风险。

## 3. 最值得学习的 Gemmini 知识与阅读顺序

| 顺序 | 知识点 | 当前工程应产出的东西 |
|---|---|---|
| 1 | scratchpad/accumulator 分离，显式软件管理、局部行宽、bank 和端口 | 每种 tile 的字节量、生命周期、bank/端口占用表 |
| 2 | load/store/execute 解耦与 RS 地址依赖 | RAW/WAR/WAW 例子、缓冲复用规则、完成条件，不是先写三个大 FSM |
| 3 | mvin/config、stride、shape 与 local address | 带单位的搬运命令格式；区分有效形状和物理形状 |
| 4 | LoopMatmul + 软件 tiled matmul | 软件选块/分配，硬件规律计数/搬运的分界；核算命令字节量 |
| 5 | DMA 分包、在途事务、bank 冲突与背压 | burst 合法性、FIFO headroom、不丢数据的停顿传播 |
| 6 | writeback scaler/activation/pooling | 位宽、舍入、融合边界和可观察的 debug 输出 |
| 7 | 全栈论文的 CPU、im2col、存储系统实验 | 端到端时间，不只汇报 PE busy；比较 CPU 控制/数据布局成本 |

推荐先读 [G1] 中 Major Components 与 ISA，再追 [G2] 命令连接、[G3] 依赖、[G4] load context，最后读 [G5] 硬件循环和 [G7] 系统实验。Gemmini 使用 TileLink 和虚拟地址/TLB 的部分主要作为概念参考，Q1 不移植 TLB/PTW、不实现 OS 支持。

## 4. 目标、边界与软件职责

### 4.1 Q1 必须支持 / 明确不支持

**必须支持：**

- INT8×INT8 GEMM、INT32 bias，M/N 为软件可寻址和内存容量允许的正数，逻辑 K 限定 1..4096，再由软件切块；单条 EX 物理块固定 8×8×8，有效维度 1..8。K>4096 必须拒绝或 CPU 兜底，不能靠中途 FINAL/requant 后继续累加绕过限制。
- 一项逻辑输出块跨 K 累加，完整 K 不超过 4096；按第 8 节实现无中间窄化的数值契约。
- 物理地址、32-bit 系统地址空间、little-endian，沿用已核查的 AXI4 32-bit 系统接口；新增字节aligner/错误检查和命令合法性，不假定旧DMA已满足这些语义。
- LD、EX、ST 各自有序完成、三引擎可并行；软件显式声明依赖。
- 原子提交、队列满重试、错误粘滞、可读完成计数、CPU 超时路径。
- INT8 输出和最终 INT32 MAC 调试输出。

**不支持：**

- 本版 DMA 解析网络、自动选 tiling、动态内存分配、通用链表、虚拟地址、cache coherency 协议。
- 本版硬件直接读 OHWI 做滑窗；旧 packed 权重流与 Q1 的 B[K,N] 不互换。
- 默认硬件 Pool/Add/GAP、任意 dilation/transpose-conv、运行中切换阵列模式。
- 多核/多生产者提交、context switch、抢占恢复；IRQ handler 不能同时写 staging。

### 4.2 责任划分

| 功能 | CPU/软件 | Q1 硬件 |
|---|---|---|
| 模型/层顺序 | 负责 | 不解析模型 |
| M/N/K、外层循环/复用顺序 | 负责 | 执行已编码的小块 |
| 外存基址、stride、有效尾块 | 计算并验证 | 再验证描述符和物理越界 |
| 缓冲区分配与依赖 | 软件 scoreboard，生成 wait 值 | 满足 wait 才执行，不做通用地址依赖推导 |
| 字节拼接、尾零/写 mask | 提供 valid shape | 负责，不访问无效行的逻辑源地址 |
| AXI/内存返回时序 | 不参与逐拍控制 | 全部负责；CPU 不编排 AXI beat |
| SRAM 仲裁、流控、阵列 skew/drain | 不写经验等待周期 | 全部负责，以握手和真实在途数据判定 |
| 宽部分和、requant、ReLU | 配置参数、提供参考 | 负责准确实现；不能逐 K 块先量化 |
| im2col、Pool/Add/GAP | 第一版负责 | 后续 capability 才可卸载 |

## 5. 存储契约

### 5.1 三类外存格式必须区分

1. HWC 激活、OHWI 权重：见 [HWC 数据](<../C/resnet/cpu/test_vector_hwc.h>)，无 channel padding。
2. Q1 GEMM 格式：A 行主序 `[M,K]`，B 行主序 `[K,N]`，C 行主序 `[M,N]`。见 [首层转换器](<../C/resnet/cpu/hwc2im2col.c#L31-L65>)；其 B 与 CPU GEMM 接收的 W[N,K] 转置关系明确。
3. 旧滑窗 NPU 格式：[Tiny 导出器](<../python/resnet/export_test_vector.ipynb>) 按 OC tile、IC4 group、ky、kx、OC lane 组织权重，四个 INT8 打成一个 32-bit word。**它不是直接 row-major B，也不等同于 K 方向末尾补齐。**

例如 IC=3 的 3×3 卷积，逻辑 K=27。Q1 按 8 切为 8/8/8/3，最后一个物理块补 5 个零；若按每个像素 IC 补 4 则形成 9×4=36 个槽位，布局和填零位置均不同。

### 5.2 Q1 本地地址与最小存储 profile

以下均为新设计建议，不是现有硬件容量。系统 SRAM 的 512KiB 预算与 NPU 私有 SRAM 分开记账；若 FPGA 实现共享物理 BRAM，必须重新划分和修改链接脚本。

- local address：32-bit **逻辑字节地址**；高 nibble 0 为 SP，1 为 ACC，其余非法；不作为 CPU 系统地址解引用。
- SP：4 banks × 1KiB = 4KiB，建议每 bank 64-bit、1R1W、写 byte-enable；所有同址读写必须通过依赖避免，不依赖厂商 RAM 的 read-during-write 行为。
- ACC：2 banks，每 bank 暴露 1KiB 的 INT32 调试地址视图；内部每个值 48-bit，因此实际数据存储至少 3KiB，而非 2KiB，另计 metadata/ECC。
- 同一引擎有冲突则仲裁/停顿，不承诺“多 bank 就没有冲突”；EX 在接受输出前必须预留接收空间。

建议固定对象，便于软件 scoreboard：

| 对象 | local address | 逻辑大小/用途 |
|---|---|---|
| A0 / A1 | `0x00000000` / `0x00000040` | 各 64B，8×8 INT8，bank 0 |
| B0 / B1 | `0x00000400` / `0x00000440` | 各 64B，8×8 INT8，bank 1 |
| Bias0 / Bias1 | `0x00000800` / `0x00000820` | 各 32B，8 个 INT32，bank 2 |
| Y0 / Y1 | `0x00000C00` / `0x00000C40` | 各 64B，最终 INT8，bank 3 |
| Acc0 / Acc1 | `0x10000000` / `0x10000400` | 各 256B 逻辑视图，物理为 64 个 48-bit 值 |

Q1 的 EX 只接受表中对象起点：A/B 各自对应类型的两个槽、ACC 两个槽、Y 两个槽、Bias 两个槽或无 bias 标记；不支持任意别名对象。DMA 的 local 矩形必须完整落在一个已定义对象内。其余容量保留，不因此开放给软件任意访问。

LD 的写数据与 EX 的 A 读可以使用同 bank 不同地址的 1R1W 端口；若实际 SRAM 只支持单端口，必须仲裁并通过性能计数反映停顿。Q1 不用双倍容量掩盖端口不足。

### 5.3 生命周期

- A/B：LD 完成后才能 EX；EX 完成后才能覆写。Q1 保守地等完整 EX，不利用“预载权重后 B 已不再读”的提前释放。
- Bias：INIT 的 EX 消费后才可覆写。
- ACC：INIT→若干累加→FINAL；FINAL 后可 ST_S32，下一次 INIT 必须等所有读者结束。
- Y：FINAL 生成后可 ST_S8；下一个 FINAL 覆写前必须等 ST 完成。
- CPU 不得在 DMA 读取期间修改源内存，也不得在 DMA 写入完成之前消费目标。跨层 CPU 算子必须在层屏障和内存可见性处理之后执行。

## 6. 命令 ABI：不是链表，而是原子快照

### 6.1 MMIO 新窗口

基址沿用 `0x40000000`，但以下偏移均为 **Q1 提案**。现有译码并不允许安全扩展：必须先从 `[7:2]` 改为完整4KiB精确译码、检查对齐，并验证 `+0x100/0x200` 不再镜像旧CTRL。仅保留 canonical `+0x00..+0x28` 为LEGACY；历史镜像明确废弃。Q0、LEGACY 与 Q1 不得同时运行；切换时要求全部在途事务与数据排空。新驱动未读到精确Q_ID前，禁止写本表任何新控制/暂存地址。

| 偏移 | 名称 | 访问与含义 |
|---|---|---|
| `0x100` | Q_ID | RO，固定 `0x4E505531`，即 NPU1 |
| `0x104` | Q_VERSION | RO，`0x00010000`，major=1/minor=0 |
| `0x108` | Q_CAPS | RO：bit0 Q1，1 LD2D，2 ST2D，3 EX8_WS，4 ACC48，5 MAC_S32_DEBUG；Q1 均为 1，其余 0 |
| `0x10C` | Q_STATUS | FIFO pending 数：LD[3:0]、EX[7:4]、ST[11:8]；活动位[18:16]；[30] QUIESCED；[31] FAULT |
| `0x110` | Q_CTRL | RW bit0 ENABLE；W1P bit1 QUIESCE、bit2 RESET；reset 仅在第 10 节的安全排空条件满足时成功 |
| `0x114` | Q_IRQ_ENABLE | RW bit0 completion、bit1 fault；默认 0 |
| `0x118` | Q_IRQ_STATUS | RO/W1C bit0 completion pending、bit1 fault pending；置位优先于同拍清除 |
| `0x11C` | Q_ERROR | RO，第一运行时错误码，复位清除 |
| `0x120` | Q_SUBMIT | WO，写 1 尝试原子提交 staging；其他值返回 BAD_CMD，不提交 |
| `0x124` | Q_SUBMIT_RC | RO，最近提交结果：0 ACCEPTED、1 FULL、2 BAD_CMD、3 DISABLED、4 FAULTED |
| `0x128/12C/130` | LD/EX/ST_SUBMITTED | RO，各引擎最后接受的序号 |
| `0x134/138/13C` | LD/EX/ST_DONE | RO，各引擎连续成功完成到的序号 |
| `0x140/144/148/14C` | FAULT_ENGINE/SEQ/TAG/ADDR | RO，首错定位；无相关系统地址时 ADDR=0 |
| `0x150/154/158` | LD/EX/ST_LAST_TAG | RO，各引擎最后成功完成的用户 tag |
| `0x15C` | DMA_TIMEOUT | RW，活动命令无进展 watchdog 周期；0 禁用，默认 0；仅 disabled 且排空时可改 |
| `0x160/164` | DMA_RD_BASE/LIMIT | RW，允许读的系统地址半开区间，reset 为空 |
| `0x168/16C` | DMA_WR_BASE/LIMIT | RW，允许写的系统地址半开区间，reset 为空 |
| `0x170` | Q_MMIO_ERROR | RO/W1C粘滞诊断：bit0总线未对齐，1非法SIZE/LEN，2部分WSTRB，3模式锁禁止的LEGACY写；reset=0，set优先于同拍W1C，不中止合法活动任务 |
| `0x180..1BC` | CMD_WORD[0..15] | RW，16×32-bit staging，仅 full-strobe 写；reset 清零 |
| `0x200..27C` | PERF[0..15] | 16 个 64-bit 性能计数，低字在前，第 12 节定义 |

未定义 Q1 偏移读0、写忽略；canonical LEGACY窗口内未知索引仍保留原约定，但不保留高地址镜像。Q1 CSR仅允许单拍LEN=0、32-bit对齐、SIZE=2、full WSTRB访问；非法请求不产生副作用，支持时返回SLVERR，同时必须留下可读的编程错误诊断，不能只靠SLVERR，因为本平台CPU不接响应错误码。新译码的对齐/大小/strobe检查是新增逻辑，旧CSR不具备这些检查。

可观测性限制：CPU [把地址低两位对齐](<A:/file/Projects/VScode/Verilog/picorv32_npu/picorv32.v#L379-L382>)，顶层 [固定AxSIZE=2](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/tb_picorv32.v#L249-L278>)；因此CPU的byte/halfword LOAD在从口看起来仍是对齐32-bit读，不改adapter就无法识别。“只允许32-bit访问”首先是驱动ABI约束，前端只能拒绝总线上可观察的非法地址/SIZE/LEN/WSTRB；窄STORE仍可由strobe识别。测试不能要求未携带到总线的宽度信息也被CSR辨认。

拒绝请求仍必须完成总线协议：对结构合法但LEN>0的禁用CSR burst，写侧接收/丢弃声明的W beats且不执行任何CSR动作，再返回错误B；读侧返回规定拍数的错误R及正确末拍RLAST。不能只锁存诊断后不再握手，否则会锁住当前全局fabric。若对端本身违约（缺beat/错误WLAST/永不返回），记录协议错误并交独立timeout/协调reset处理，不承诺靠错误响应完成回滚。

Q_CTRL ENABLE 复位为 0，仅控制是否接受新提交；清 ENABLE 不撤销已接受命令、不关闭其执行时钟。QUIESCE 同样停止新提交、允许已接受工作完成，并保持拒绝提交直至 RESET。正常 QUIESCED 表示三个队列、活动槽及总线在途事务全空；FAULT 时允许队列仍有待丢弃命令，但活动槽及总线必须全空。RESET 令 ENABLE=0、QUIESCED=1、SUBMIT_RC=DISABLED，并清除 QUIESCE 锁存。DMA 窗口、watchdog、性能计数清零仅允许 disabled 且安全排空时操作，不能在仍有已接受工作时修改。QUIESCE 锁存期间即使 ENABLE=1，SUBMIT 也返回 DISABLED；RESET 条件不满足时整个 Q_CTRL 写忽略、状态不变，驱动必须先观察安全 QUIESCED，再 reset 并读回 ENABLE/计数确认。FAULT 后活动槽只在其已发事务和本地在途更新排空后清除，不能提前用 ACTIVE=0 冒充排空。若 ENABLE=0 但未 QUIESCE/FAULT，可重新写 ENABLE=1 恢复提交；QUIESCE 或 FAULT 后须先 reset。Q_ID 不匹配时驱动直接报 unsupported，不写旧 CSR 猜测版本。

### 6.2 提交原子性与队列满行为

1. CPU 填完 16 个 staging 字；写入 staging 本身不触发任务。
2. `Q_SUBMIT=1` 的 MMIO 写事务执行时，硬件校验字段/序号/已接受依赖/地址区间。
3. 若合法且目标 FIFO 有空间，**同一次提交快照全部 64B**，入对应 FIFO，更新 SUBMITTED，RC=ACCEPTED；后续 staging 修改不影响已入队任务。
4. 若 FIFO 满，RC=FULL，序号和 FIFO 均不变化。SUBMIT 不因等空位长期占住总线；软件稍后重试同一份命令。
5. BAD_CMD 不推进计数、不产生 DMA、不置运行时 FAULT；软件把它作为编程错误。运行时错误则按第 10 节处理。
6. `Q_SUBMIT_RC` 在 MMIO 写响应返回前更新；同一主机随后读取必须看见该结果。一个生产者串行使用该窗口。

MMIO 从设备必须分别正确接收 AXI AW/W（若使用 AXI-Lite），不能假定两者同拍到达。SUBMIT 只能触发一次；背压/重试不能复制入队。异步桥如有，需要传递完整快照，不能分别同步 16 个活跃配置寄存器。

### 6.3 描述符公共部分：16 个 little-endian uint32_t

| word | 字段 | 编码 |
|---|---|---|
| 0 | header | opcode[7:0]；flags[15:8]；ABI=1[23:16]；[31:24]=0 |
| 1 | seq | 目标引擎 SUBMITTED+1；0 保留 |
| 2 | wait_ld | 依赖 LD 的成功完成序号；0 表示不等待 |
| 3 | wait_ex | 依赖 EX 的成功完成序号 |
| 4 | wait_st | 依赖 ST 的成功完成序号 |
| 5..14 | payload | 按 opcode 解释，不能混用单位 |
| 15 | user_tag | 软件标识；不替代 seq，不参与依赖比较 |

flags 的字节内部位：bit0 IRQ_ON_DONE，bit1 INIT，bit2 FINAL，bit3 RELU，bit4..7=0。INIT/FINAL/RELU 仅 EX 可用，RELU 必须同时 FINAL。opcode：`0x01 LD2D`→LD；`0x02 ST2D`→ST；`0x10 GEMM8_WS`→EX；其他拒绝。

固定结构可写为 `uint32_t word[16]`，必须 `_Static_assert(sizeof(desc)==64)`。不要用 C bitfield 或依赖编译器 packing；字段显式移位、掩码，并在打包前验证范围。

### 6.4 LD2D / ST2D payload

| word | LD2D | ST2D |
|---|---|---|
| 5 | 系统源地址 | local 源地址 |
| 6 | local 目标地址 | 系统目标地址 |
| 7 | `rows_total[15:0] \| cols_total[31:16]` | 同左 |
| 8 | `rows_valid[15:0] \| cols_valid[31:16]` | 同左 |
| 9 | 源 row stride，字节 | 源 local row stride，字节 |
| 10 | 目标 local row stride，字节 | 目标系统 row stride，字节 |
| 11 | dtype：0=S8，1=S32，其余非法 | 同左 |
| 12..14 | 0 | 0 |

这里 `\|` 表示两段字段组合，不是把它作为字符串。rows/cols 单位均为**元素**，stride 与地址均为**字节**。dtype 决定元素宽 e=1/4。

Q1 限制：total 行/列均 1..8；valid 行/列均 1..total。stride 必须正数且不小于其一行使用的字节数：local 按 total cols，系统按 valid cols；S32 地址/stride 必须 4-byte 对齐。

LD：对 `r<rows_valid && c<cols_valid` 读取 `src+r*src_stride+c*e`；其余 local total 矩形位置写 0。**不读取无效行/列的逻辑元素，不保留旧尾数据。** S8 只能写 A/B；S32 只能写 Bias（1×8 total）。

ST：仅写 valid 矩形；不写 total 中无效尾行/列，不把填零扩写到下一个 tile。S8 只读 Y；S32 只读已 FINAL 且无溢出的 ACC，所有 total/valid 维度必须与该源对象最近一次 EX 的物理/有效形状相容。

A/B/Y 的 local row stride 固定 8B，ACC 的逻辑 row stride 固定 32B，Bias 为 32B。A/B/Y total 固定 8×8；Bias total 固定 1×8；ACC 的 ST total 固定 8×8。对象间不允许 local DMA copy。

### 6.5 GEMM8_WS payload

| word | 含义 |
|---|---|
| 5 | A0/A1 local 起点，物理 8×8 S8 |
| 6 | Acc0/Acc1 local 起点，物理 8×8 宽部分和 |
| 7 | m_valid[15:0]、n_valid[31:16]，均 1..8 |
| 8 | k_valid[15:0]，1..8；高 16 位=0 |
| 9 | FINAL 时 Y0/Y1 local 起点；非 FINAL 为 `0xFFFFFFFF` |
| 10 | INIT 时逻辑 K_total，1..4096；非 INIT 为 0 |
| 11 | B0/B1 local 起点，物理 8×8 S8，逻辑 B[k,n] |
| 12 | INIT 时 Bias0/Bias1 起点或 `0xFFFFFFFF` 表示无 bias；非 INIT 必须为该无效标记 |
| 13 | FINAL 时有符号正数 INT32 multiplier；非 FINAL 为 0 |
| 14 | FINAL 时 shift，0..31；非 FINAL 为 0 |

动作：

- INIT：创建/重建 ACC 上下文；有效 `[m,n]` 设为 bias[n] 或 0，然后加当前 k_valid 的乘积；无效 m/n 槽清零。
- 非 INIT：ACC 必须存在未 FINAL 上下文，m/n_valid 必须相同；在宽部分和上继续相加。
- 每次累计 k_valid；不超过 INIT 声明的 K_total；FINAL 时必须恰好等于 K_total。
- FINAL：先检查最终有效 MAC 是否都可表示为 INT32，再统一 requant/clip/可选 ReLU，写 Y；保留最终 MAC 以供 ST_S32。非 FINAL 不量化、不截断。
- 未 FINAL 的 ACC 禁止被 ST 读取。重新 INIT 覆写已完成 ACC 前由软件依赖保护所有 ST 读者；若重建一个仍开放的上下文，运行时 BAD_CONTEXT。
- A/B 的物理尾部必须由 LD 清零；阵列可以执行 8×8×8 的零填充运算，也可以门控，但不能把无效尾当有效 MAC 计数。

无需把 bias、multiplier 等通过可变全局配置寄存器留给执行时读取；每条 EX 自带相关参数，避免队列中旧任务被新配置污染。

## 7. 调度、依赖与双缓冲

### 7.1 Q1 选择“软件 scoreboard + 硬件完成序号”

每引擎 FIFO 内按序，一次只执行一条活动命令，**上一条命令真正成功完成才启动下一条**。因此 `DONE[e]` 表示从 1 到该值全部完成，不是某条较新的工作先完成。

队首可启动条件：

```text
LD_DONE >= wait_ld && EX_DONE >= wait_ex && ST_DONE >= wait_st
&& 本引擎 idle && 必要资源可获得 && !FAULT
```

提交时每个 wait 值必须 `<= 对应 SUBMITTED`；同引擎 wait 必须 `< 本命令 seq`。不允许引用尚未接受的未来命令。所有依赖指向全局提交顺序中的更早任务，因而排除描述符依赖环；同引擎 FIFO 前序也隐式构成完成依赖。**不能只比较跨引擎 token 而忽略同引擎覆写。**

计数器不进行模比较：到 `0xFFFFFFFF` 后拒绝新提交，驱动安全排空并 reset，开始新 epoch。reset 后旧 seq/票据全部失效。

Q1 不自动发现软件漏报的 RAW/WAR/WAW。可信驱动必须是唯一入口；软件模型和 debug assertions 应验证对象生命周期。通用 RS/范围比较是后续可选硬件策略，不可与本版的责任混淆。

### 7.2 软件如何生成 wait，而不是手写魔法数

每个 local 对象保存：最后写者 `(engine,seq)`，以及 LD/EX/ST 各自最后读者序号。把对象粒度作为保守别名范围：

- 新读：等待该对象最后写者。
- 新写：等待该对象最后写者及所有尚未完成读者。
- RMW（ACC 累加）：等价于读+写。
- 合并多个对象的依赖：每引擎取所需 seq 的最大值，填入三个 wait 字。
- 仅在 SUBMIT_ACCEPTED 后更新软件 scoreboard；FULL 重试不得提前更新。

例：LD A0/B0 → EX0，LD A1/B1 可与 EX0 并行；再次 LD A0/B0 必须等待 EX0 完成。EX 的 FINAL 写 Y0 后，ST Y0 依赖它；再次写 Y0 则等该 ST。若开 MAC debug，重新 INIT Acc0 同时要等 ST_S32 完成。只等待“生产者写完”而忘记“旧读者读完”会产生 WAR 覆写错误。

外存对象也要有生命周期：初版禁止 DMA 目标与任何未完成源/目标区间重叠，除非软件模型能证明依赖且命令确实等待。不要利用不声明的外存别名来绕过 local scoreboard。

### 7.3 完成点必须写清

- **LD_DONE**：所有读响应已被接收、拼接，所有有效数据和尾零已提交到可供 EX 读取的 local SRAM；不是 AR 握手，也不是发完请求。
- **EX_DONE**：所有阵列在途结果和 accumulator 更新已落定；FINAL 的 Y/INT32 debug 已有效；不是最后一拍输入进入阵列。
- **ST_DONE**：全部 AXI B 响应成功返回，并达到本系统定义的 CPU 可见性点。仅完成 WLAST 不够；若桥接器提前应答必须增加 flush/readback 等平台保证。

上述条件不满足，完成计数绝不推进。不能用固定 `drain_timeout=132` 替代真实排空证明。

### 7.4 FIFO 不保证 CPU 可立即离开

若 FIFO 只有 8 项、整层有数千项，CPU 必须持续补充。排队解决“每项都 wait IRQ”的串行化，不解决“整层已托管”的问题。

驱动建议接口（均为拟议函数，不是现有实现）：

```c
int npu_probe(struct caps *out);
int npu_try_submit(const uint32_t word[16]); // 0接受，EAGAIN满，其余错误
int npu_wait_ticket(enum engine e, uint32_t seq, uint64_t deadline);
int npu_layer_fence(uint64_t deadline);     // 捕获三个submitted，再等待相应done
int npu_quiesce_and_reset(uint64_t deadline);
```

提交模型：单生产者持锁（裸机可无并发，但不能让 ISR 写 staging）→检查软件字段→完成必要 cache clean/release→写 16 字→写 SUBMIT→读 RC→接受后更新 scoreboard。

等待模型：先检查 FAULT/DONE，达标立即返回；否则按平台保证的“不丢唤醒”机制等待，再循环检查。不得把“收到一次 IRQ”当成完成某个任务。若 PicoRV32 的 pending IRQ/`waitirq` 语义不能证明 read-check 与休眠之间不丢事件，Q1 首版用有 deadline 的轮询，不直接复制旧等待函数。

现有路由已确认是IRQ4，但缺少clk→clk_pico电平同步。Q0/Q1必须在CPU输入前加入合适的电平同步器和协调复位，IRQ源保持粘滞直到软件确认，不能发送未握手的窄脉冲。MMIO继续复用已有AXI-Lite CDC；命令staging/FIFO位于NPU的clk域，**不再凭空增加跨域命令FIFO**。具体同步器及约束仍需CDC工具/仿真验收。

Q1 completion在带IRQ_ON_DONE的命令完成时置pending，fault始终置fault pending；IRQ是`(pending & enable)!=0`的电平信号。清W1C后重新检查所有计数和FAULT。FAULT本体只能reset清除，不能靠W1C隐藏。CPU已锁存的pending不会因外设W1C自动清掉，ISR需容忍重复/合并唤醒，不能以IRQ次数等同命令数。

## 8. 数值契约与跨 K 分块

沿用 [HWC GEMM 黄金实现](<../C/resnet/cpu/main_im2col_hwc.c#L166-L210>) 和 [公共整数算子](<../C/resnet/resnet_int8.c#L133-L153>)，不是 Gemmini 默认缩放：

```text
acc[m,n] = int32_bias[n] + sum_over_full_K(int8_A * int8_B)
q = clip(floor((int64(acc) * int32_multiplier) / 2^shift), -127, 127)
y = relu_enabled ? max(q,0) : q
```

- zero point=0；有效 INT8 数据限定 [-127,127]，保留 -128 不作为模型有效值；DMA 不做重新归一化或重新校准。
- Q1 每个 PE 局部累加及 ACC 更新不能在未完成全 K 时溢出/饱和。建议使用有符号 48-bit 累加，K_total<=4096 时含任意 INT32 bias 的绝对上界小于 `2^31 + 4096*127*127 < 2^32`，48-bit 有足够裕量。
- 如内部仍用 32-bit 部分和，必须限制并证明所有中间值都不溢出；不能仅因最终值在 INT32 内就认为安全。Q1 的 ACC48 能力不得用逐块 32-bit wrap 冒充。
- FINAL 时统一验证最终 MAC 在 INT32 范围，越界报 ACC_OVERFLOW，不饱和冒充成功。成功后 INT32×INT32 的乘积放在 signed64 中，负数右移按向负无穷取整，不加 rounding bias。
- bias 只在 INIT 加一次；每个 K tile 都加 bias、先各自 requant 再相加，均为错误。
- Conv3 保留 signed requant/Clip，再进入 Add；融合执行也不能直接把未量化 ACC 加残差。
- Add：两路 INT8 分别乘各自 multiplier，宽位求和后共用 shift，检查调试 INT32、clip，再 ReLU。
- GAP：仅处理非负 ReLU 输出，`(sum + divisor/2)/divisor`，当前 divisor=256，不改变尺度。
- Q1 的 Add/GAP/Pool 由 CPU 执行；若未来卸载，必须独立通过相同逐元素黄金测试。

## 9. DMA 必须做到多复杂

### 9.1 建议 RTL 分层

```text
MMIO staging/submit
        |
   LD_Q / EX_Q / ST_Q + done counters
        |       |       |
      LD2D    WS+ACC    ST2D
        |       |       |
 byte aligner / banked SP / ACC + requant
        |               |
 AXI read engine     AXI write engine
```

DMA 可以拆成三个局部状态机，不必合为“理解整个卷积”的 FSM：

1. 命令层：校验、逐行计数、有效形状与 local zero fill。
2. 请求层：行地址、4KiB 分割、burst 长度、字节拼接/掩码。
3. 事务层：AR/R 或 AW/W/B 握手、响应错误、在途计数、流控。

EX独立管理权重预载、A馈送、skew/drain、ACC和Y，DMA不判断该层是Conv还是FC。Q1一读DMA+一写DMA；每方向最多1个在途burst、固定ID、每引擎最多1条活动命令。复用当前互联时，物理总线全局一次只能服务一个读或写事务，CPU注入也要竞争；三引擎并行仅保证内部调度能力及与本地计算重叠，不保证外存读写全双工。先保障正确性，再决定是否值得换crossbar/双端口接入或放宽outstanding。

### 9.2 地址、对齐与 AXI 约束

- 系统地址范围由 RD/WR window 限定在真实可 DMA 访问的 SRAM；不得覆盖 CSR/UART。范围、最后一行地址、乘法加法均以至少 64-bit 检查，最终地址不得绕回 32-bit。
- S8 支持任意字节起点和 stride，例如 A 的 stride=27。读 aligner 可以读对齐的 32-bit word 后挑字节；分配器必须保证矩阵总分配按 4B 上取整、末尾 guard 可读，且对齐扩读范围全部在 RD window 内。**逻辑上不读无效元素，不等于总线上永远没有对齐扩读。** 禁止扩读 MMIO/保护页，不把这一点隐藏给软件。
- ST 必须用 WSTRB 保护首尾无效字节；没有有效元素的行不发 AW/W。不允许读改写目标 word 来代替正确 strobe，因为可能破坏相邻并发 tile。
- AXI4 INCR burst，建议Q1最大16 beats（旧硬件上限256，不要求Q1照搬）；不跨4KiB，不超过从设备允许长度。当前阻塞互联下，缩短burst还可降低CPU取指/提交被单笔DMA占用的最长时间，真实收益须测量。一次上层LD2D不等于一次AXI burst。
- 对齐 beat 的拆分上界：`beats <= min(MAX_BURST_BEATS, row_remaining_beats, (4096-(addr&4095))/4)`。跨行合并为可选优化，不能改变逻辑 row stride 或越过 valid 矩形。
- AW 和 W 是独立握手；一旦接受某个 burst，必须正确处理全部 beats、WLAST 与 B。读侧同样核验 RLAST/RRESP。
- VALID 已置且 READY 未置时，地址/数据/last/strobe 保持稳定；所有计数器仅在对应握手或本地提交成功时推进。

### 9.3 流控不是“FIFO 差不多够大”

定义读响应暂存容量 `D_r`、写数据容量 `D_w`、阵列输出容量 `D_y`。实现时至少给出：

- 若接收 AR 后不能保证全程拉低 RREADY，则必须为该 burst 的全部返回数据预留空间；若可停顿，仍要覆盖内存宏/桥接器固定延迟和 skid buffer 中不可撤回的数据。
- 接受 AW 前有策略保证后续 W 数据最终可达；不能因“先占住外部资源、再等内部永远不能满足的依赖”造成死锁。
- 启动 EX 前预留无法及时停止的全部结果，或证明 valid/ready 可安全冻结整条 skew/PE/ACC 管线。不能仅停 A、让权重/valid 继续走。
- `D_y - almost_full_threshold >= 最大停顿传播期间新增结果 + 已在途结果`，所有量用同一单位。Q1 的具体阈值由 RTL 延迟推导，不能沿用旧固件数值当证明。
- SRAM 仲裁须无饥饿；响应路径不等待后续未提交命令。随机 AXI 背压下也应持续进展。

### 9.4 第一版明确不让 DMA 做什么

不算 tile 地址的全局优化，不决定一个层切几个 N/K 块；不认识 ResNet 残差图；不自动分配 local 地址；不解析通用 next 指针；不在 K 分块途中 requant；不替 CPU 解决 cache 所有权。

## 10. 内存可见性、错误与恢复

### 10.1 发布/消费协议

1. CPU 写完源数据、bias；有 D-cache 时 clean，随后 release/order barrier。
2. DMA 目标在发布前也要转移 cache-line 所有权：保证不存在可在 ST 期间逐出的 dirty 目标行/别名；按平台执行必要 clean+invalidate。目标与其他 CPU 数据共享 cache line 时应改为独占/对齐分配，或保证整行在 DMA 期间无人读写并正确保留相邻数据。仅在 DMA 完成后 invalidate 不足以防止脏行覆盖 DMA 结果。
3. 提交描述符必须排在源可见及目标所有权移交之后；`volatile` 只约束编译器访问，不能保证 cache clean 或总线完成。DMA 活动期间 CPU 不访问已移交目标，不修改源及其共享缓存行。
4. NPU 的 ST_DONE 建立系统可见性；CPU 在 wait 成功后执行 acquire/order barrier，有 D-cache 时按平台再次失效目标 cache line，再接回目标所有权。
5. 无 cache 的 PicoRV32 可省略 cache clean/invalidate，但仍要确认桥接器/写缓冲排序；不能把“volatile 读一次 bias”当作通用屏障。

当前核已确认识别标准FENCE（funct3=000），且无D-cache、非posted写路径；驱动仍需编译器memory clobber/release-acquire防止C重排。无需为本实例编造cache clean，也不能声称FENCE能刷新未来posted bridge。现有 [启动汇编](<../RISCV/start.S>) 使用PicoRV32自定义IRQ指令；WFI/mret/通用特权CSR不是已支持的替代物。迁移其他CPU/profile时重新校验ISA与屏障契约。

### 10.2 错误分层

- 提交错误：未知 opcode/version、保留位非零、非法对象/维度/stride、未接受依赖、错误 seq、可静态判定的地址越界等，返回 BAD_CMD，不发事务。
- 运行时错误：AXI_RRESP、AXI_BRESP、RLAST/长度协议错、ACC_OVERFLOW、BAD_CONTEXT、无进展 WATCHDOG、内部 invariant 错，锁存首错及 engine/seq/tag/address。
- 错误码固定：0 NONE；1 AXI_READ；2 AXI_WRITE；3 AXI_PROTOCOL；4 ACC_OVERFLOW；5 BAD_CONTEXT；6 WATCHDOG；7 INTERNAL。

FAULT 后拒绝新提交，禁止启动新的队首命令。对已发出的事务完成协议性排空；不能撤回已接受 AW，也不能丢弃仍需消费的 R/B 而使总线永久堵塞。失败命令不推进 DONE；不得跳过失败序号继续宣称后续任务成功。

部分 DMA 写可能已经发生，**不保证事务回滚**；驱动应废弃当前层/批次结果。其他引擎已完成的计数可保留用于诊断，但不把它们当作整层成功。

### 10.3 reset、timeout 与安全性

- 正常：QUIESCE→不接受新任务→队列及活动任务完成→所有总线事务排空→RESET。
- 故障：停止发起新命令，已发 burst 排空，待处理队列可在 RESET 时丢弃；此时无活动事务即可 RESET，无需等待永远不能满足的故障后依赖。
- RESET 清队列、计数、上下文、IRQ/错误和窗口配置；SP 数据内容不保证清零，下次 LD/INIT 必须覆盖使用范围。
- watchdog 的“进展”定义为本命令的 AXI 握手或 local/EX 状态有有效前进；只在活动命令上计数。队列依赖等待超时由 CPU deadline 检测。
- 如果外设永不返回R/B，普通软reset无法凭空消除外部在途事务；需升级到interconnect/SoC协调复位并确认不会有旧响应污染新epoch。当前fabric还可能阻塞CPU取指/CSR读，因此CPU deadline只处理CPU仍能前进的等待，不是无响应总线的可靠恢复机制；必须提供不依赖该fabric的硬件watchdog/外部复位。分别复位NPU或仅复位互联都不能当作安全事务取消。

## 11. 当前 Tiny ResNet 的具体映射

### 11.1 逻辑形状

来源：[HWC 推理入口](<../C/resnet/cpu/main_im2col_hwc.c#L381-L439>)。

| 层 | M,K,N | Q1 output tile 数 | 每输出 tile 的 K tile 数 | CPU 操作/注意点 |
|---|---|---:|---:|---|
| Conv1 | 1024,27,16 | 128×2=256 | 4：8/8/8/3 | FINAL 可 ReLU；之后 CPU 2×2 Pool |
| Conv2 | 256,144,16 | 32×2=64 | 18 | FINAL 可 ReLU |
| Conv3 | 256,144,16 | 64 | 18 | FINAL 不 ReLU，保留 signed INT8 边界 |
| FC | 1,16,10 | 1×2=2 | 2 | M 尾 1，第二 N 尾 2；只输出有效十类 |

卷积 CPU im2col 仍须使用 [现有函数](<../C/resnet/cpu/main_im2col_hwc.c#L103-L163>) 的 ky/kx/ic 顺序。Q1 中 Conv2/3 的 B 需要同样的 W[N,K]→B[K,N] 置换；当前首层导出器不会自动提供这些数据。

### 11.2 Conv1 第一个输出 tile

记 m0=0、n0=0，A_sys 为 A[1024,27]，B_sys 为 B[27,16]，bias_sys 为 16 个 INT32，C_sys 为 HWC [1024,16]。

- bias：LD2D，源 `bias_sys+4*n0`，S32，total=1×8、valid=1×8，目标 Bias0；stride=32。
- k0=0/8/16：LD A，源 `A_sys+m0*27+k0`，系统 stride=27，local stride=8，total/valid=8×8；LD B，源 `B_sys+k0*16+n0`，系统 stride=16，local stride=8，total/valid=8×8。
- k0=24：A valid=8×3，B valid=3×8；local total 仍 8×8，分别补 5 列/5 行。源内存无需预先把整矩阵 K 补到 32。
- 第一次 EX：INIT，K_total=27；中间继续宽累加；最后 EX：FINAL，k_valid=3，当前 Conv1 的 multiplier/shift 从 [HWC 数据](<../C/resnet/cpu/test_vector_hwc.h#L32-L33>) 取得；逐变量 debug 时先不融合 ReLU，方便观察 requant 输出。
- ST：从 Y0 写 `C_sys+m0*16+n0`，total/valid=8×8，local stride=8，系统 stride=16；不会覆盖本 tile 以外 8 个输出通道。
- MAC debug：另行 ST_S32 到 debug_sys，系统 stride=16×4；下一次复用 Acc0 必须等该 ST 完成。

这是“CPU 算少量矩形地址/shape，硬件搬完整矩形+补零”的边界，不是 CPU 对每个输入元素发指令。

若从空队列/清零序号开始，下面是一条可直接用作命令模型单测的提交顺序。括号里的 seq 是各自引擎序号，不是全局序号；表中只列必要跨引擎 wait，同引擎前序完成等待由硬件隐式保证。每一行均先 SUBMIT_ACCEPTED 后才能发布下一行的依赖。

| 全局提交次序 | 命令 | 必要依赖 |
|---:|---|---|
| 1 | LD(1)：Bias0 | 无 |
| 2 / 3 | LD(2)：A0 k0；LD(3)：B0 k0 | 无 |
| 4 | EX(1)：INIT Acc0，A0/B0，k_valid=8 | wait_ld=3，同时覆盖 Bias LD(1) |
| 5 / 6 | LD(4)：A1 k8；LD(5)：B1 k8 | 无，可与 EX(1) 重叠 |
| 7 | EX(2)：累加 Acc0，A1/B1，k_valid=8 | wait_ld=5 |
| 8 / 9 | LD(6)：A0 k16；LD(7)：B0 k16 | 各自 wait_ex=1，保护旧 A0/B0 读者 |
| 10 | EX(3)：累加 Acc0，A0/B0，k_valid=8 | wait_ld=7 |
| 11 / 12 | LD(8)：A1 k24；LD(9)：B1 k24，尾零 | 各自 wait_ex=2 |
| 13 | EX(4)：FINAL Acc0→Y0，A1/B1，k_valid=3 | wait_ld=9 |
| 14 | ST(1)：Y0→系统 C 对应 tile | wait_ex=4 |
| 15（可选） | ST(2)：Acc0→系统 MAC debug tile | wait_ex=4 |

下一次写 Y0 必须 wait_st>=1；若发出可选 ST(2)，下一次 INIT Acc0 必须 wait_st>=2。不要让 LD(6) 等未来 EX(3)，否则它依赖的命令尚未提交，既应被 Q1 拒绝，也会形成错误调度。完整软件 scoreboard 可以生成比表中更保守的已接受前序 wait，仍应保证正确。

### 11.3 明确计入命令开销

以无 A/B 跨输出块复用、每输出块加载一次 bias、只存 INT8 输出的朴素映射：

```text
Conv1: 256 output tiles × (1 bias LD + 4×(A LD+B LD+EX) + 1 ST)
     = 3584 commands
描述符 payload = 3584×64B = 229376B = 224KiB
仅 staging+submit = 3584×17 = 60928 次 32-bit MMIO 写
另计 RC/队列/完成状态读；MAC debug 还会增加 256 个 ST
```

此为确定的命令数量，不是测得时延。FIFO 深度 8 不会把这些写次数变少。若直接把全部描述符静态放入固件，还要占 224KiB，可能与当前黄金数据/代码/BSS 争夺 512KiB 系统 SRAM；首版必须流式生成少量命令，不保存整层任务表。

因此性能迭代优先级应由计数决定：

1. 复用已加载的权重/bias、适度增大 macro tile，减少重复搬运；必须结合 SRAM/bank 容量。
2. 固定长度 ring 减少 MMIO 发布开销，但仍有取描述符的流量。
3. 硬件 LOOP_TILE 减少描述符数量/CPU 计算；这是 Gemmini loop unroller 真正值得学的部分。
4. 卷积隐式 im2col 减少 CPU 和显式中间矩阵流量。

不要把 Q1 小块开销直接归罪于 WS、阵列重构或 DMA 带宽。

### 11.4 层间调度与黄金可观察性

- 调通阶段：每层保存 INT32 MAC、requant INT8，再 CPU ReLU/Pool/Add/GAP，完整比较现有 16 项变量；不用黄金结果作为下一层实际输入。
- 性能阶段：允许 FINAL 融合 ReLU，但 debug 模式仍要能获得融合前 requant 结果（可先禁融合并单独跑），不能删除数值边界来换“通过”。
- Pool 后的 identity 要保留至残差 Add；CPU 与 DMA 分配不得覆盖它。
- 每次 CPU 兜底前执行层屏障/可见性处理，兜底后重新发布下一层输入。

## 12. 验证与性能验收

### 12.1 功能/协议验收清单

| 测试 | 必须验证的条件 |
|---|---|
| 提交原子性 | 只写部分 staging 不执行；SUBMIT 后立即改 staging 不污染任务；AW/W 分离不重复入队 |
| 队列满 | 8 项 pending+1 active，FULL 不丢/不重复，不推进 SUBMITTED，CPU 总线不被长期锁住 |
| 配置 | version/保留位/对象类型/非法 seq/未来依赖/越界全部拒绝，无 DMA 副作用 |
| 数据布局 | A[M,K]、B[K,N]、C[M,N]，byte lane、跨 word 对齐，S32 bias 符号一致 |
| 尾部 | M/N/K 分别 1/3/7/8/9/10/16/27/32/144 等；A/B 旧尾数据先填非零再加载，确认清零；ST 周边哨兵不变 |
| 依赖 | RAW、WAR、WAW；LD 不能覆写 EX 正在用的 A/B；Y 和 ACC 不能覆写 ST 正在读的数据 |
| 同引擎次序 | 同址两次 LD 及跨方向依赖，确保“完成后再启动下一条”，不能只检查 issue 顺序 |
| K 累加 | bias 仅加一次；27 分 8/8/8/3；中间越 INT32 但最终回到范围的取消；FINAL 溢出必须失败 |
| 量化 | 负数 floor shift、shift0/31、最大 multiplier、clip[-127,127]、ReLU、Conv3/Add 边界 |
| AXI | 4KiB 前 1/2/3/4B、最大 burst、非对齐 S8、WSTRB；监视器验证实际总线，不只看输出 |
| 背压 | AR/AW/W/R/B 独立随机停顿，片上 bank 冲突、阵列输出满，valid 数据稳定、无饥饿 |
| 错误 | RRESP/BRESP/长度错、watchdog、坏上下文；首错锁存、无假 DONE、部分写被上层废弃 |
| IRQ/reset | 同拍 set/W1C、等待前已完成、多项合并、中断风暴；有在途事务时 reset 不误通过 |
| 数值黄金 | 最终对当前 Tiny 16 个中间/输出数组逐元素一致，分类一致仅是额外检查 |

本规格未实现这些测试；既有 CPU 回归只能作为黄金数据和软件算子参考，不能代替本表。

### 12.2 性能计数定义

PERF 16 个 64-bit 累加计数：

| 索引 | 名称/单位 |
|---|---|
| 0 | 总 elapsed cycles：ENABLE 至 QUIESCE 完成的启用周期 |
| 1/2/3 | LD/EX/ST 活动周期，可重叠，不能直接相加当总周期 |
| 4 | 依赖阻塞周期：任一非空队首因 wait 未达标而不能启动的周期，按 union 计 |
| 5 | SRAM 仲裁阻塞周期：任一客户端因 bank/port 被拒，按 union 计 |
| 6 | AXI 等待周期：活动 DMA 当拍需要总线推进而未成功推进，按 union 计 |
| 7 | SUBMIT_FULL 次数 |
| 8/9 | AXI 读/写实际传输 bytes；写按 WSTRB 计有效 lane，读含对齐扩读 |
| 10 | 有效 MAC 数 `m_valid*n_valid*k_valid` |
| 11 | 执行 MAC 槽位数；无门控固定每 EX 512，有门控仍另报理论 512 槽用于比较 |
| 12/13/14 | 成功完成 LD/EX/ST 命令数 |
| 15 | 预留重构/loop 控制停顿周期，Q1=0 |

双字读取用high-low-high重读法避免撕裂；reset清零。CPU单独记录发布命令、软件im2col/transpose、等待、CPU兜底时间及总层时延。当前实例默认启用64bit cycle计数，可用rdcycle/rdcycleh按high-low-high读取CPU域周期；NPU PERF记录clk域周期。两域频率不同时先换算实际时间，不直接相加。其他profile若关闭counter，再选择平台timer；总线锁死时CPU计数可继续增长不等于CPU还能执行读计数或恢复代码。

必须报告：CPU+NPU 端到端时间、真实频率、访存与命令流量、填充/排空开销、bank 冲突、PE 利用率、LUT/FF/DSP/BRAM。论文 [G7] 提醒 CPU 与 im2col 能显著影响性能，但其具体倍数不能移植为本工程预计收益。

## 13. 演进：何时才值得增加“指令链表”

### Q2-A：固定长度描述符环，而非任意指针链

若 Q1 测得 MMIO 注入为主要瓶颈，可新增独立 capability/ABI：

- 系统 SRAM 内固定 64B 描述符，ring base 64B 对齐，容量 2 的幂，单生产者/单消费者。
- CPU 写槽→必要 clean→release→一次 tail doorbell；硬件 DMA 顺序取描述符→校验→复制进入内部队列→推进 head。
- `head` 表示描述符已被安全复制可覆写，**不表示 DMA/计算任务完成**；源/目标数据仍须保持到 DONE。
- head/tail 使用明确代数/计数避免满空混淆；跨圈和 counter wrap 必须有测试。软件不能改已发布未消费槽。
- 描述符读取和数据 DMA 共用端口时应有公平仲裁，避免命令取数饥饿；解析坏 descriptor/读错误须记录 ring 索引。
- 不支持 next 指针就不需要任意链表遍历、防环/指针追踪；若后续真要 scatter/gather，再单独立 spec。

ring、内部 FIFO、硬件 loop 可以共存。ring 是发布机制，FIFO 是有限缓冲，loop 是压缩规则性任务生成；三者不互相替代。

### Q2-B：受限硬件循环展开

先做固定 `LOOP_GEMM`：软件给 M/N/K、基址/stride、选定 tile/mode、local 配额；硬件做规律地址递增和重复 LD/EX/ST、双缓冲，软件仍选分块和复用策略。必须保留可导出的底层命令 trace，能与 Q1 软件计划逐项比较。

是否先做 ring 或 loop，由“CPU 生成命令”和“MMIO 发布”分别占多少时间决定；不能只因环听起来更像工业 DMA 就先做。

### Q2-C：隐式 im2col 与写回 Pool

隐式 im2col 必须额外定义 H/W/C、KH/KW、stride、dilation、padding、输出坐标到输入坐标、边界零、IC 尾部，以及行缓存覆盖/复用生命周期；一般 2D DMA 不能代替它。

Pool 初版建议只支持已 requant/ReLU 的 NHWC 2×2、stride2、无 padding；先要求完整窗口在片上可访问，不跨不完整 tile。必须定义跨行/跨 tile 保留、有效通道、输出 stride、INT8 signed 比较；不能对未 requant 的 ACC 直接池化却声称等价。若先支持 signed padding，应使用正确的最大值单位元，而非默认 0。

### Q3：固定 PE 预算的可重构阵列

沿用 [研究方向](<../paper.md#L39-L48>)：固定 256 PE，比较固定 16×16、四独立 8×8、有限组合模式。WS 的物理空间映射主要是 K/N，M 是流过的行；不得把 OS 的 M/N 利用率公式直接用于 WS。

扩展时增加带 capability 的 mode/subarray 标识；在所有相关 LD/EX/ST 和跨子阵列数据排空后切换，不能在活跃命令中变更全局路由。每种模式重新定义 tile 容量、端口带宽、流水延迟和依赖资源。Q1 固定对象地址/物理8×8不是未来多模式的无版本 ABI 承诺。

## 14. 推荐里程碑与待确认项

### 14.1 先做 P0：现有硬件契约收口，不急着换阵列

| 优先级 | 改造/验证门槛 | 验收条件 |
|---|---|---|
| P0-1 | 明确FPGA/VCS全局宏、顶层参数、PE权重深度、firmware布局 | 记录预处理profile和硬件/软件commit；不把磁盘`define`当已部署版本 |
| P0-2 | CSR完整4KiB精确译码、canonical旧窗口兼容 | `+0x100/0x200/0x300`不再碰旧CTRL；新ID只读探测；非法strobe/size无副作用且可诊断 |
| P0-3 | start/mode lock、active配置快照 | busy期间start/改活跃配置不能重置任一DMA握手或改变当前任务 |
| P0-4 | 输出credit/headroom、overflow诊断、真实完成计数 | worst-case背压不丢结果，短drain不产生假DONE；最终写响应完成并核验错误 |
| P0-5 | R/B错误、beat/RLAST检查、范围与正计数校验 | zero count/越界不能被发到总线；错误不假成功；卡死有out-of-band恢复 |
| P0-6 | IRQ4同步及计数式驱动 | clk→clk_pico CDC通过检查；重复/合并IRQ不影响任务正确性 |
| P0-7 | 宽位PPU修复、32bit部分和溢出策略 | 覆盖第1.7节反例；只对已证明无中间溢出的legacy数值范围开放执行 |

这些门槛可按依赖逐步开发/验证，不要求一次改完才观察现有行为；但没有完成前，不能宣称Q0/Q1已具备可靠异步托管能力。

### 14.2 Q0：以完整 legacy 任务为粒度的低改造队列

**这是当前硬件最直接的“CPU准备任务表、硬件顺序跑”的实现，不需要先设计Gemmini式SP/ACC。** 每项任务相当于现有“一组输出通道的一次完整Conv启动”，不是一个AXI burst，也不是一个K子块。

建议先写软件参考任务数组/串行解释器，再为同样格式加硬件FIFO。Q0与Q1是不同ABI，不能把同一64B结构按另一套payload解释。

建议Q0任务64B格式：

| word | 字段 |
|---|---|
| 0 | opcode=0x80 LEGACY_RUN[7:0]；flags[15:8]只允许bit0 IRQ_ON_DONE；format=1[23:16]；高8bit=0 |
| 1 | user_tag，不是软件指定seq |
| 2..5 | ACT_BASE、WEIGHT_BASE、BIAS_BASE、OUT_BASE |
| 6..11 | IMG_DIM、MEM_CNT、DATAPATH、SPATIAL、QUANT、POST，按第1.4节canonical字段 |
| 12..15 | 必须为0，保留 |

硬件SUBMIT_ACCEPTED时分配单一单调ticket，8项pending FIFO+1项active；active副本/寄存器bank锁定直到整任务完成，CPU只能改staging。FIFO按序跑，下一项只在前项所有结果/读写事务排空后启动。这样跨任务依赖保守地由总顺序保证，不需要三个wait字段或地址范围ROB；CPU兜底算子仍须等待对应ticket。

建议独立保留Q0控制窗口`+0x300..+0x3FF`（**现有也会镜像，P0-2之前禁止写**）：ID=`0x4E504C30`（NPL0）放`+0x300`，VERSION=`+0x304`，STATUS=`+0x308`，SUBMIT/RC=`+0x310/+0x314`，SUBMITTED/DONE=`+0x318/+0x31C`，staging16字=`+0x340..+0x37C`。这是迁移接口草案，IRQ、错误、窗口保护、复位寄存器的完整编码须在Q0实现前单独冻结；不得猜测它就是Q1窗口移位版。未冻结/实现就不生成可运行驱动。

Q0至少遵守Q1相同的原子快照、FULL重试、无假完成、故障停止、序号不绕回、安全排空与可读错误原则；只是不提供独立LD/EX/ST、local矩阵地址、ACC48或跨K保留。FIFO不减少发布字数：每任务仍16字+SUBMIT，比旧10个配置字+START甚至更多；收益在减少CPU逐项等待/ISR及允许提前托管，实际受CDC和阻塞fabric影响。

建议第一批只开放受限legacy profile（仍须通过RTL验收后才成为支持契约）：

- FPGA条件配置为64×8、PE深度9；3×3、stride1、pad1；H=2..32，W=1..32；更一般形状/FC/1×1先不开放。提交校验必须逐字段强制`kernel_kx_max=2`、`kernel_ky_max=2`、`pad=1`、`kernel_ky_skew=0`，而不只是接受软件口头声明3×3。
- IC=1..64，软件补齐到`4*ceil(IC/4)`；`WRITE_GROUP_LAST=ceil(IC/4)-1`；64行输出切片的`READ_GROUP_LAST=0`；`sa_weight_num=9`，`line_width=W+2`。raw配置必须与这些派生值和word count精确一致；SPATIAL[7:6]、POST[11:6]及任务保留位必须为0，未知编码/不匹配立即拒绝，不能让它们进入active bank。
- OC只能4或8，且不超过物理列数；启用所有使用列对应的四列门控组；输出基址和stride均4B对齐，stride>=OC且可表示为9bit。
- row_word_count=`W*ceil(IC/4)`；weight_word_count=`9*ceil(IC/4)*OC`；bias为OC个INT32；输入/权重、bias、输出覆盖范围用宽地址运算检查在SRAM数据分配范围内，禁止指向CSR/UART。
- multiplier范围1..65535、zp=0、shift0..31，且通过第8节所要求的无中间溢出/宽位饱和检查；保留ReLU开关。FIFO阈值和drain必须来自该profile的时序/credit证明，不能只给一个经验常量。

暂不开放H=1有具体依据：当前预热 [无条件请求第二行](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/npu_axi_wrapper_burst.v#L940-L960>)，后面的H!=1条件没有保护第一次预取；未修复前可能多读整行。row_word_count=0还可能让burst长度减一为255，不是安全空操作。这里只缩小Q0入口，不把这些旧行为合理化为通用DMA语义。

**Tiny首层用Q0的例子：** IC=3 pad至4，H=W=32，OC_total=16，以8通道分两项任务；共享ACT，第二项WEIGHT基址加`9*1*8*4=288B`、BIAS加32B、OUT加8B，输出像素stride=16B，每项权重72words、每行输入32words。两项均做完整K=27卷积（内部有IC填充），不是两项K分块；不需CPU生成显式A矩阵，但必须使用legacy packed权重。Q0任务表仅两项，与Q1第11节3584个微命令的粒度完全不同，不能直接用它们的命令数量比较阵列优劣。

Q0不自动导出INT32 MAC：旧数据通路只把PPU后INT8送入输出FIFO。若验收仍要求全部16项黄金可观察，需另加受控debug trace/读出或TB逐项观察接口；仅最终INT8输出一致不能冒充16项检查通过。

### 14.3 研究路线Q1：确认需要解耦后再做

1. **M0软件命令模型**：针对当前首层A/B，生成Q1命令，模拟LD/EX/ST/local SRAM/依赖，计算命令/带宽开销。
2. **M1协议壳**：在P0完整译码和模式锁之上加Q1 staging/FIFO/seq/DONE，模拟随机执行延迟。
3. **M2新DMA与local SRAM**：复用/重构现有burst切片与写响应握手，新增byte aligner、二维shape、合法性、错误、对象地址及bank仲裁，不能直接连旧line buffer就宣称完成。
4. **M3单8×8 WS+宽ACC**：新矩阵馈送和持久部分和，验证跨K累加、bias一次、FINAL位宽和首层INT32/INT8黄金。旧64×8 PE链的valid/skew和psum语义需重新推导，不能只修改SYS_ROWS/COLS参数。
5. **M4 Tiny全网络**：Conv/FC Q1，其他CPU兜底，16项黄金逐元素一致。
6. **M5性能裁决**：以CPU/NPU真实时钟、fabric串行、命令发布和布局转换的实测瓶颈决定ring/loop/隐式im2col；最后扩到固定PE预算四子阵列对比。

### 14.4 已确认与仍待确认

已确认：外部工作树与HEAD差异、CSR字段/镜像、32bit AXI、512KiB映射、现有数据FIFO深度、无D-cache/非posted写通路、IRQ4/自定义IRQ ISA/FENCE和cycle计数、单事务fabric及旧DMA完成位置。

仍待确认/测量：完整工程统一宏和实际部署bitstream、综合后BRAM/端口实现、现有profile的全套动态正确性、不可停顿在途输出上界、safe阈值/drain、CDC约束/复位恢复、真实频率与布局/PPA、错误注入和所有AXI边界。原有 [SRAM SIM_CHECKS](<A:/file/Projects/VScode/Verilog/picorv32_npu/npu_rtl/axi_dp_sram_hybrid.v#L491-L594>) 多为`$display`告警，响应码仍恒OKAY；必须增加有失败退出/断言的协议监视器及可注入错误的target，不能靠当前SRAM模型证明所有错误路径。

## 15. 来源、版本与阅读索引

官方 Gemmini 硬件 master 在检索时解析为 **`8c3f9923a44a2fe2c7930587be297d6d4f8c09ca`**；以下代码链接固定该提交。其软件子模块 `gemmini-rocc-tests` 固定为 **`7c540b3adf1b86ad93d07f893abe3a73489b568e`**。不同论文/分支/生成参数可不同，Q1 的字段、地址、容量、队列深度均是本提案，不是 Gemmini ISA 摘抄。

- **[G1]** [Gemmini 官方 README](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/README.md>)：DAE 第184–196行；scratchpad/accumulator 第198–225行；DMA 第269–282行；ROB 第284–291行；loop unroller 第293–304行；mvin contexts 第411–414行；pool 第481–494行；loop容量/外层tile 第583–608行。
- **[G2]** [Controller.scala](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/src/main/scala/gemmini/Controller.scala#L230-L269>)：命令/loop/RS 连接；[控制器发射连接](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/src/main/scala/gemmini/Controller.scala#L346-L368>)。
- **[G3]** [ReservationStation.scala](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/src/main/scala/gemmini/ReservationStation.scala#L68-L112>)：地址范围、依赖向量；第327–378行依赖建立、第491–515行完成解除。应对照内部控制器，不把它视为通用 CPU 乱序 ROB。
- **[G4]** [LoadController.scala](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/src/main/scala/gemmini/LoadController.scala#L33-L70>)：多套配置和同一个命令/请求路径；第94–127行命令跟踪及完成。
- **[G5]** [LoopMatmul.scala](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/src/main/scala/gemmini/LoopMatmul.scala>) 与 [软件 gemmini.h](<https://github.com/ucb-bar/gemmini-rocc-tests/blob/7c540b3adf1b86ad93d07f893abe3a73489b568e/include/gemmini.h#L366-L374>)：软件宏发配置/LOOP_WS，硬件展开；并非所有底层 mvin/compute 都由该宏内 CPU 循环逐条生成。
- **[G6]** [StoreController.scala](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/src/main/scala/gemmini/StoreController.scala#L225-L226>)：pool/一维 mvout 与多 block 的组合限制；[README pool 说明](<https://github.com/ucb-bar/gemmini/blob/8c3f9923a44a2fe2c7930587be297d6d4f8c09ca/README.md#L481-L494>) 标明 experimental/NHWC，不能推广成任意卷积 tile 零成本池化。
- **[G7]** [Gemmini 论文，arXiv:1911.09925v3，2021-07-09](<https://arxiv.org/html/1911.09925>)：III-A 存储和两级阵列，III-B 运行时 tile/参数生成，IV-B CPU与硬件 im2col 的权衡，V 存储/系统资源影响。引用具体结果须保留其平台条件。
- **[G8]** [Chipyard Gemmini 文档](<https://chipyard.readthedocs.io/en/latest/generators/gemmini/>)：完整系统/软件联合探索定位。

最终原则：**CPU 负责“选什么、放哪里、何时可复用”；命令接口负责“原子发布、排队、依赖与完成”；DMA 负责“把明确的数据矩形可靠搬到位”；EX 负责“按数值契约算完”。是否把重复循环、滑窗或池化再下沉，交给测量结果，而不是架构口号。**
