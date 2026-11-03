# SA 第二版：级联权重、自由流水与南侧本地累加

本版按本轮四项微架构要求修改 [PE](<../../npu_rtl/pe.v>) 和 [SA](<../../npu_rtl/sa.v>)，新增 [南侧 ACC](<../../npu_rtl/sa_south_acc.v>) 与 [结果 FIFO](<../../npu_rtl/sa_result_fifo.v>)。这是独立计算子系统，不是完整 DMA/命令队列 NPU。初版（48位/全局 stall/顶部 seed）的实现与历史报告保存在 Git 提交 `800e46f`；本目录当前测试不再沿用旧全局冻结模型。

## 1. 数据通路与四项改造

```text
北侧权重整行流 B[R-1,:] ... B[0,:]
        | 各列首PE
        v 每跳 data/valid/bank/target 寄存
A行 -> 行skew -> WS PE mesh -> 列deskew -> 南侧ACC[acc_addr][n] -> 结果FIFO -> 消费者
        每拍前进、无advance                 ^ bias配置          |
输入控制器 <--------- ready / reserved credit / almost_full ---+
```

### 1.1 权重：点到点级联，不再广播到所有物理行

- 外部 `weight_in[COLS*8-1:0]` 只接北侧首行。随后每个 PE 只连接上方 PE 的 `weight_out` 与同拍的 valid/bank/目标行，控制也逐跳寄存；没有全阵列 `weight_en` 或 `weight_data` 广播树。
- 每 PE **两个8位驻留权重 PING/PONG，加一个8位转发寄存器**，最多3个权重字节，无9/64项RF、无已选权重副本。默认64 PE：驻留128B，转发64B，合计192B权重数据，另计控制位。
- 每次 tile 固定 `ROWS` 个成功握手，顺序是 `B[ROWS-1,:]` 到 `B[0,:]`；byte0对应列0。内部生成目标行号，匹配的 PE 捕获，packet继续流至南侧。
- 一个装载会话只针对一个 bank，可有任意输入 bubble；会话中换 bank 时 `weight_ready=0`，不能交错两个半 tile。最后一次北侧握手后仍须等待南侧 row0 packet 的 ACK；**不能把“已发齐”当作“已装齐”**。
- 完整空闲 bank 首次重写立即撤销 ready。每次都必须发送所有物理行，无效 K/N 项写0。另一已加载 bank 可同时计算；若新计算与新装载同拍争用同 bank，计算优先。

### 1.2 自由运行与输出 FIFO

所有 PE、行 skew、列 deskew、侧带 token 每个时钟前进，只有 reset/flush 可清空；**没有 `advance`、没有下游反压传播到 PE enable**。PE 仅按单一 `act_valid_in` 计算/隔离数据，不再有 `psum_valid_in`、`mac_valid=act_valid&&psum_valid` 或纵向 valid 链。几何对齐由边缘 token 与仿真断言验证。

令 `L_array=ROWS+COLS-1`。输入在边沿 n 接受，对齐部分和在 n+L_array−1 边沿之后有效，在 n+L_array 边沿执行南侧 ACC 和 FIFO enqueue；最早在下一边沿退休。默认8×8：15级阵列、加南侧一级共16级。**延迟按实际时钟数，而非 enabled-step 计数**。

FIFO 深度单位是“整行结果向量”，默认 `2*(ROWS+COLS)=32`，必须不小于 `ROWS+COLS=16`。支持非2幂深度，指针显式在 `DEPTH-1` 回绕。只有 `in_last` 的输入产生 FIFO 项，非最后 K 块只更新本地 ACC。

深度≥延迟本身不能防止溢出。本版采用精确预留 credit：

```text
Q = fifo_level（已排队最终输出）
P = 已接受、尚未在南侧提交的所有输入行
U = reserved_level = Q + P <= FIFO_DEPTH
U_next = U + in_fire - nonfinal_south_commit - out_fire
```

每个输入保守地预留一个向量位置；non-final到南侧释放，final只把预留从阵列转到 FIFO，消费最终输出才释放。空间不足时仅 `in_ready=0`，在途结果仍自然排空。`almost_full=(U==FIFO_DEPTH)` 是**预留额度耗尽**，不是单纯 FIFO 占用阈值。满额同拍 pop 不借给新输入，保守牺牲一次接受机会，简化反馈路径。断言逐拍检查守恒与无溢出。

**DMA 集成要求：必须遵守 ready/valid，输入仅在 `in_valid&&in_ready` 时被接受。** 若实际 DMA 仅延迟若干拍响应 almost_full、且这些拍不可撤回，需再加对应 stop-latency margin 或输入 skid/FIFO；不能直接无握手地灌入。当前未实现 DMA，也不把此信号称为任意 DMA 的现成安全阈值。

