# VPU 独立验证结果 — 2026-11-04

## 1. 已提交基线与新增实现

按用户要求，先将上一轮工作区提交为 **`175f2e0`**，message：`移除 PE 阵列全局 flush 并实现边缘自然排空隔离`。

本轮新增 [VPU RTL](<../../npu_rtl/npu_vpu.v>) 与本验证目录；新内容仍保留在工作区，未再次提交或推送。Git检查确认SA、PE、旧PPU、南侧ACC/FIFO源码相对基线无变动。

VPU为两个并行向量乘法通路＋一个向量加法通路，默认每lane signed48×32、signed8×32，乘积分别80/40位，宽和81位。先宽加、统一floor shift，再对称clip[-127,127]，最后逐向量可选ReLU；无clip前32位窄化。默认8lane对应16个RTL标量乘法器和8个宽加法器，不是2个总标量乘法器或16个DSP的综合结论。

## 2. 保存下来的测试向量

**768个向量已持久保存，每向量8lane，共6144个输出元素；其中462个融合向量。所有文件均在vectors目录，不在被忽略的build里，没有删除。**

- [可读JSON输入与黄金结果](<vectors/vectors.json>)。
- [923位主输入HEX](<vectors/input.hex>)、[64位残差HEX](<vectors/residual.hex>)、[82位结果＋metadata HEX](<vectors/expected.hex>)。
- [参数/seed/字段布局/SHA256 manifest](<vectors/manifest.json>)。
- [确定性生成与只读校验脚本](<gen_vectors.py>)，固定seed `0x5650552026`。

黄金使用Python任意精度整数，不使用numpy、浮点或int64中间值。显式覆盖：32769×65535旧PPU窄化反例、负floor、clip边界、相邻向量ReLU变化、先宽加后shift、两路大数抵消、ACC_MIN×INT32_MIN=+2^78、大于64位乘积和高shift、负残差/负系数、mask与错误透传。

`--check`重新校验JSON每项范围/黄金、HEX逐行打包、params/layout/count及全部SHA，不改变保存文件的字节或mtime；默认回归只调用此模式。显式 `make generate` 才按固定seed重新发布，使用同目录临时文件原子替换，manifest最后发布。

## 3. 实际执行

工具：Synopsys VCS `V-2023.12-SP2_Full64`，SystemVerilog、VPU/SA_CHECKS、`+lint=all`，Verdi KDB/FSDB。

```sh
python3 iVerdi/vpu_unit/gen_vectors.py --check
python3 iVerdi/vpu_unit/run_sim.py --self-test
make -C iVerdi/vpu_unit regress
make -C iVerdi/vpu_unit test FSDB=1
```

三个顶层各seed=1/7/42，**9场最终回归全部PASS**；另有一场主向量FSDB仿真PASS。全部经runner校验，不仅依据simv返回码；所有最终状态为passed=true、无failure。

### 3.1 保存向量与协议主测试

[主TB](<tb_vpu.sv>)对768个保存向量逐lane比较Python黄金，并同时用 [独立signed128参考与五级elastic模型](<vpu_test_driver.sv>)检查，不从DUT状态构造期望。

每seed接受783个向量、正常退休773个、flush/reset各取消5个（共10）；其中768个退休向量来自保存数据，另5个为早/晚残差与X隔离定向用例。残差共消费464个（保存流462＋定向2），最大在途数确为5。

| seed | 输出阻塞周期 | ordinary期间提前res未被误取的观察周期 | main等待res | res等待main/容量 |
|---:|---:|---:|---:|---:|
| 1 | 451 | 157 | 725 | 690 |
| 7 | 414 | 154 | 633 | 690 |
| 42 | 453 | 152 | 569 | 691 |

覆盖独立main/res producer、双fire原子性、普通不消耗提前残差、main先到/残差先到、全字段逐向量锁存、完整payload反压稳定、错误/all0mask仍消费融合残差、占满5级、flush与reset取消恢复、普通模式无效残差data/系数全X隔离。

