# RISC-V + NPU 异构 SoC 项目

基于 **PicoRV32** RISC-V 处理器与**自研脉动阵列 NPU** 的异构计算 SoC 设计，支持 INT8 量化卷积神经网络推理加速。

---

## 项目概述

本项目在 PicoRV32 (RV32I) 精简 RISC-V 处理器核心基础上，集成了一颗自研的**可配置权重驻留脉动阵列 (Weight-Stationary Systolic Array)** NPU 加速器。系统采用 AXI4-Full 总线互联，CPU 负责任务调度与 NPU 寄存器配置，NPU 作为 AXI Master 直接通过 DMA 方式访问共享 SRAM 完成权重/特征图的高速搬运。

| 特性 | 说明 |
|------|------|
| **处理器核心** | PicoRV32 (RV32I) @ Claire Wolf / YosysHQ |
| **NPU 架构** | 权重驻留脉动阵列 (Weight-Stationary Systolic Array) |
| **FPGA 阵列规模** | 4×4 PE (面向 Xilinx 部署) |
| **仿真阵列规模** | 64×64 PE (验证架构可扩展性) |
| **计算精度** | INT8 激活 × INT8 权重，INT32 累加器 |
| **后处理单元** | 量化乘子 + 移位 + ReLU / INT8 截断 (PPU) |
| **总线协议** | AXI4-Full (支持 Burst 突发传输) |
| **地址空间** | SRAM (1MB)(AXI总线分配了2MB，但编译时与定义的SRAM大小均为1MB) / NPU 配置寄存器 (4KB) / UART (4KB) |
| **仿真环境** | Synopsys VCS + Verdi |
| **FPGA 平台** | Xilinx Vivado |

---

## 目录结构

```
picorv32/
├── picorv32.v                     # PicoRV32 RV32I 处理器核心 (原始开源 IP)
├── npu_rtl/                       # NPU 加速器 RTL 设计
│   ├── pe.v                       #   处理单元 (MAC + 权重 Cow Buffer)
│   ├── sa.v                       #   脉动阵列顶层 (ROWS×COLS PE + 时钟门控)
│   ├── npu_bottom_acc.v           #   阵列底部累加器 (含窗口计数)
│   ├── npu_ppu.v                  #   后处理单元 (量化/ReLU/截断)
│   ├── npu_line_buffer.v          #   行缓冲 + 滑动窗口提取
│   ├── npu_deskew_buffer.v        #   反偏斜缓存 (列对齐)
│   ├── npu_axi_wrapper_burst.v    #   NPU AXI4-Full 封装 (FSM + DMA)
│   ├── act_skew_buffer.v          #   激活偏斜缓冲
│   ├── axi_interconnect.v         #   AXI4 互联矩阵 (Alex Forencich)
│   ├── axi_dp_sram_hybrid.v       #   双端口 AXI SRAM
│   ├── arbiter.v                  #   优先级仲裁器
│   ├── priority_encoder.v         #   优先级编码器
│   ├── npu_sync_fifo.v            #   同步 FIFO
│   ├── my_icg.v                   #   集成时钟门控 (ICG)
│   └── tb_picorv32.v              #   SoC 顶层 Testbench (含 VCS + FPGA 双模式)
├── iVerdi/                        # VCS 仿真与调试
│   ├── Makefile.vcs               #   VCS 编译/仿真/回归测试 Makefile
│   ├── firmware.hex               #   默认固件 HEX 文件
│   ├── novas.conf / novas.rc      #   Verdi 配置文件
│   └── regress/firmwares/         #   回归测试固件集合
│       ├── firmware_byte_cpu_alu.hex       # CPU ALU 正确性
│       ├── firmware_byte_axi_cfg.hex       # AXI 配置寄存器读写
│       ├── firmware_byte_axi_burst_edge.hex# AXI 突发传输边界
│       ├── firmware_byte_math_ones.hex     # 全一张量数学验证
│       ├── firmware_byte_dim_stretch.hex   # 维度拉伸测试
│       ├── firmware_byte_fc_reshape.hex    # 全连接/Reshape 算子
│       ├── firmware_byte_conv_1x1.hex      # 1×1 卷积
│       ├── firmware_byte_bus_stress.hex    # 总线压力测试
│       ├── firmware_byte_quant_bound.hex   # 量化边界饱和
│       ├── firmware_byte_irq_storm.hex     # IRQ 风暴测试
│       ├── firmware_byte_vgg_full.hex      # VGG 风格全网络
│       └── firmware_byte_reg_bounds.hex    # 寄存器边界测试
└── FPGA/
    └── project_riscv_npu.xpr.zip  # Xilinx Vivado 工程打包

```

---

## SoC 架构

