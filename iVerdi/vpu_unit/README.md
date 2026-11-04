# NPU 向量后处理单元（VPU）

## 1. 提交与实现范围

按用户要求先提交上一轮自然排空改动：**`175f2e0` — 移除 PE 阵列全局 flush 并实现边缘自然排空隔离**。

本轮新增 [npu_vpu.v](<../../npu_rtl/npu_vpu.v>) 与本独立验证目录，不修改既有SA/PE、南侧FIFO或 [旧PPU](<../../npu_rtl/npu_ppu.v>)。VPU可以直接接SA南侧FIFO的ready/valid与宽结果，但未把旧SoC wrapper改接为新VPU。新源码与测试向量保留在工作区，未再次提交/推送。

## 2. 数值契约

每lane有独立signed multiplier；shift/mode/ReLU由一个向量共用。默认 `COLS=8, ACC_WIDTH=48, RES_WIDTH=8, MULT_WIDTH=32, SHIFT_WIDTH=7, TAG_WIDTH=8`，lane0位于最低byte/word。

```text
普通卷积量化：wide = acc * mul_main
残差融合量化：wide = acc * mul_main + residual * mul_res
q = clip(floor(wide / 2^shift), -127, 127)
y = relu_en ? max(q,0) : q
```

- INT8对称饱和范围沿用 [既有Spec](<../sa_unit/reference/NPU_Spec.md#L439-L457>) 的 **[-127,127]**，不是通用二补码[-128,127]；zero point=0。
- 负数右移向负无穷取整：`-3 >>> 1 = -2`，不加rounding bias，不使用浮点，也不先把两个乘积分别shift/clip。
- 主输入可使用完整signed48累加值，不偷偷截成INT32。默认主乘积80位、残差乘积40位、求和81位；直到clip才窄化为8位，避免旧PPU的“先截32位再饱和”风险。
- 泛化位宽：`P0=ACC_WIDTH+MULT_WIDTH`，`P1=RES_WIDTH+MULT_WIDTH`，`SUM_WIDTH=max(P0,P1)+1`；两乘积先按符号扩至SUM_WIDTH后求和，移位结果继续保留SUM_WIDTH。
- 默认shift可为0..127。算术右移量大于等于SUM_WIDTH时，负数得到-1、非负得到0，与整数floor语义一致。
- 系数支持完整signed位宽，包含负值/最小负值。实际模型若仅使用正系数，是上层量化参数约束，不是本模块隐含的截断规则。
- mask=0的lane输出0。`in_error!=0`时整向量数据输出0，错误、mask、tag仍随token输出，不把SA错误饱和成成功。错误或全0mask的融合向量也须正常消费其残差，防止流错位。
- Bias已经由SA南侧ACC在first注入；VPU不重复加bias。这里也不实现Spec的FINAL INT32范围拒绝、debug INT32窄化或整任务错误/IRQ管理。

## 3. 微架构：两乘一加与五级弹性流水

```text
S0 捕获输入/系数/模式/ReLU/shift/tag/error/mask
              |                            |
S1       ACC×M0（并行）                RES×M1（并行）
              +------------+---------------+
S2                   宽位加法器
S3                   全宽算术右移
S4                  clip / 可选ReLU
```

**“两个乘法器”按两个向量乘法通路实现：每lane两个标量乘法器＋一个标量加法器。** 默认8 lane对应16个RTL标量乘法、8个宽加法，不是整个8维向量只用两个scalar，也不能据此说只需要16个DSP。若物理预算严格只允许两个scalar，应把COLS设为1并由外部串行化/重组SA向量，或另做时间复用VPU；不能同时宣称8 lane全并行吞吐。

普通模式仍经过同一加法器，残差操作数与系数在S0隔离为0，既不会消费残差，也不会被普通模式下无效/X残差数据污染。数据寄存器不复位，reset/flush仅清valid与接口握手许可；invalid周期的payload可能为旧值/X，不应被消费。

每级有本地 `ready[i]=!valid[i] || ready[i+1]`，输出级接out_ready。最多容纳5个在途向量；连续可用输入/残差和输出ready时，理论II=1向量/周期。无stall时在边沿n接受、n+4边沿后输出valid、最早n+5边沿退休；反压时延可变，不是固定5cycle端到端延迟。

ReLU可以逐接受向量、逐周期开/关。**实时控制不追溯修改已接受的在途向量**：全部mode、系数、shift、ReLU、metadata在握手时锁存，后续只使用其副本。若把当前全局ReLU直接接到输出，会使旧数据受新层配置污染，因此没有这样“简化”。

VPU本身允许局部弹性停顿，但ready只反馈到SA南侧FIFO的pop；不连接PE enable，不恢复全局advance。SA的自然排空与credit机制继续负责在途阵列结果安全落入FIFO。

## 4. 接口、残差配对与flush

| 接口 | 行为 |
|---|---|
| `in_valid/in_ready, in_acc, in_mask, in_tag, in_error` | 主输入，可接SA南侧FIFO的psum/col_mask/错误；tag由控制器打包bank/acc_addr等 |
| `in_residual_en, in_relu_en, in_shift` | 当前主向量的模式、ReLU、公共右移量 |
| `in_mul_main/in_mul_res` | 每lane完整signed系数，低slice对应lane0 |
| `res_valid/res_ready, res_data` | 独立残差流，默认每lane signed8；只消费融合向量 |
| `out_valid/out_ready, out_data/out_mask/out_tag/out_error` | 量化INT8向量与原metadata；被阻塞时完整payload稳定 |
| `flush/rst_n` | VPU局部取消；flush周期不发生三接口握手，采样后清全部5级valid |

令R0为第0级本地可用：

```text
in_ready  = R0 && (!in_residual_en || res_valid) && reset_ok && !flush
res_ready = R0 && in_valid && in_residual_en     && reset_ok && !flush
```

融合时两路fire严格同时发生；普通模式res_ready恒0，即使残差提前到达也不消耗。main/res来源都不得等待READY才断言VALID，否则可能在系统外形成等待环；valid且未ready时必须各自保持data稳定，main的稳定payload包括全部mode/coeff/ReLU/shift/meta。

直接连接示意：`VPU.in_valid=SA.out_valid`、`SA.out_ready=VPU.in_ready`、`VPU.in_acc=SA.out_psum`，错误和mask直传，tag可编码 `{bank,acc_addr}`（TAG_WIDTH须容纳）。配置必须匹配当前FIFO头向量，不能因层切换提前把尚未握手的旧向量配置换掉。

本模块没有残差地址比较/重排/独立残差FIFO，按接受顺序配对。控制器负责把相同行/通道残差送来；缺残差会使融合头部等待，不能把“无内部组合环”宣称成任意外部调度都无死锁。

VPU单独flush只取消已接受的本地向量，不能清上游SA FIFO或残差源队列。系统中止必须协调各队列/控制器的同一任务边界；否则可能把旧残差配到新主向量。这里不新增全局PE flush。

## 5. 与旧Tiny/Conv3/Add不等价的边界

既有Spec要求Conv3先requant/clip，再把两路INT8做Add。**直接融合raw ACC与残差通常不与该顺序bit-exact**，即使数学实数比例看似可合并。

例：raw acc=200，Conv量化M=1/shift=0先clip成127；残差=-127，Add两乘数=1、shift=1，则原顺序得到0。若直接raw融合，`floor((200-127)/2)=36`，ReLU后仍为36。

因此本模块定义独立的raw融合算术模式，不宣称已复现旧Tiny残差黄金。若要严格遵守旧边界，应先普通模式得到Conv3 INT8，再符号扩展为main做融合Add（两pass/中间缓冲），或保留CPU Add；不能把系数一合并就声称等价。此取舍写清而不强行“优化掉”中间量化。

## 6. 持久测试向量与验证

**测试向量保存在 [vectors.json](<vectors/vectors.json>)，不在忽略的build目录，不会删除。** [manifest](<vectors/manifest.json>)记录参数、固定seed、字段位布局、SHA256与计数；同时保存 [主输入HEX](<vectors/input.hex>)、[残差HEX](<vectors/residual.hex>) 和 [黄金结果HEX](<vectors/expected.hex>)。

[生成器](<gen_vectors.py>)使用Python任意精度整数计算完整乘积/求和/floor/clip/ReLU，无numpy或int64溢出。默认768个向量、每向量8 lane，其中462个融合向量。另用独立signed128参考检查RTL，而不是用旧SA的signed64模型验证80位乘法。

```sh
make -C iVerdi/vpu_unit vectors       # 只读检查已保存向量，不覆盖
make -C iVerdi/vpu_unit generate      # 显式按固定seed重生成（保留在vectors/）
make -C iVerdi/vpu_unit regress       # 三top，各seed 1/7/42
make -C iVerdi/vpu_unit test FSDB=1
make -C iVerdi/vpu_unit wave FSDB=1
```

- [主测试](<tb_vpu.sv>)与[共享driver](<vpu_test_driver.sv>)：持久Python黄金向量＋signed128参考双比，独立main/res producer、精确5级elastic时序、早/晚残差、动态参数、X残差隔离、长反压、占满5级、flush/reset在途取消恢复。
- [参数测试](<tb_vpu_params.sv>)：不同lane数/ACC/残差/乘数/shift/tag宽，包含残差乘积宽于主乘积的配置；检查高于64位乘法、负数大shift和输出metadata。
- [真实FIFO集成测试](<tb_vpu_fifo.sv>)：使用现有sa_result_fifo、与SA相同的字段打包，独立残差源，只反馈VPU ready，不改PE；深度5的非2幂FIFO在缺残差和长输出反压下保持头数据稳定并复流。

实际执行统计与限制见 [验证报告](<RESULTS.md>)。[运行器](<run_sim.py>)同时核验simv返回码、Fatal/assert失败及顶层PASS完成标记：本机VCS某些fatal场景可能返回0，不能仅凭退出码判断成功；runner会强制将该情况转换为非零失败。build产物可重建，vectors是独立保留的交付数据。

## 7. PPA与集成限制

48×32宽乘法器可能拆分成多个DSP/单元，宽加法、可变右移和5级ready链也可能成为关键路径；`use_dsp`只是提示，不保证映射、Fmax或面积。二组向量乘法器与每向量捕获系数提高吞吐/正确性，但有寄存器和布线成本，未强加串行化来掩盖资源预算。

本轮没有综合/PPA/STA/CDC签核，没有真实DDR/残差DMA/整网Tiny黄金或完整Q1命令集验收。旧PPU仍原样存在（live配置、clip前32位窄化等风险不在这里顺手重构），新模块的验证结论不能套用到旧SoC固件路径。
