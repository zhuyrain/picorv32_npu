# 真实 SA → 南侧 ACC/FIFO → VPU 联合仿真

## 1. 已提交基线与本轮范围

先按用户要求提交上一轮VPU工作区：**`be0e35e` — 实现独立向量 VPU 及持久量化与残差融合验证**。

本目录是随后新增的联合验证环境，直接实例化 [SA](<../../npu_rtl/sa.v>) 与 [VPU](<../../npu_rtl/npu_vpu.v>)，使用SA内部的真实PE、南侧ACC和FIFO，不替换/伪造GEMM输出。现有RTL和既有单元测试源码保持不变；本轮新内容未再次提交/推送。

## 2. 原始输入与持久 identity

输入来自 [已冻结的im2col头文件](<../sa_unit/reference/test_vector_hwc_im2col_tiles.h>)，五组分别为：

| case | A[M,K] | B[K,N] | MAC/identity/Y[M,N] |
|---|---|---|---|
| 1 | 32×32 | 32×16 | 32×16 |
| 2 | 32×27 | 27×16 | 32×16 |
| 3 | 32×8 | 8×16 | 32×16 |
| 4 | 32×8 | 8×8 | 32×8 |
| 5 | 8×8 | 8×8 | 8×8 |

A/B保持头文件原值，权重是 **B[K,N]，不是W[N,K]**。case3–5激活是全1；case1已有K尾零，case2由SA馈送端按8/8/8/3分块并对尾部A/B补0。

[生成器](<gen_vectors.py>)校验原始来源SHA，再以Python任意精度整数重算 `C=A*B`，逐元素核对头文件INT64 expected。header不含bias，因此SA bias保持0，不改变原始输入来适配期待结果。

每组另外生成一个同形状 **M×N signed INT8随机identity残差张量R**，范围[-127,127]，固定基础seed `0x5341565055323036`，每组使用base+case。这里identity指skip-connection特征，不是数学单位矩阵，也不是来自真实网络前层的shortcut。

全部A/B、裸MAC、identity及三种后处理黄金矩阵保存在 [可读vectors.json](<vectors/vectors.json>) 与逐case HEX中；[manifest](<vectors/manifest.json>)记录源提交/SHA、生成器与解析器SHA、seed、形状、系数、统计及文件哈希。数据在持久vectors目录，不在忽略的build里，不会删除；正常回归只读校验，显式 `make generate` 才重生成。

## 3. 逐层 MULT 与共享 SHIFT

每组矩阵视为一个独立测试层：一个MULT_MAIN、一个MULT_IDENTITY，所有空间位置/输出通道相同，**不使用per-channel量化**。两路共用SHIFT=16。

令 `P=max(abs(C))`，主支路目标峰值约80，给残差留出约64的幅度：

```text
MULT_MAIN = max(1, floor((80*2^16 + floor(P/2)) / P))   # 正数nearest、half-up
P=0时 MULT_MAIN=1
MULT_IDENTITY = 32768                                # 有效增益0.5
SHIFT = 16
```

| case | MAC绝对峰值 | MULT_MAIN | MULT_IDENTITY | 公共SHIFT |
|---|---:|---:|---:|---:|
| 1 | 22409 | 234 | 32768 | 16 |
| 2 | 22409 | 234 | 32768 | 16 |
| 3 | 137 | 38269 | 32768 | 16 |
| 4 | 137 | 38269 | 32768 | 16 |
| 5 | 137 | 38269 | 32768 | 16 |

主支路有效增益分别234/65536或38269/65536；残差为32768/65536。系数正且在signed INT32范围内。目标80是选系数的近似目标，不是严格的绝对值上限，负数floor也可能改变一个LSB。

**MULT_MAIN作用于完整全K的GEMM输出C，不作用于输入A/B，也不逐K块量化。** identity同样只在VPU中乘自己的MULT，然后两乘积先宽加、一次共同右移：

```text
ordinary = clip((C * MULT_MAIN) >>> SHIFT, -127, 127)
fused    = clip((C * MULT_MAIN + R * MULT_IDENTITY) >>> SHIFT, -127, 127)
fused_relu = max(fused,0)
```

不用浮点计算黄金、不加rounding bias、zero-point=0。残差1/2的非整数部分与主支路小数先相加再floor，不能各自shift后再求和。五组融合结果中饱和元素分别0/0/4/2/1；既有大量未饱和结果，也实际覆盖clip与负数ReLU。

**这只是合成测试校准，不是训练模型校准。** 头文件只提供量化整数A/B和裸MAC，没有真实sA/sW/sR/sY或层scale；不能据此恢复真实网络的量化比例/精度。固定随机R也不代表真实identity的分布或相关性。

## 4. 实际连接、顺序与调度

[主TB](<tb_sa_vpu_joint.sv>)实例化：8×8 SA，内部19位/南侧48位、8个M槽；以及8lane VPU。连接是：

