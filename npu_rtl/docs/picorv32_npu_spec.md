# PicoRV32 + NPU 异构处理器 Spec

版本：v0.1  
目标工程：PicoRV32 + 32-bit NPU 异构 SoC  
CPU 选择：PicoRV32 RISC-V Core  
仿真环境：VS Code + Icarus Verilog  
设计目标：完成基于 AXI 总线的 CPU/NPU 协同计算平台，支持 INT8 矩阵/卷积加速、AXI-Lite 寄存器配置、AXI Burst/DMA 数据搬运、低功耗控制和可量化性能测试。

## 1. 设计范围

本设计实现一个面向边缘 AI 推理的低功耗异构处理器，由 PicoRV32 CPU 负责系统控制、任务调度和异常处理，由 NPU 负责 INT8 矩阵乘法/卷积类密集计算。CPU 与 NPU 通过片上 AXI 互连通信，NPU 可通过 DMA/AXI Master 从共享 SRAM 中读取输入、权重并写回输出，实现零拷贝数据交互。

本 spec 覆盖以下内容：

- 顶层 SoC 架构
- PicoRV32 CPU 配置
- AXI 总线与地址空间规划
- NPU 计算阵列、寄存器、DMA 和数据格式
- 低功耗设计
- 软件编程模型
- RTL 验证、性能测试和输出物要求

## 2. 顶层指标

### 2.1 基础指标

| 项目 | 指标 |
| --- | --- |
| CPU | PicoRV32，RV32IMC 推荐配置 |
| NPU 数据位宽 | INT8 输入/权重，INT32 累加，INT8/INT32 输出可选 |
| 基本阵列 | 4x4 systolic array tile |
| CPU/NPU 通信 | AXI4-Lite 寄存器配置，AXI4 Burst 数据搬运 |
| 共享存储 | 片上 SRAM，CPU 与 NPU 可共同访问 |
| 基本任务 | CPU 配置任务，NPU 执行矩阵/卷积计算 |
| AXI Burst | 支持 INCR 地址递增模式 |
| 低功耗 | NPU 空闲时关闭阵列时钟 |
| 验证 | RTL 仿真，功能覆盖目标不低于 95% |

### 2.2 优化指标

| 项目 | 目标 |
| --- | --- |
| NPU 峰值算力 | 基础目标不低于 0.5 TOPS@INT8，优化目标接近或超过 1 TOPS@INT8 |
| 总线带宽利用率 | Burst 场景基础目标不低于 60%，优化目标不低于 80% |
| DMA | 集成独立 DMA 或 NPU 内部 AXI Master DMA |
| 阵列扩展 | 支持参数化多 4x4 tile 复制，或动态可调阵列 |
| 互连 | AXI 共享总线，支持 CPU、NPU/DMA 多主设备访问 |
| 低功耗增强 | 支持时钟门控，预留 DFS/电源门控接口 |
| FPGA 验证 | 作为加分项，完成板级运行和性能记录 |

### 2.3 算力说明

单个 4x4 INT8 脉动阵列每周期包含 16 个 MAC。按 1 MAC = 2 OPS 计算：

```text
Peak_OPS = TILE_NUM * 16 MAC/cycle * 2 OPS/MAC * Freq
```

示例：

| 配置 | 频率 | 峰值算力 |
| --- | --- | --- |
| 1 个 4x4 tile | 100 MHz | 3.2 GOPS |
| 1 个 4x4 tile | 200 MHz | 6.4 GOPS |
| 80 个 4x4 tile | 200 MHz | 512 GOPS，约 0.512 TOPS |
| 157 个 4x4 tile | 200 MHz | 1.0048 TOPS |

因此，本设计将 4x4 阵列定义为基础 tile。RTL 原型可先实现单 tile，性能优化版本通过 `NPU_TILE_NUM` 参数扩展 tile 数量，并在设计报告中分别给出单 tile 实测指标和多 tile 估算/综合指标。

## 3. 系统架构

### 3.1 顶层模块建议

顶层模块建议命名为 `picorv32_npu_soc`。