### 3.2 参数与连续吞吐测试

[参数TB](<tb_vpu_params.sv>)的四实例，各seed均PASS：

| COLS | ACC | RES | MULT | SHIFT | TAG |
|---:|---:|---:|---:|---:|---:|
| 1 | 32 | 8 | 32 | 7 | 5 |
| 3 | 40 | 8 | 32 | 7 | 9 |
| 3 | 56 | 8 | 32 | 7 | 8 |
| 3 | 32 | 40 | 24 | 8 | 6 |

最后一例残差乘积宽于主乘积，验证max宽度分支而非硬编码80/40。每实例141个接受、136个退休、5个flush取消。包含24个**无gap连续输入**，每周期必须ready，五级模型验证输出对应时序，确认普通模式II=1；覆盖动态ReLU/coeff/mask/meta、>64位乘法和超大shift。融合模式的理论II=1以残差持续可用为前提，不把残差等待时间算作计算吞吐保证。

### 3.3 真实SA南侧FIFO集成

[集成TB](<tb_vpu_fifo.sv>)实例化原有sa_result_fifo，字段按SA实际 `{error,acc_addr,bank,col_mask,psum}` 打包，VPU ready直接控制FIFO pop，未修改PE或FIFO。

每seed36个最终向量、18组融合配对全部正确；观测到85周期FIFO头阻塞、35周期缺残差、104周期深度5 FIFO满，复流后无丢失/重复/错配。错误与mask照常传递，错误向量输出0但融合残差仍被配对消费。

初次集成刺激曾把FIFO的**预留式fire-only push端**误当作可持有VALID的端口，触发保留空间断言；已改为源request等待push_ready，只有request&&ready的fire送到FIFO。没有为通过测试去改FIFO或关断言。

## 4. 失败检测与波形

本机VCS在某些 `$fatal` 场景可能返回0，因此新增 [run_sim.py](<run_sim.py>)：同时检查返回码、当前运行stdout中的Fatal/Error/assertion失败，以及该顶层明确PASS完成标记；缺标记或出现失败即非零退出。自检确认“返回0但Fatal”“PASS后Fatal”“assert失败”“无PASS”“非零返回”均拒绝。每次运行另保存run_status JSON。

- [9场完整回归记录](<build/regress.log>)。
- [主TB seed1](<build/tb_vpu/sim_seed1.log>)、[参数seed1](<build/tb_vpu_params/sim_seed1.log>)、[FIFO集成seed1](<build/tb_vpu_fifo/sim_seed1.log>)。
- [已校验运行状态示例](<build/tb_vpu_fifo/run_status_seed1.json>)。
- [FSDB运行记录](<build/tb_vpu_fsdb/sim_seed1.log>)、[VPU波形](<build/tb_vpu_fsdb/vpu.fsdb>)。

```sh
make -C iVerdi/vpu_unit wave FSDB=1
```

最终构建无宽度/符号或未命名断言lint提示；保留正常TB事件等待 `Lint-[NS]` 与工具LCA提醒。未启动或声称人工逐信号浏览GUI。

## 5. 不能由本次PASS推定的能力

- Raw ACC融合与旧Spec的“Conv3先requant/clip，再两路INT8 Add”通常不等价；需要旧Tiny bittrue时必须保留该边界/两pass，不能直接合并系数。明确反例见 [README](<README.md>)。
- 残差按序配对、无地址比较/重排，配置必须匹配当前main；来源VALID不能依赖READY。局部flush须由控制器与SA FIFO/残差队列协调任务边界。
- 两向量乘法通路不等于只有两个scalar的物理资源预算；48×32可能拆多DSP。未综合，不宣称Fmax/PPA或DSP数量。
- 没有最终INT32范围拒绝、真实DDR/残差DMA、完整旧SoC/Q1命令ABI、全网络Tiny黄金或STA/CDC签核。