### 1.3 32位南侧跨轮累加与 bias

- 北侧 `in_psum` 已删除，各列 psum 从常数0起算；历史部分和与 bias 不经过阵列。
- 每输入带 `in_acc_addr/in_first/in_last`。`ACC_ROWS` 默认为8，保存8个 M 行上下文，每槽 `COLS` 个32位值。M、N大矩阵由上层按本地容量切块。
- first：新上下文 `bias[n]+本次dot[n]`；非first：`acc[addr,n]+本次dot[n]`；last：只在此时产生一个最终输出并释放该槽。不需要外部 SRAM 的部分和回读/回写或顶部反馈。
- `bias_data` 是独立南侧列向量配置，reset为0。只有阵列无在途输入且无开放ACC上下文时 `bias_ready=1`；若同拍有新计算则计算优先。FIFO中已完成的旧结果不妨碍配置。**bias只在first加一次**。
- 槽采用组合读、同步写的寄存器数组，支持连续时钟访问同一地址，不依赖 SRAM 未定义同址行为。若改成同步读 SRAM，需要增加 RMW pipeline/forwarding 或互锁并重算延迟与credit。

### 1.4 32位数值契约与错误

本轮32位 profile 不等于历史 [Spec快照](<reference/NPU_Spec.md>) 的 ACC48 能力。`PSUM_WIDTH` 固定32，合法物理 `ROWS=1..4096`，故单次 INT8 K块部分和在32位内；跨轮与bias在南侧用临时 signed33 位加法检测32位溢出，**不存储33/48位历史部分和**。

| `out_error` | 含义 |
|---|---|
| 0 | 本上下文未发现错误，输出有效32位结果 |
| 1 | 上下文错：无first就累加、未last又重复first、有效列mask改变 |
| 2 | 任一有效列的南侧加法发生 signed32 中间溢出 |

错误上下文持续 poison 到 last，last 返回错误码且整向量为0；`fault` 粘滞至 flush/reset，诊断不阻塞其他工作或排空。非first保留上下文首错；重复first建立新的错误上下文（以本次mask/bias为起点，报context错），不能视为合法抢占。last后才可正常first复用。mask=0的列不参与数值溢出检查。非法 `in_acc_addr` 不接受（ready0），不是一个自动错误完成命令。

**重要取舍：中间越过INT32后再抵消回范围，本版仍报overflow，不能像初版48位那样成功。** 报错前存入低32位仅供硬件继续排空，绝不会作为成功结果输出。

用户文字“218 accumulations”若指 `2^18` 个乘积项，则32位不能无条件保证：`2^18*127*127=4,228,120,576 > INT32_MAX`。无bias、输入限定[-127,127]的同号最坏安全项数是133144；任意INT32 bias也可能只加一个正乘积就溢出。若是218个项，则无bias的该乘积和在范围内，带任意bias仍需检测。因此本版采取**32位受限/溢出诊断**，不宣称支持任意2^18项精确累加。若必须保留原Spec的宽中间值后抵消语义，应另保宽ACC profile，而非静默缩位。

## 2. 接口摘要

默认 `ROWS=COLS=ACC_ROWS=8`，lane0在最低 byte/word。

| 接口 | 契约 |
|---|---|
| `weight_valid/ready, weight_bank, weight_in` | 北侧逆序整tile权重流，移除旧 `weight_row/weight_data` 接口 |
| `bank_ready[1:0]` | 两组驻留权重分别完整可计算，不是两套物理阵列 |
| `bank_busy[1:0]` | 仅阵列在途token引用；南侧提交后即可覆写，不再等输出FIFO退休 |
| `bias_valid/ready, bias_data` | 南侧配置，只有无在途/无开放context可改 |
| `in_valid/ready, in_bank, in_act` | 接受一M行在当前K块的激活，K/N尾由调用方补0 |
| `in_acc_addr, in_first, in_last, in_col_mask` | 本地M槽与多轮上下文；mask在同一上下文内保持不变 |
| `out_valid/ready, out_psum, out_acc_addr, out_bank, out_col_mask, out_error` | 只输出last结果；bank/mask取最终输入的元数据，阻塞时FIFO头稳定 |
| `fifo_level, reserved_level, almost_full` | 已排队/已预留向量数、credit反馈，不是字节数 |
| `acc_busy, fault` | 任一开放上下文、粘滞错误诊断 |
| `flush / rst_n` | 取消计算/FIFO/ACC上下文与在途load；flush保留完整bank和bias，但中断装载的bank无效；reset使所有bank无效且bias清0 |

