## 快速开始

### 环境要求

-**仿真 & 覆盖率收集**：Synopsys VCS + DVE + Verdi

-**FPGA**：Xilinx Vivado

-**GCC编译器**：无需，hex固件由CNN-CIFAR-10代码仓自动生成后复制到本代码仓的iVerdi/regress/firmwares/目录下即可

### 单次仿真

```bash
cd iVerdi

# 编译 + 仿真 + 启动 Verdi 查看波形
make all CASE=1 -f Makefile.vcs

# 仅编译
make compile CASE=1 -f Makefile.vcs

# 仅仿真（使用当前 firmware.hex）
make sim CASE=1 -f Makefile.vcs

# 仅启动 Verdi 波形
make wave CASE=1 -f Makefile.vcs
```

### 覆盖率回归测试

```bash
cd iVerdi

# 使用所有回归固件进行带覆盖率收集的全量仿真
make regress COV=1 -f Makefile.vcs

# 打开DVE查看覆盖率报告
cd vcs_work
dve -cov -covdir simv.vdb &
```

### FPGA 上板

1. 解压 `FPGA/project_riscv_npu.xpr.zip`
2. 在 Vivado 中打开工程
3. 综合 (`Synthesis`) → 布局布线 (`Implementation`) → 生成比特流 (`Generate Bitstream`)
4. 烧录至目标 FPGA 开发板