```text
+-------------------------------------------------------------+
|                      picorv32_npu_soc                       |
|                                                             |
|  +----------------+       +-----------------------------+   |
|  | PicoRV32 CPU   |       | NPU / DMA AXI Master        |   |
|  | AXI4-Lite M0   |       | AXI4 Burst M1               |   |
|  +-------+--------+       +-------------+---------------+   |
|          |                              |                   |
|          +--------------+---------------+                   |
|                         |                                   |
|                  +------v------+                            |
|                  | AXI Interconnect                         |
|                  | arbitration / decode                     |
|                  +--+--------+----+                         |
|                     |        |                              |
|             +-------v+   +---v----------+                   |
|             | SRAM   |   | NPU Reg Bank |                   |
|             | AXI S0 |   | AXI-Lite S1  |                   |
|             +--------+   +-------+------+                   |
|                              |                              |
|                      +-------v------+                       |
|                      | NPU Core     |                       |
|                      | 4x4 tile(s)  |                       |
|                      +--------------+                       |
+-------------------------------------------------------------+
```

### 3.2 模块划分

| 模块 | 功能 |
| --- | --- |
| `picorv32_axi` | CPU 主核，使用 AXI4-Lite master 接口访问指令、数据和外设 |
| `axi_interconnect` | AXI 主从互连，完成地址译码、仲裁、通道转接 |
| `axi_sram` | 共享片上 SRAM，存放程序、输入、权重、输出 |
| `npu_regbank` | NPU 配置/状态寄存器，从设备接口为 AXI4-Lite |
| `npu_dma` | NPU 数据搬运单元，主设备接口为 AXI4 Burst |
| `npu_core` | NPU 控制器、line buffer、脉动阵列和后处理 |
| `sa_4_4` | 4x4 INT8 systolic array tile |
| `pe` | 单个处理单元，完成 INT8 乘法和 INT32 累加 |
| `npu_line_buffer` | 卷积输入行缓存和 padding 处理 |
| `clock_gate` | NPU 阵列时钟门控单元 |

## 4. CPU 规格

### 4.1 CPU 配置

使用 PicoRV32 的 `picorv32_axi` 版本作为 CPU，推荐参数如下：

| 参数 | 推荐值 | 说明 |
| --- | --- | --- |
| `COMPRESSED_ISA` | 1 | 支持 RV32C，提高代码密度 |
| `ENABLE_FAST_MUL` | 1 | 支持快速乘法 |
| `ENABLE_DIV` | 1 | 支持除法 |
| `ENABLE_IRQ` | 1 | 推荐打开中断，用于 NPU done/err |
| `PROGADDR_RESET` | `0x0000_0000` | 复位后从 SRAM 起始地址取指 |
| `STACKADDR` | SRAM 顶部 | 软件栈地址 |

### 4.2 CPU 职责

CPU 负责：

- 初始化 SRAM 中的输入、权重和输出缓冲区
- 配置 NPU 寄存器
- 启动 NPU/DMA 任务
- 轮询或中断等待 NPU 完成
- 校验输出或执行后续控制逻辑
- 处理异常、超时、性能计数读取

CPU 不负责逐元素搬运 NPU 数据，避免破坏零拷贝和带宽利用率目标。

## 5. 地址空间

建议地址空间如下。

| 地址范围 | 目标 | 说明 |
| --- | --- | --- |
| `0x0000_0000` - `0x000F_FFFF` | SRAM | 程序、数据、输入、权重、输出 |
| `0x0010_0000` - `0x0010_0FFF` | NPU Reg Bank | NPU 控制和状态寄存器 |
| `0x0011_0000` - `0x0011_0FFF` | DMA Reg Bank | 若 DMA 独立于 NPU，则放置 DMA 寄存器 |
| `0x0012_0000` - `0x0012_0FFF` | Timer/Perf | 性能计数器和系统计时器 |
| `0x000E_0000` | UART sim port | 仿真打印端口，可选 |

SRAM 内部建议布局：

| 区域 | 起始地址 | 说明 |
| --- | --- | --- |
| `.text/.rodata` | `0x0000_0000` | 固件 |
| `.data/.bss` | 链接脚本指定 | 普通数据 |
| stack | SRAM 顶部向下 | CPU 栈 |
| input buffer | 4KB 对齐 | NPU 输入 |
| weight buffer | 4KB 对齐 | NPU 权重 |
| output buffer | 4KB 对齐 | NPU 输出 |

## 6. AXI 总线规格