所有输入在 ready=0 时按握手协议保持不变；flush/reset周期不发生输入、weight、bias或输出握手。一个tile的固定流顺序由调用方负责；接口无行号，不能自动识别调用方把两行权重颠倒。

## 3. PPA/带宽取舍：不强行宣称“所有改动都更优”

1. **连线改善是结构性目标，不是物理签核。** 权重数据/valid/bank/target在每一跳寄存，只保留北侧COLS个入口扇出；原全局advance已移除。clock/reset/flush与边缘控制仍需正常物理设计，未做布局布线证明“无拥塞”。
2. **级联装载有额外代价。** 每PE多一个转发字节和控制寄存器；最后注入后还要等待南侧ACK，单个load会话也限制两个bank的装载并发。它换取短局部连线，不保证小阵列面积/装载延迟更好。
3. **FIFO不是免费面积。** 默认结果宽270位，32项约8640个数据位；本地ACC为8×8×32=2048个数据位，另加metadata。当前用寄存器数组，可能比原48位PE+全局stall方案的总FF面积更大。可在端口/延迟确定后映射 SRAM 或调整深度，但不能只为减面积把FIFO降到不满足排空约束。
4. **自由运行不自动等于低功耗。** 取消全局stall降低enable扇出，但bubble期流水寄存器仍打拍；仅使用单valid隔离输入，未加入复杂门控补回面积/时序开销。后续局部门控需要重新验证在途数据，不能把全局advance偷偷加回来。
5. **32位缩位以数值范围换面积。** 减少PE/deskew位宽且删除顶部seed路由，但失去48位中间抵消能力；已用显式错误语义代替静默回绕。
6. **本地ACC减少的是不必要的跨K反馈。** 五组用例接受616个K行token，仅232个最终向量输出。其余384个non-final更新留在南侧；这是接口传输计数，不是实测系统 SRAM 带宽或端到端加速比。当前无DMA/SRAM系统连接。
7. **不能只看PE关键路径。** 新的南侧读mux+32位vector加法+FIFO写可能成为新瓶颈。单拍MAC/南侧RMW均需后续综合、工艺库和时序约束；本次VCS功能通过不代表PPA/Fmax改善。

## 4. 验证与复现

[生成器](<gen_vectors.py>) 校验 [固定来源manifest](<reference/manifest.json>) 的 SHA256，再用Python任意精度整数重算 [五组向量](<reference/test_vector_hwc_im2col_tiles.h>)，原子发布hex，无第三方依赖。case3–5的A明确为全1。默认参考提交不随远端分支漂移。

```sh
python3 iVerdi/sa_unit/gen_vectors.py
make -C iVerdi/sa_unit regress              # 三top，各seed 1/7/42
make -C iVerdi/sa_unit test TOP=tb_sa_protocol
make -C iVerdi/sa_unit test FSDB=1
make -C iVerdi/sa_unit wave FSDB=1
```

- [共享driver/checker](<sa_test_driver.sv>)：输入端独立int64 GEMM/上下文数学模型、固定时钟token pipe、独立期望FIFO，逐拍检查credit、顺序、稳定性、bank释放及fault；不读取DUT权重/ACC内存构造期望。
- [黄金向量TB](<tb_sa.sv>)：全部1856个最终元素，K=27按8/8/8/3、先污染bank再尾零，两bank装载与计算重叠；无任何部分和反馈输入。
- [协议TB](<tb_sa_protocol.sv>)：加载bubble/错bank/半装载、bias一次、多槽交织和同槽连续RMW、FIFO满/输入credit停顿/在途自由排空、输出未退休时重装bank、上下文错、正负溢出和抵消仍失败、flush/reset。
- [参数TB](<tb_sa_shapes.sv>)：1×1、1×8、8×1、3×5使用最小FIFO深度2/9/9/8，另加8×8/FIFO17；覆盖非2幂回绕与3个ACC槽的非法地址测试。所有失败与超时均 `$fatal` 非零退出。

实际工具版本、运行统计与日志见 [验证报告](<RESULTS.md>)。生成目录被Git忽略，报告仅链接当前本地结果；代码测试以命令可复现为准。

## 5. 尚未集成

旧卷积wrapper/旧外部skew/PPU与本接口不兼容，未运行或宣称原SoC固件回归通过。本版没有DMA、片上SP、命令ABI、完整K_total/依赖检查、量化/ReLU或IRQ；它们需要独立EX/控制器接入，不能靠 `first/last` 冒充完整旧Spec。参考Spec快照保持原样，本轮32位profile差异以上述章节为准。未做综合/PPA、STA、CDC或全网络黄金验收。
