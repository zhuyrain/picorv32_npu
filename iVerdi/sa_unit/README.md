# SA 单元自检

## 文件与边界

- [gen_vectors.py](<gen_vectors.py>)：仅使用 Python 标准库解析固定 C 数组；先用 Python 任意精度有符号整数逐元素重算五组 GEMM，再生成 `$readmemh` hex。不存在 int8 溢出、numpy 定宽乘法或后处理。case 3–5 强制检查 A 全为 **1**，不是 0。
- [sa_test_driver.sv](<sa_test_driver.sv>)：公共驱动和独立算术/时序 scoreboard，两个主 TB 都必须编译此文件。
- [tb_sa.sv](<tb_sa.sv>)：五组 reference 的全元素测试，1856 个最终输出逐一比较。
- [tb_sa_protocol.sv](<tb_sa_protocol.sv>)：协议、有符号/宽 seed、反压、flush/reset 和 bank 生命周期测试。
- [Makefile](<Makefile>)：VCS 编译、向量生成及运行入口；[tb_sa_shapes.sv](<tb_sa_shapes.sv>)：1x1、1x8、8x1、3x5 参数 smoke。

本目录验证对象是 **SA compute primitive**，不是整个 Q1 系统。旧 wrapper、外部 skew 与32位 ACC 尚未迁移，不能通过旧 SoC 回归判断本接口是否正确。本次不涉及 PPA/Fmax。默认8x8空载 latency 为15个寄存器级：包含输入接收边沿，即接收后14个后续 advance 边沿输出有效；输出在其后的 ready posedge 退休。

## 计算接口

默认 `ROWS=COLS=8`、`PSUM_WIDTH=48`。物理行对应 K，物理列对应 N，M 沿时间流过；逻辑大矩阵由调用方分块，不增加 PE 的权重容量。

| 接口 | 行为 |
|---|---|
| `weight_valid/ready, weight_bank/row/data` | 一次握手写一个 K 行的8个 INT8；每 PE 严格 ping/pong 两个8位寄存器，整阵列128B权重数据，无9/64项RF |
| `bank_ready[1:0]` | 各 bank 的全部物理行已写齐；完整 bank 开始重装后须重新写齐，尾行也必须写0 |
| `bank_busy[1:0]` | 包括被反压输出在内的在途引用；禁止写该 bank，同拍新输入与同 bank 写冲突时计算优先 |
| `in_valid/ready, in_bank, in_act` | 接收一逻辑 M 行的8个 K 激活及其权重 bank；调用方按握手保持输入稳定 |
| `in_psum` | 每列48位种子；首 K 块给0或一次 bias，后续给外部 ACC 的实际部分和 |
| `in_col_mask` | N 有效列掩码，随行传递；屏蔽 lane 输出0，不关闭独立列时钟 |
| `out_valid/ready, out_bank/psum/col_mask` | 内部 deskew 后整行输出；阻塞时全计算管线冻结，另一空闲 bank 仍可预载 |
| `flush` / `rst_n` | 同拍禁止接口握手、清在途数据；flush 保留已加载权重，reset 撤销 loaded 状态 |

内部行 skew、seed 列 skew、PE 与输出 deskew 共用 `advance`，无需旧外部 skew 或经验 drain 计数。没有独立列门控或额外的已选权重寄存器。单拍 MAC 的时序收敛及后续低功耗门控需要另行综合评估。

本模块不管理 `K_total`/INIT/FINAL 上下文、ACC SRAM、INT32 最终溢出、requant、DMA、MMIO 或命令队列；这些不能由本次 SA 通过测试推定已支持。PE 算术额外覆盖 -128 仅用于二补码边界检查；模型有效输入仍遵守 Spec 的 [-127,127] 限定。

## 生成向量

在仓库根目录执行：

```sh
python3 iVerdi/sa_unit/gen_vectors.py
# 可选：更改输入与输出目录
python3 iVerdi/sa_unit/gen_vectors.py --source path/to/header.h --out path/to/hex
```

默认输入为 [固定 reference](<reference/test_vector_hwc_im2col_tiles.h>)，首先按 [固定manifest](<reference/manifest.json>) 校验 SHA256，任何快照改动都拒绝；`--manifest` 可指定另一个显式来源清单。输出为 `build/hex/`（相对此验证目录）。所有输出 hex 与 manifest 都通过同目录唯一临时文件、关闭后 `os.replace` 原子发布，允许多个并行 make 共用输出目录而不会读到截断文件。每组生成 input/weight/expected 三个平坦 row-major hex：INT8 为两位二补码，INT64 expected 为十六位二补码，每行一个元素；另生成含源 SHA256 与 M/K/N 的 manifest。非法 shape、元素数、范围、非整数字面量或 expected 不一致均立即报错，非零退出；不需要 C 编译器。

