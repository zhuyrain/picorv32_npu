# SA：窄位宽阵列与独立宽位累加器

## 1. 版本与范围

- `800e46f`：初版（48位阵列、全局stall、顶部seed）。
- **`d48d9c2`：按用户要求先提交的重构基线**（级联权重、自由流水、32位南侧本地ACC、结果FIFO）。
- 当前未提交改动：解耦 `PE_PSUM_WIDTH` 与 `ACC_WIDTH`，默认8×8为 **19位阵列 / 48位南侧ACC**。

实现位于 [PE](<../../npu_rtl/pe.v>)、[SA](<../../npu_rtl/sa.v>)、[南侧ACC](<../../npu_rtl/sa_south_acc.v>) 与 [结果FIFO](<../../npu_rtl/sa_result_fifo.v>)。这里只验证计算子系统，不是完整DMA/命令队列NPU。

## 2. 两个独立位宽参数

```verilog
parameter ROWS = 8;
parameter PE_PSUM_WIDTH = $clog2(ROWS * 16384 + 1) + 1;
parameter ACC_WIDTH = 48;
```

### 2.1 为什么修正原公式的一个边界位

完整signed INT8乘积范围为 `[-16256, +16384]`；正极值来自 **(-128)×(-128)=+16384**。物理R行的部分和范围为 `[-16256R, +16384R]`，signed W位的正上界却是 `2^(W-1)-1`。

用户给出的 `$clog2(ROWS*16384)+1` 在ROWS为2的幂时少1位：R=8得到18位，但正极值131072超过18位signed上限131071。因此为满足“最极端最小安全位宽”，采用 **`$clog2(ROWS*16384+1)+1`**。不是静默把-128当作不可出现，也没有把结果饱和或回绕。

| ROWS | 最坏正和 | 安全最小 PE_PSUM_WIDTH |
|---:|---:|---:|
| 1 | 16384 | 16 |
| 3 | 49152 | 17 |
| 8 | 131072 | 19 |
| 4096 | 67108864 | 28 |

合法物理ROWS为1..4096，公式中的32位整数乘法在此范围内安全。允许显式扩大PE宽度，不允许小于安全值；`ACC_WIDTH>=32` 且 `ACC_WIDTH>=PE_PSUM_WIDTH`，保证INT32 bias与内部部分和都可无损吸收。参数检查不依赖 `SA_CHECKS`，非法配置仿真启动即失败；综合时忽略这些检查，不代表无效参数可作为合法实现。

### 2.2 各层到底用哪个宽度

| 路径/存储 | 位宽 |
|---|---|
| INT8激活、两组驻留权重、权重转发 | 8位 |
| PE内部乘积 | signed16 |
| PE垂直psum、底部列deskew、送入南侧的partial | **PE_PSUM_WIDTH** |
| `bias_data`端口与bias寄存器 | signed INT32，每列32位，不扩大存储 |
| 南侧history、下一部分和、最终 `out_psum` lane | **ACC_WIDTH** |
| 南侧临时加法与溢出检测 | **ACC_WIDTH+1** |
| 结果FIFO数据 | 每列ACC_WIDTH，加bank/address/mask/error元数据 |

窄partial与INT32 bias都在南侧入口**先按各自符号位扩展**；两操作数再扩至ACC_WIDTH+1后做加法。无效列保持0。不能先在32位内相加后再扩位，也不能把unsigned packed lane直接零扩展。南侧history与FIFO完全不回窄到PE宽度或32位。

默认8×8，结果数据端口为 `8*48=384` 位；FIFO每项含metadata共398位，32项约12736个数据位；ACC历史为8×8×48=3072个数据位。若显式覆盖ACC=32/40/56，输出/FIFO/历史宽度随之变化，阵列宽度不会被带着改变。原 `PSUM_WIDTH` 参数已经移除，调用方需改用两个新参数。

### 2.3 数值与错误语义

- first：`sign_extend(INT32_bias) + sign_extend(tile_dot)`；非first：`ACC_history + sign_extend(tile_dot)`。bias只在first加一次。
- **超过INT32范围不再是错误。** 默认48位可保留宽中间值并允许后续K块抵消，last也可输出超过INT32的合法48位结果。
- `out_error=1` 仍表示上下文错（缺first、重复first、mask改变）；`out_error=2` 现在表示 **ACC_WIDTH自身** 的signed溢出，而非INT32溢出。
- 实际ACC溢出仍poison到last，返回错误且整行0；不能把截断值当成功。fault粘滞至flush/reset。显式选择ACC_WIDTH=32时，旧版32位越界诊断仍成立。
- 有限48位不是“无限轮绝对安全”：完整INT8、任意INT32 bias且逻辑K≤4096时，完整和范围 `[-2214068224,2214592511]`，48位有充分裕量；本模块不计K_total，不限制无限次first/last之间的更新，故保留实际ACC溢出诊断。
- 本模块没有最终INT32窄化/量化。将宽输出写成INT32或requant时，上层须另做范围检查；不能把本版宽累加成功等同于INT32 debug输出一定可表示。

## 3. 数据流与接口（保留自由流水架构）

```text
北侧权重流 B[R-1,:] ... B[0,:]
           | 每hop byte/valid/bank/target 寄存
A -> 行skew -> WS mesh [PE_PSUM_WIDTH] -> 列deskew [PE_PSUM_WIDTH]
                                             |
                         INT32 bias -> 符号扩展 -> ACC[ACC_WIDTH] -> FIFO[ACC_WIDTH] -> 消费者
输入控制器 <------------------------ ready / reserved credit / almost_full -------+
```