### 6.1 CPU AXI4-Lite Master

PicoRV32 使用 AXI4-Lite master 接口访问 SRAM 和寄存器空间。CPU 访问特性：

- 单拍读写
- 32-bit 数据宽度
- 4-bit 字节写使能
- 不产生 Burst
- 所有外设必须支持 AXI-Lite 基本握手

### 6.2 NPU/DMA AXI4 Master

NPU/DMA 使用 AXI4 Burst master 接口访问 SRAM。推荐规格：

| 信号/属性 | 规格 |
| --- | --- |
| 数据宽度 | 32-bit 基础版，64/128-bit 优化版可选 |
| 地址宽度 | 32-bit |
| Burst 类型 | INCR |
| Burst 长度 | 1、4、8、16 beats 可配置 |
| 对齐要求 | 起始地址按数据宽度对齐 |
| 读写通道 | 支持独立 AR/R、AW/W/B 通道 |
| 响应 | 处理 OKAY，检测 SLVERR/DECERR |

### 6.3 AXI Interconnect

互连支持至少两个 master：

- M0：PicoRV32 AXI4-Lite master
- M1：NPU/DMA AXI4 master

支持至少两个 slave：

- S0：共享 SRAM
- S1：NPU Reg Bank

仲裁策略：

- 基础版：固定优先级，CPU 配置访问优先，NPU Burst 在 SRAM 区域连续执行
- 优化版：round-robin 或带 QoS 的仲裁，降低 CPU starvation 风险
- NPU Burst 不应阻塞 CPU 对 NPU 状态寄存器的访问

### 6.4 带宽利用率定义

```text
Bandwidth_Utilization = Valid_Data_Beats / Total_Bus_Cycles
```

统计范围为 NPU/DMA Burst 传输阶段，不包含 CPU 配置阶段。RTL 中应设置性能计数器：

- `axi_active_cycles`
- `axi_read_beats`
- `axi_write_beats`
- `axi_stall_cycles`
- `axi_burst_count`

## 7. NPU 寄存器规格

NPU 寄存器基地址：`NPU_BASE = 0x0010_0000`。

| Offset | 名称 | R/W | 说明 |
| --- | --- | --- | --- |
| `0x00` | `NPU_CTRL` | R/W | bit0 start，bit1 soft_reset，bit2 irq_en，bit3 clock_gate_en，bit4 dfs_en |
| `0x04` | `NPU_STATUS` | R | bit0 busy，bit1 done，bit2 error，bit3 irq_pending |
| `0x08` | `NPU_INT_CLR` | W | 写 1 清除 done/irq/error |
| `0x0C` | `NPU_CFG` | R/W | bit[1:0] op_type，bit[3:2] out_mode，bit[7:4] tile_num_log2 |
| `0x10` | `SRC_ACT_BASE` | R/W | 输入 feature map 基地址 |
| `0x14` | `SRC_WEIGHT_BASE` | R/W | 权重基地址 |
| `0x18` | `SRC_BIAS_BASE` | R/W | bias 基地址，可选 |
| `0x1C` | `DST_OUT_BASE` | R/W | 输出基地址 |
| `0x20` | `M_DIM` | R/W | 矩阵 M 或输出高度 |
| `0x24` | `N_DIM` | R/W | 矩阵 N 或输出宽度 |
| `0x28` | `K_DIM` | R/W | 矩阵 K 或卷积通道/核展开长度 |
| `0x2C` | `IMG_CFG` | R/W | bit[15:0] img_w，bit[31:16] img_h |
| `0x30` | `KERNEL_CFG` | R/W | kernel_w/kernel_h/stride/pad |
| `0x34` | `QUANT_CFG` | R/W | scale/shift/relu/saturation 配置 |
| `0x38` | `BURST_CFG` | R/W | burst_len、outstanding、data_width |
| `0x3C` | `ERR_CODE` | R | 错误类型 |
| `0x40` | `CYCLE_CNT` | R | NPU 任务周期计数 |
| `0x44` | `MAC_CNT` | R | 完成 MAC 数 |
| `0x48` | `AXI_ACTIVE_CNT` | R | AXI 活跃周期 |
| `0x4C` | `AXI_BEAT_CNT` | R | AXI 有效 beat 数 |