```text
SA.out_valid  -> VPU.in_valid
SA.out_psum   -> VPU.in_acc
SA.out_col_mask/out_error -> VPU.in_mask/in_error
VPU.in_ready -> SA.out_ready              # 只控制SA南侧FIFO pop
independent R stream -> VPU.res_data/valid/ready
```

tag编码仅 `{0 padding, final_bank, local_acc_addr}`，不携带完整全局M行号或N-tile地址。全局位置由有序流位置重建，不用已经前进的生产者循环变量猜FIFO旧头属于哪一行。

计算顺序为 **N-tile优先，再M块，再K块**：nb每8列、mb每8行，kb每8项。每个权重tile逆序注入物理行7..0；双bank装载与计算重叠，依据weight_ready/南侧ACK等待可用。每M行的K块用first/last和本地ACC累加，只有last进入FIFO，不回灌期待/实际部分和。

每个nb的最终输出依次为m=0..M−1，再进入下个nb。残差producer使用独立游标按相同顺序提取 `R[m,nb:nb+8]`，**不是直接顺读row-major HEX的连续8字节**（N=16时那会把下一N-tile误配给下一M行）。VALID不等待READY才拉高；阻塞时res数据保持不变。融合双fire必须原子，ordinary不消费任何res。

M槽在旧last南侧提交后可复用，不必等待VPU消费。TB不在每mb等待最终输出，否则无法填满FIFO；但切换case/MULT/mode/ReLU之前，会等该case所有SA pop、VPU结果退休、SA credits/ACC/bank_busy清空，且显式断言VPU全部5级valid为0。正常case间不reset硬件。

## 5. 三种profile与端到端压力

一个仿真依次执行：

1. ordinary、ReLU关闭；
2. fused、ReLU关闭；
3. fused、ReLU打开。

每种profile跑全部五组，每种1856个元素；一次仿真检查 **5568个最终INT8元素，并另外检查5568个raw MAC元素**。SA的真实FIFO头在每个valid周期（包括被VPU/残差阻塞时）都与原裸MAC比对，计数只按fire增加，防止clip/ReLU掩盖SA错误。

[默认TOP](<tb_sa_vpu_joint.sv>)使用FIFO_DEPTH=32，[第二TOP](<tb_sa_vpu_joint_fifo17.sv>)使用17，覆盖非2幂回绕与较小容量。两者使用同一套量化数据。

对profile1/case1额外停止最终消费者，直到实际 `fifo_level==FIFO_DEPTH` 且预留额度满，再保持25周期才释放；释放逻辑是独立线程，不等生产者结束，避免自造等待环。此时还显式要求bank_busy=0、reserved==depth，说明在途阵列已自然排空。case1有64个最终向量，足以填FIFO加VPU5级；case4/5输出太少，不对它们强行等待“FIFO满”。

其他周期有独立随机激活/权重/残差间隙和输出反压。检查主FIFO头、VPU输出和残差源阻塞稳定；记录缺残差、credit停止注入、FIFO满、下游停止时SA南侧继续提交，且没有向PE增加stall/flush。

## 6. 复现与持久文件

```sh
make -C iVerdi/sa_vpu_joint vectors        # 只读核验源/随机残差/量化参数/所有黄金
make -C iVerdi/sa_vpu_joint generate       # 显式固定seed重生成持久数据
make -C iVerdi/sa_vpu_joint regress        # 两FIFO配置，各seed 1/7/42
make -C iVerdi/sa_vpu_joint test FSDB=1
make -C iVerdi/sa_vpu_joint wave FSDB=1
```

`params.hex`每条119位，低位到高位为M0[32]、M1[32]、SHIFT[7]、M[16]、K[16]、N[16]；详细offset在manifest。A/B/identity/后处理HEX是signed8二补码，MAC HEX是signed64二补码，均row-major逐元素存储，testbench自行打包8lane。

[运行器](<run_sim.py>)同时检查当前运行的返回码、Fatal/assertion失败与明确完成标记，避免VCS零退出码掩盖失败。实际运行日志、统计和波形见 [验证报告](<RESULTS.md>)。

## 7. 不强行优化与未覆盖范围

- 旧Spec的“Conv3先requant/clip，再两路INT8 Add”不能一般化为raw C融合。例C=200先clip成127、R=-127、Add两M=1/shift1，旧顺序结果0；raw融合则36。本轮明确验证当前VPU的raw融合定义，不宣称旧Tiny整网bittrue；如要旧边界需保留两pass/中间量化。
- 逐层量化只约束参数统一，不自动消除中间量化边界，也不让合成随机残差成为真实shortcut。没有模型scale时不伪造“真实校准”。
- header的M/N都是8的倍数，联合测试不覆盖M/N ragged尾；K27尾零按协议发送。A尾也为0时，裸MAC正确本身不能独立证明所有B尾实际写0，低层权重捕获/尾部协议仍以既有SA单测为补充。
- 本轮只覆盖给定数值范围，>64位极端乘法等仍由已提交VPU单测覆盖。没有协调中途flush/跨epoch残差取消、真实DMA/DDR、命令ABI、全网络精度或PPA/STA/CDC验收；10ns时钟只是功能激励。