```
  ┌─────────────────────┐           ┌──────────────────────────────────┐
  │  PicoRV32 (RV32I)   │           │       NPU AXI Wrapper            │
  │        CPU          │           │                                  │
  │                     │           │  ┌────────────┐ ┌──────────────┐ │
  │  ┌───────────────┐  │  IRQ      │  │ Slave Port │ │  Master Port │ │
  │  │ IRQ(bit5)     │◄─┼───────────┼──│(CPU配置CSR)│ │   (DMA引擎)  │ │
  │  │ ← npu_done    │  │           │  └─────┬──────┘ └──────┬───────┘ │
  │  └───────────────┘  │           │        │ 配置寄存器      │ 读写     │
  │        │            │           └────────┼────────────────┼────────┘
  │   AXI-Lite          │                    │                │
  └────────┼────────────┘                    │                │
           │ M0 (CPU)                        │ S1 (NPU Slave) │ M1 (NPU DMA Master)
           │                                 │                │
  ┌────────▼─────────────────────────────────▼────────────────▼───────┐
  │                       AXI4 Interconnect                           │
  │                   (2 Masters × 3 Slaves)                         │
  │                                                                   │
  │   Masters:  M0 = CPU (取指/数据)    M1 = NPU DMA (读写SRAM)       │
  │   Slaves:   S0 = SRAM    S1 = NPU Slave    S2 = UART              │
  └─┬──────────────────┬────────────────────┬─────────────────────────┘
    │ S0               │ S1                 │ S2
    ▼                  ▼                    ▼
  ┌──────────┐   ┌───────────┐       ┌───────────┐
  │   SRAM   │   │  NPU CFG  │       │   UART    │
  │  (1 MB)  │   │  (4 KB)   │       │  (4 KB)   │
  │0x00000000│   │0x40000000 │       │0x80000000 │
  └────┬─────┘   └───────────┘       └───────────┘
       │
       │  NPU DMA 读写 SRAM (通过 M1 Master Port)
       │
  ┌────▼──────────────────────────────────────────────────────────────┐
  │                        NPU 内部数据通路                            │
  │                                                                    │
  │  DMA读 ──► 权重 ─────────────────────────────┐                    │
  │                                               ▼                    │
  │  DMA读 ──► 激活 ──► Line Buffer ──► ┌──────────────────┐          │
  │                                     │  Systolic Array  │          │
  │                                     │   (ROWS × COLS)  │          │
  │                                     │    PE 阵列        │          │
  │                                     └────────┬─────────┘          │
  │                                              │ Psum (部分和)       │
  │  DMA读 ──► Bias ──────────────────────► ┌────▼────────┐          │
  │                                         │  Bottom Acc │          │
  │                                         │  (列累加器)  │          │
  │                                         └────┬────────┘          │
  │                                              │ Acc结果             │
  │                                         ┌────▼────────┐          │
  │                                         │    PPU      │          │
  │                                         │ (量化/ReLU)  │          │
  │                                         └────┬────────┘          │
  │                                              │ INT8输出            │
  │                                         ┌────▼────────┐          │
  │                           DMA写回 SRAM ◄─│  Deskew     │          │
  │                                         │  Buffer     │          │
  │                                         └─────────────┘          │
  └──────────────────────────────────────────────────────────────────┘
```

### 地址映射

| 地址范围 | 大小 | 外设 |
|----------|------|------|
| `0x0000_0000 - 0x000F_FFFF` | 1 MB | 共享 SRAM (指令 + 数据 + NPU I/O) |
| `0x4000_0000 - 0x4000_0FFF` | 4 KB | NPU 配置寄存器 (AXI Slave) |
| `0x8000_0000 - 0x8000_0FFF` | 4 KB | UART (AXI Uartlite 兼容) |

---

## NPU 微架构

### 处理单元 (PE)

每个 PE 实现一个 INT8 乘加单元，内部包含：

- **权重 Cow Buffer**：可配置深度的局部权重寄存器堆（物理最大条目可自定义，支持权重复用）
- **独立读写指针**：配置阶段 (`weight_en`) 写入权重，计算阶段 (`act_valid`) 读取权重
- **权重合法标志位**：防止未配置权重参与计算
- **数据流**：激活 (`act_in`) 水平向右流动，部分和 (`psum_in`) 垂直向下流动

```
   weight_in (32-bit bus)          act_in (8-bit)
         │                              │
         ▼                              ▼
  ┌──────────────┐              ┌──────────────┐
  │  Weight Cow  │─────────────▶│   INT8 MAC   │
  │  Buffer      │    int8_w    │  (Multiply + │
  │  (max 36)    │              │   Accumulate)│
  └──────────────┘              └──────┬───────┘
                                       │
                                psum_in ▼
                              ┌──────────────┐
                              │  psum_out    │──▶
                              └──────────────┘
```

### 脉动阵列 (SA)