`NPU_CTRL.start` 写 1 后由硬件自清零。`NPU_STATUS.done` 在任务完成后置 1，软件写 `NPU_INT_CLR` 清除。

## 8. NPU 计算规格

### 8.1 数据格式

| 数据 | 格式 | 说明 |
| --- | --- | --- |
| activation | signed INT8 | 4 个元素打包为 32-bit |
| weight | signed INT8 | 4 个元素打包为 32-bit |
| bias | signed INT32 | 每输出通道一个 bias |
| psum | signed INT32 | PE 内部累加 |
| output | signed INT8 或 INT32 | 默认 INT8，支持饱和/截断 |

32-bit word 打包格式：

```text
word[ 7: 0] = element0
word[15: 8] = element1
word[23:16] = element2
word[31:24] = element3
```

### 8.2 支持操作

基础版支持：

- `op_type = 0`：矩阵乘法，`C[M,N] = A[M,K] * B[K,N]`
- `op_type = 1`：3x3 depthwise/pointwise 简化卷积，使用 line buffer 输入

优化版支持：

- 多 tile 并行 GEMM
- im2col + GEMM 卷积
- ReLU、饱和量化、右移缩放
- 动态 tile mask

### 8.3 4x4 脉动阵列 tile

每个 tile 包含 16 个 PE，按 4 行 4 列连接。基础接口与现有 `sa_4_4` 保持一致：

| 信号 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `clk` | input | 1 | tile 时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `weight_en` | input | 1 | 1 表示权重装载，0 表示计算 |
| `left_act_in` | input | 32 | 4 行 activation 输入 |
| `top_weight_in` | input | 128 | 4 列权重输入 |
| `top_bias_in` | input | 128 | 4 列 bias/psum 初始值 |
| `bottom_psum_out` | output | 128 | 4 列 INT32 输出 |

### 8.4 PE 规格

每个 PE 完成：

```text
if weight_en:
    weight <= psum_in[7:0]
    psum_out <= shift_to_next_weight
else:
    psum_out <= psum_in + act_in * weight
    act_out <= act_in
```

PE 乘法输入为 signed INT8，累加输出为 signed INT32。PE 对外接口保持 bit vector，内部显式 signed 转换。

### 8.5 数据流

基础数据流采用 output-stationary / weight-stationary 混合方式：

- 权重先通过 `weight_en` 波前写入各 PE
- activation 从阵列左侧逐拍输入并向右流动
- psum/bias 从阵列顶部输入并向下流动
- 最后一行输出最终部分和

卷积模式中，`npu_line_buffer` 维护 3 行输入，自动生成左右/上下 zero padding。控制器按 `kernel_kx/kernel_ky` 提取窗口像素并送入阵列。

## 9. DMA 规格

DMA 可作为 `npu_dma` 独立模块，也可集成在 NPU 控制器中。为了满足赛题 DMA 加分项，推荐形成独立模块边界。

### 9.1 DMA 功能

- 从 SRAM 读取 activation block
- 从 SRAM 读取 weight block
- 读取 bias，可选
- 写回 output block
- 支持 AXI Burst INCR
- 支持地址自增、长度计数和完成中断

### 9.2 DMA 通道

基础版：

- 1 个读通道，activation/weight 分时读取
- 1 个写通道，输出写回

优化版：

- activation read channel
- weight read channel
- output write channel
- ping-pong buffer 隐藏访存延迟

### 9.3 DMA 错误处理

DMA 检测以下错误：

- 地址未对齐
- Burst 跨越非法地址区
- AXI 响应错误
- 任务运行中重复 start
- 配置维度为 0

错误写入 `ERR_CODE`，置位 `NPU_STATUS.error`。

## 10. 低功耗规格

### 10.1 时钟门控

NPU 阵列时钟 `npu_array_clk` 由系统时钟门控生成。

门控条件：

```text
array_clk_en = npu_busy && (state == LOAD_WEIGHT || state == COMPUTE || state == DRAIN)
```

当 NPU idle 或 DMA 单纯搬运且阵列不工作时，关闭 PE 阵列时钟。

### 10.2 DFS 预留

优化版预留 DFS 控制接口：

- `dfs_en`
- `dfs_freq_sel`
- `dfs_ack`