### 权重与bank

每PE仍为**两个8位驻留权重＋一个8位转发寄存器**，最多3个字节，无多项RF。`weight_in`仅接北侧首行，再从相邻PE逐跳传递数据与控制，不恢复全局广播。

每tile固定ROWS个握手，按物理行逆序注入，所有K/N尾部显式写0。一个load会话只用一个bank，可有bubble，不可中途切bank；最后注入后还须等待ROWS个后续边沿的南侧ACK，才有 `bank_ready`。bank是驻留权重组，不是另一套计算阵列；默认驻留128B，转发64B。

`bank_busy`只跟踪阵列在途token，南侧提交后即可重装，即使最终结果仍在FIFO。首次重装撤销旧ready；同拍新计算与同bank装载冲突时计算优先。flush取消正在装载的bank，防止部分新旧权重混用。

### 自由流水与credit

PE没有 `advance` 或纵向valid链，仅单一act-valid。所有skew、mesh、deskew每拍前进；改变位宽不改变时序：`L_array=ROWS+COLS-1`，输入边沿n接受，n+L_array−1后aligned partial有效，n+L_array边沿南侧提交/入FIFO，最早再下一边沿输出握手。默认15级阵列＋1级南侧。

FIFO深度单位为整行向量，默认2*(ROWS+COLS)，必须≥ROWS+COLS；支持非2幂回绕。额度守恒：

```text
P = 已接受、尚未南侧提交的输入行
Q = fifo_level
U = reserved_level = P+Q <= FIFO_DEPTH
U_next = U + in_fire - nonfinal_south_commit - out_fire
```

non-final留在本地ACC，释放预留；final只把预留转到FIFO，退休后释放。`almost_full=(U==FIFO_DEPTH)` 是预留额度耗尽，满额同拍不借pop信用。消费者阻塞不会冻结PE，在途结果继续排空。

**输入DMA必须遵守ready/valid。** 若仅延迟响应almost_full且继续无条件发送，需要额外stop-latency margin/skid空间；FIFO深度≥延迟本身不是防溢出证明。

### 本地槽、bias与控制

`in_acc_addr`选择M行槽，`in_first/in_last`标记多K块上下文，mask在同一上下文中不变；只有last向FIFO输出。默认ACC_ROWS=8，存储为组合读/同步写寄存器数组，支持连续同地址RMW。若映射同步读SRAM，需重新设计旁路/互锁、端口和credit延迟。

`bias_valid/ready`配置南侧INT32列向量；只有阵列无在途、无开放ACC上下文时可写，同拍计算优先。已完成FIFO结果不妨碍改bias。`out_bank/out_acc_addr/out_col_mask`来自final输入，阻塞时FIFO头稳定。非法ACC地址不接受（ready0）。

flush禁止所有握手，清阵列/FIFO/context/fault，保留完整权重组和bias；中断load的bank无效。reset另使全部bank无效并清bias为0。

## 4. 验证与复现

[生成器](<gen_vectors.py>)按[固定manifest](<reference/manifest.json>)校验[五组向量](<reference/test_vector_hwc_im2col_tiles.h>)并用Python整数GEMM重算，case3–5激活全1。所有输出原子发布，source快照不修改。

```sh
make -C iVerdi/sa_unit regress
make -C iVerdi/sa_unit test FSDB=1
make -C iVerdi/sa_unit wave FSDB=1
```

[共享checker](<sa_test_driver.sv>)使用独立int64数学模型与固定时钟pipe/FIFO，检查credit、顺序、数据、错误、bank ACK和反压稳定，不读取DUT内存构造期望。当前验证覆盖ACC32/40/48/56，checker支持至63位，不因此限制RTL可配置上限。

[主向量测试](<tb_sa.sv>)覆盖全部1856个最终元素、616个K行token/232个最终向量，K27按8/8/8/3、先污染后尾零，无外部部分和反馈。[协议测试](<tb_sa_protocol.sv>)保留串行装载、bias一次、多槽/同槽RMW、满FIFO排空、上下文错与flush/reset，并将默认48位下的INT32越界抵消改为成功；[32位配置测试](<tb_sa_protocol32.sv>)单独保留ACC32溢出poison验收。[参数测试](<tb_sa_shapes.sv>)包含最小/非2幂FIFO与独立PE24/ACC40配置。附加位宽/南侧边界测试检查-128×-128正端点、负partial/负bias扩展及真正ACC位宽溢出。具体顶层和实际结果见[验证报告](<RESULTS.md>)。

## 5. PPA取舍与尚未集成

默认PE/deskew从32位降为19位，但ACC从32位升48位，FIFO也随输出变宽；这是把宽数值状态集中在边缘，不保证总FF面积或功耗下降。权重转发与FIFO也有面积/装载延迟成本。自由运行减少全局enable扇出，却不自动减少bubble期翻转；南侧读mux＋48位加法＋FIFO写可能成为时序瓶颈，必须综合/布局布线后判断。

仍未集成旧SoC wrapper、DMA、片上SP、完整命令ABI/K_total依赖检查、量化/ReLU或IRQ，旧卷积固件不能直接沿用。本轮没有PPA/Fmax/STA/CDC或全网络签核结论；10ns仿真时钟不是频率收敛证明。[历史Spec快照](<reference/NPU_Spec.md>)原样保留，当前接口与位宽以本说明为准。