- **物理规格**：`ROWS × COLS`，可参数化扩展
- **FPGA 部署**：4×4（节约资源，适合原型验证）
- **仿真验证**：64×64（验证大阵列时序收敛性）
- **时钟门控**：支持列级门控 (`my_icg`)，按需关闭空闲列，降低动态功耗
- **权重配置**：按行组 (`weight_row_group`) 逐组广播权重

### 累加器 (npu_bottom_acc)

- 每列独立 32-bit 累加器
- 支持偏置预装 (`preload_bias`)
- 内置窗口计数，自动感知卷积窗口结束时刻
- 产生 PPU 触发令牌 (`acc_valid_out`)

### 后处理单元 (npu_ppu)

对累加器输出执行量化推理管线的最后一环：

1. **Stage 1**：部分和 × 量化乘子 (`cfg_multiplier`)，产生 64-bit 积
2. **Stage 2**：算术右移 (`cfg_shift`) + 加输出零点 (`cfg_out_zp`)
3. **Stage 3**：可选的 ReLU 激活 / INT8 对称饱和截断

### 行缓冲 (npu_line_buffer)

- 物理存储深度：128-bit × 34 行（支持最大 32+2 行宽）（4×4规模下）
- 动态配置支持：Padding 宽度、行宽、输入通道组数均可在层切换时软件配置
- 滑动窗口提取：通过 `(kernel_kx, kernel_ky, window_base_x)` 坐标实时输出 3×3 窗口内的任意像素

### 反偏斜缓存 (npu_deskew_buffer)

脉动阵列各列输出存在固有的**梯形延迟**（第 0 列最先输出，最后一列最后输出）。该模块将 N 列流水输出在时间上重新对齐为 `(N×8)-bit` 并行输出，供 AXI DMA 整拍写回。

### AXI 封装 (npu_axi_wrapper_burst)

- 实现 AXI4-Full Slave（CPU 配置 CSR） + AXI4-Full Master（NPU DMA 搬运）双角色
- 内置硬件 FSM 控制完整推理流程：`IDLE → LOAD_BIAS → LOAD_WEIGHT → LOAD_ACTIVATION → COMPUTE → STORE`
- 支持 AXI Burst 传输，最大化 SRAM 带宽利用率
- 提供 `npu_done_level` 中断信号输出

---

## 快速开始
请参考 [快速开始指南](QuickStart.md)

---

## 回归测试固件说明

| 固件文件 | 测试目标 |
|----------|---------|
| `firmware_byte_cpu_alu.hex` | 验证 PicoRV32 基本 ALU 指令正确性 |
| `firmware_byte_axi_cfg.hex` | AXI4-Full 配置寄存器读写验证 |
| `firmware_byte_axi_burst_edge.hex` | AXI 突发传输边界条件测试 |
| `firmware_byte_math_ones.hex` | 全一张量 MAC 运算数学验证 |
| `firmware_byte_dim_stretch.hex` | 非对齐维度上的卷积尺寸拉伸 |
| `firmware_byte_fc_reshape.hex` | 全连接层 / Reshape 算子测试 |
| `firmware_byte_conv_1x1.hex` | 1×1 逐点卷积 (Pointwise) |
| `firmware_byte_bus_stress.hex` | AXI 总线满负载压力测试 |
| `firmware_byte_quant_bound.hex` | INT8 量化正负边界饱和行为 |
| `firmware_byte_irq_storm.hex` | NPU 完成中断响应压力测试 |
| `firmware_byte_vgg_full.hex` | VGG 风格端到端完整推理 |
| `firmware_byte_reg_bounds.hex` | 配置寄存器边界值测试 |

---

## 关键设计特点

1. **权重驻留数据流**：权重在 PE 内局部缓存，激活沿阵列水平传播，部分和垂直累积，最大化数据复用
2. **时钟门控**：列级门控 (`my_icg`)，仅在当前计算需要时启用对应列时钟，显著降低动态功耗
3. **写/读指针分离 + 合法标志位**：PE 内部权重 Buffer 的写指针与读指针完全解耦，配合权重合法标志位防止溢出计算
4. **动态层配置**：行缓冲宽度、IC 通道组数、权重循环数、Padding 等参数均可在不同网络层间由软件动态切换
5. **AXI4-Full 原生支持**：不同于常见 AXI-Lite 简化方案，NPU Master 支持原生 Burst 传输以充分利用 SRAM 带宽
6. **双模式仿真**：单个 `tb_picorv32.v` 支持 `VCS` 仿真和 `FPGA` 综合两种模式，通过 `` `define FPGA`` 宏切换

---

## 许可证

- **PicoRV32**：ISC License (Copyright © 2015 Claire Xenia Wolf)
- **AXI Interconnect**：MIT License (Copyright © 2018 Alex Forencich)