RTL 仿真中可通过 clock enable 模拟低频工作；FPGA/ASIC 实现中再接 PLL/MMCM 或时钟分频器。

### 10.3 功耗统计

RTL 中至少统计：

- NPU busy cycles
- array active cycles
- array gated cycles
- DMA active cycles

设计报告中比较：

- CPU-only 矩阵计算周期
- CPU+NPU 周期
- NPU 时钟门控开启/关闭下的活动周期比例

## 11. 软件编程模型

### 11.1 启动流程

```c
npu_write(SRC_ACT_BASE, act_addr);
npu_write(SRC_WEIGHT_BASE, weight_addr);
npu_write(SRC_BIAS_BASE, bias_addr);
npu_write(DST_OUT_BASE, out_addr);
npu_write(M_DIM, m);
npu_write(N_DIM, n);
npu_write(K_DIM, k);
npu_write(BURST_CFG, burst_cfg);
npu_write(NPU_CTRL, START | IRQ_EN | CLOCK_GATE_EN);

while (!(npu_read(NPU_STATUS) & DONE)) {
    /* wait or sleep */
}

npu_write(NPU_INT_CLR, DONE | IRQ_PENDING);
```

### 11.2 固件要求

固件需提供：

- `npu_init()`
- `npu_start_gemm()`
- `npu_start_conv3x3()`
- `npu_wait_done()`
- `npu_get_perf()`
- `cpu_reference_gemm()` 或 `cpu_reference_conv()`
- 输出比对函数

## 12. 验证规格

### 12.1 单元测试

| 测试对象 | 用例 |
| --- | --- |
| `pe` | signed INT8 正负乘法、累加溢出边界、复位 |
| `sa_4_4` | 权重装载、4x4 矩阵乘、bias 输入、流水线排空 |
| `npu_line_buffer` | 左右 padding、顶部 padding、底部 padding、窗口移动 |
| `axi_sram` | 字节写使能、读写交错、边界地址 |
| `npu_regbank` | 寄存器读写、自清 start、done/error 清除 |
| `npu_dma` | 单 beat、4/8/16 beat burst、地址递增、错误响应 |

### 12.2 集成测试

| 用例 | 目标 |
| --- | --- |
| CPU boot | PicoRV32 从 SRAM 启动并打印 hello |
| CPU 配置 NPU | CPU 写寄存器启动 NPU |
| GEMM 小矩阵 | 4x4、8x8、非 4 对齐尺寸 |
| Conv 3x3 | padding、stride 1、不同图像宽高 |
| AXI Burst | 连续地址递增读写，校验数据完整性 |
| DMA 并发 | CPU 轮询寄存器时 NPU 访问 SRAM |
| 错误注入 | 非法地址、未对齐地址、重复 start |
| 低功耗 | idle 时 array clock 不翻转 |

### 12.3 覆盖率目标

功能覆盖：

- NPU FSM 所有状态
- AXI 读/写通道握手组合
- Burst 长度 1/4/8/16
- start/done/error/irq 路径
- padding 边界
- signed 乘法正负组合
- 量化饱和上下界

代码覆盖：

- line coverage >= 95%
- branch coverage >= 90%
- FSM state coverage = 100%

### 12.4 仿真命令建议

基础仿真使用 Icarus Verilog：

```sh
iverilog -g2012 -o sim_npu \
  npu_rtl/tb_npu_core.v \
  npu_rtl/pe.v \
  npu_rtl/sa_4_4.v \
  npu_rtl/npu_line_buffer.v

vvp sim_npu
```

SoC 集成仿真：

```sh
iverilog -g2012 -o sim_soc \
  npu_rtl/tb_picorv32.v \
  picorv32.v \
  npu_rtl/axi_sram.v

vvp sim_soc
```

最终工程应补充带 AXI interconnect、NPU regbank、DMA、NPU core 的完整 SoC testbench。

## 13. 性能测试规格

### 13.1 必测指标

- NPU 任务总周期
- NPU MAC 数
- 峰值算力
- 有效算力
- AXI Burst 带宽利用率
- CPU-only 与 CPU+NPU 加速比
- 时钟门控节省比例

### 13.2 计算公式