五组 M/K/N 分别为 32/32/16、32/27/16、32/8/16、32/8/8、8/8/8。转换器已验证全部 1856 个 expected；另以内存损坏测试确认源 SHA256 改变、修改一个 expected 或将 case3 的一个 A 改成 0 都会被拒绝。

## 运行

[Makefile](<Makefile>) 可直接在仓库根目录调用：

```sh
make -C iVerdi/sa_unit test TOP=tb_sa SEED=1
make -C iVerdi/sa_unit test TOP=tb_sa_protocol SEED=1
make -C iVerdi/sa_unit test TOP=tb_sa_shapes SEED=1
# 编译一次后，变更随机种子仅重跑：
make -C iVerdi/sa_unit sim TOP=tb_sa SEED=42
# 三个顶层，各跑seed 1/7/42；遇错立即非零退出
make -C iVerdi/sa_unit regress
# 可选：主向量TB的FSDB（独立build/tb_sa_fsdb目录）
make -C iVerdi/sa_unit test TOP=tb_sa FSDB=1
make -C iVerdi/sa_unit wave TOP=tb_sa FSDB=1
```

如手动编译，加入 PE/SA RTL、公共 driver 和所选 TB，使用 SystemVerilog 模式并指定顶层。向量仿真接受 `+HEX_DIR=<绝对或当前运行目录相对路径>`；默认相对仓库根目录的 `iVerdi/sa_unit/build/hex`。VCS 的 `+ntb_random_seed` 通过 `$urandom` 初始化 producer/backpressure LFSR；零态有兜底，固定 seed 可复现。所有数据/协议失败和覆盖缺失使用 `$fatal(1,...)`；每次握手、等待输出、drain 及整场仿真都有超时。运行统计见交付报告。

## 验证模型与覆盖

**约定：** lane0 位于最低 byte/word；A/B 是 signed INT8；种子和结果为 signed PSUM_WIDTH（默认48）。weight_row 为物理 K 行，weight_data 每列一 byte。每轮完整写 ROWS 行；完整闲置 bank 的首次重写开始新 generation，直到重新写齐 ROWS 行才可计算。

**独立 scoreboard：** 仅观察外部握手维护两 bank 的权重与 loaded bitmap，根据逻辑向量直接计算 `seed[c] + Σ A[k]*B[k,c]`，不读取 DUT 内部 PE 状态。L=ROWS+COLS−1 个期望寄存器仅在 `!out_valid || out_ready` 时移动，因此同时检查精确 latency、bubble、bank/mask 元数据、全部输出 lane、全管线冻结，以及 backpressure 每周期的输出稳定性。mask=0 的 lane 必须为 0，但行 valid 仍存在。bank_busy 必须等于全部期望在途元数据的归约，包括等待退休的输出寄存器。flush/reset 会清除模型在途行；只有 reset 清除 loaded bitmap。

**五组向量：** M 按8行批次、N 按8列、K 按8处理；每个 K 块的实际输出通过 TB 外部 ACC 数组反馈为下一块的 in_psum。没有 DMA/EX controller。两个 bank 交替使用：一侧计算时另一侧预载下一 K 块。case2 的 K=27 尾块对 A 和 B 都补0；写尾权重前先把目标 bank 全部写成127，再完整覆盖8个物理行，显式检测陈旧尾行。所有参考输出均逐元素比较，不使用仅抽样或 checksum。

**协议测试：** 未加载/半加载输入拒绝；完整 bank 第一次重写后旧 ready 撤销；同拍相同 bank compute 优先；逐行混合两个已加载 bank（包括连续32行 in_valid）；随机 producer bubbles、out backpressure、mask；A 的负值与127/−127/−128；正负超过INT32的宽 seed；第一块越过INT32上界后用实际结果反馈、第二块抵消回原范围；busy bank 写拒绝；输出被冻结时另一 bank 独立完成整轮预载；flush/reset 丢弃被阻塞的在途输出；flush 同拍三个事务接口均取消、权重保留；reset 后两个 bank 重新变成不可用。协议 TB 本身也参数化，另有 1x1/1x8/8x1/3x5 的并行 shape smoke。