```text
Peak_TOPS = TILE_NUM * 16 * 2 * Freq_Hz / 1e12
Effective_TOPS = Actual_MACs * 2 / Task_Time_s / 1e12
Speedup = CPU_Only_Cycles / CPU_NPU_Cycles
AXI_Util = AXI_Valid_Beats / AXI_Active_Cycles
Clock_Gate_Ratio = Array_Gated_Cycles / Total_NPU_Cycles
```

### 13.3 测试集

RTL 阶段：

- 小规模 deterministic matrix
- 随机 INT8 matrix
- 3x3 卷积小图

FPGA/报告阶段：

- MNIST 简化 CNN 第一层或全连接层
- CIFAR-10 可选，若片上资源不足，可只验证关键层 kernel

## 14. FPGA 验证建议

FPGA 验证可采用两级目标：

第一级：

- PicoRV32 可运行固件
- UART 打印测试结果
- SRAM 中输入/输出可比对
- NPU 单 tile 完成 GEMM/conv

第二级：

- DMA Burst 接入 FPGA BRAM/AXI RAM
- 性能计数器可读
- 板上时钟门控/DFS 模式可切换
- 输出 FPGA 资源利用率和最高频率

## 15. 实施里程碑

| 阶段 | 目标 | 产物 |
| --- | --- | --- |
| M1 | 单 PE 和 4x4 阵列正确 | `pe`/`sa_4_4` testbench |
| M2 | NPU core 完成小矩阵/卷积 | `npu_core` 和 golden model 对比 |
| M3 | NPU regbank + CPU 配置 | PicoRV32 固件启动 NPU |
| M4 | AXI interconnect + shared SRAM | CPU/NPU 共享存储访问 |
| M5 | DMA Burst | AXI INCR burst 正确性报告 |
| M6 | 低功耗和性能计数 | clock gating + perf counters |
| M7 | 完整 RTL 仿真报告 | 覆盖率、波形、测试日志 |
| M8 | FPGA 验证，可选 | bitstream、串口日志、资源/频率报告 |

## 16. 与评分项对应关系

| 评分项 | 本设计对应方案 |
| --- | --- |
| 4x4 脉动阵列 | `sa_4_4` + 16 个 `pe` |
| 动态可调阵列 | 优化版通过 tile mask / PE bypass / 参数化 tile 扩展 |
| AXI 共享总线互连 | `axi_interconnect` 支持 CPU 和 NPU/DMA 多主访问 |
| DMA 控制器 | `npu_dma`，AXI Burst INCR |
| 低功耗设计 | NPU array clock gating，DFS 预留 |
| 文档清晰 | 本 spec + RTL 设计文档 + 验证报告 |
| 性能优化 | 多 tile 参数化扩展，Burst 提升带宽利用率 |
| FPGA 加分 | 预留 FPGA 验证流程 |

## 17. 当前仓库映射

当前已有文件可映射到本 spec：

| 文件 | 对应模块 |
| --- | --- |
| `picorv32.v` | `picorv32_axi` CPU |
| `npu_rtl/pe.v` | PE |
| `npu_rtl/sa_4_4.v` | 4x4 systolic array tile |
| `npu_rtl/npu_line_buffer.v` | line buffer |
| `npu_rtl/axi_sram.v` | AXI-Lite SRAM 原型 |
| `npu_rtl/npu_axi_master_lite.v` | NPU 控制器/AXI master 雏形 |
| `npu_rtl/tb_npu_core.v` | NPU 单元测试入口 |
| `npu_rtl/tb_picorv32.v` | PicoRV32 + SRAM 集成测试入口 |

后续需要新增或重构：

- `npu_rtl/picorv32_npu_soc.v`
- `npu_rtl/axi_interconnect.v`
- `npu_rtl/npu_regbank.v`
- `npu_rtl/npu_dma.v`
- `npu_rtl/npu_core.v`
- `firmware/npu_driver.c`
- `firmware/npu_test.c`
- `docs/rtl_design.md`
- `docs/sim_report.md`

## 18. 输出物清单

最终提交建议包含：

- 完整 RTL 源码
- 顶层架构图和模块说明
- 地址映射和寄存器手册
- AXI Burst 传输说明
- NPU 数据流说明
- 低功耗设计说明
- RTL 仿真 testbench
- 仿真日志、波形截图和覆盖率报告
- 性能测试报告
- FPGA 验证报告，可选

