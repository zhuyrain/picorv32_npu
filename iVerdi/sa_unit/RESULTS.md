# SA 重构验证结果 — 2026-11-03

## 版本与验证范围

- 改造基线：`800e46f`（SA/PE 初版），本报告对应当前未提交的第二版改动。
- 参考软件冻结提交：[`7b2d27f9f65e3ae51a3a20b90ce88caa23aac898`](<https://github.com/zhuyrain/CNN-CIFAR-10/commit/7b2d27f9f65e3ae51a3a20b90ce88caa23aac898>)。[Spec快照](<reference/NPU_Spec.md>)、[矩阵向量](<reference/test_vector_hwc_im2col_tiles.h>) 和 [来源SHA256](<reference/manifest.json>) 未改动；本轮用户32位重构要求与旧ACC48契约的差异见 [README](<README.md>)。
- 验证模块：[PE](<../../npu_rtl/pe.v>)、[SA](<../../npu_rtl/sa.v>)、[本地南侧ACC](<../../npu_rtl/sa_south_acc.v>)、[排空FIFO](<../../npu_rtl/sa_result_fifo.v>)。
- 工具：Synopsys VCS `V-2023.12-SP2_Full64`，`-sverilog +define+SA_CHECKS +lint=all`，Verdi KDB/FSDB。10ns测试时钟仅为功能激励，不是Fmax证明。

## 实际执行与结果

```sh
make -C iVerdi/sa_unit regress
make -C iVerdi/sa_unit test FSDB=1
```

三个顶层分别以seed=1/7/42运行，共9场回归；另有一场FSDB主向量仿真，均通过、退出码0。新增8×8/FIFO17参数用例纳入参数顶层，最终日志以本目录重新运行命令为准。

### 黄金 GEMM：1856个最终元素

| case | M×K×N | 检查元素/seed | 1/7/42 |
|---|---|---:|---|
| 1 | 32×32×16 | 512 | PASS |
| 2 | 32×27×16 | 512 | PASS |
| 3 | 32×8×16 | 512 | PASS |
| 4 | 32×8×8 | 256 | PASS |
| 5 | 8×8×8 | 64 | PASS |

每seed接受616个K块行token，仅产生232个最终向量，全部1856项逐元素匹配。Python任意精度GEMM也独立重算全部参考值。case3–5输入全1；case2按8/8/8/3分块，A/B尾补0，权重bank先全部污染为127再通过逆序级联完整覆盖。

**跨K累加真实发生在RTL南侧ACC内。** TB不再将黄金或实际部分和通过顶部seed反馈；北侧已无in_psum。数学scoreboard在输入握手端使用独立int64上下文，固定时钟token队列与独立结果FIFO逐拍检查输出、顺序、credit、bank/mask/address/error和稳定性。

| seed | 另一bank装载与阵列计算重叠的写握手 | 输出背压周期 |
|---:|---:|---:|
| 1 | 394 | 105 |
| 7 | 381 | 105 |
| 42 | 391 | 143 |

384个non-final更新只保存在南侧，不输出至外部；这不是实际系统SRAM流量/Fmax/PPA测量。

### 自由流水、协议与32位边界

默认8×8、FIFO32的三个seed均接受110个输入行，退休96个最终向量，明确flush/reset丢弃2个尚未退休的最终向量，其余为non-final本地更新。每seed观察到5个credit满额阻塞周期；消费者不ready时仍有南侧提交，分别48/43/46次，证明测试确实覆盖了**下游阻塞但阵列继续排空**，而非沿用旧全局冻结模型。

通过的定向检查：

- 北侧权重逆序整tile、任意bubble、中途错bank拒绝、半装载/半重装拒计算；最终北侧握手后精确等待ROWS个后续边沿的南侧ACK。
- 同拍新计算优先于同bank重载/bias写；阵列仍引用的bank不能覆写；结果已进入FIFO但尚未退休时可重装bank。
- 两bank和多个M槽交织，first/middle/last连续访问同槽；正负bias只first加一次，开放context期间禁止改bias。
- 消费者长期阻塞，填满所有reserved/FIFO额度；新输入停止，但所有在途行自然到达FIFO，bank_busy回到0；释放消费者后按序无丢失/重复。
- 精确守恒断言 `reserved = fifo_level + mesh_inflight <= depth`；non-final释放、final入FIFO转移、外部pop释放，无全局advance。
- signed32正溢出、负溢出、先溢出再反向抵消：均报error2并输出0，不能回绕后冒充成功；mask外列不制造overflow。
- 未初始化累加、重复first、mask改变、缺first后建立poison上下文：报error1，fault粘滞；合法后续任务不偷偷清fault。
- flush清FIFO/ACC/在途管线并保留完整权重/bias；中断装载的bank保持不可用；reset另清bias并使两bank不可用。

### 参数与FIFO回绕

参数顶层并行检查：1×1/FIFO2、1×8/FIFO9、8×1/FIFO9、3×5/FIFO8，以及8×8/FIFO17；均为3个ACC槽。包含最小合法FIFO容量、非2幂深度、超过2倍深度的输出回绕、非法ACC地址3拒绝、满FIFO时阵列排空、4轮K块本地累加与flush后bias保留。三个seed均通过，详见 [参数日志](<build/tb_sa_shapes/sim_seed1.log>)。

## 构建与可打开结果

- [完整回归日志](<build/regress.log>)，各顶层的分seed日志保存在对应build子目录。
- [主向量seed1](<build/tb_sa/sim_seed1.log>)、[协议seed1](<build/tb_sa_protocol/sim_seed1.log>)。
- [FSDB运行记录](<build/tb_sa_fsdb/sim_seed1.log>)、[当前SA波形](<build/tb_sa_fsdb/sa.fsdb>)；打开命令 `make -C iVerdi/sa_unit wave FSDB=1`。

最终RTL无宽度/符号或未命名断言lint提示；测试台保留正常事件等待的 `Lint-[NS]`，工具提示 `LCA_FEATURES_ENABLED`。覆盖既有FSDB时还会有dumper的覆盖提醒。这不等同专业静态lint/形式/物理签核；未启动或声称人工逐信号浏览桌面GUI。

## 明确限制

- 32位profile不保证原ACC48的宽中间抵消语义；任何中间signed32溢出都诊断失败，不能宣称任意2^18项乘积加任意INT32 bias均精确。见 [数值/PPA取舍](<README.md>)。
- 北侧仅保留COLS个权重入口扇出，后续逐跳；clock/reset/flush仍需正常物理设计。新增FIFO/寄存器ACC可能增加总面积/动态功耗，不能凭去advance与缩位推定PPA改善。
- 本地ACC为寄存器数组，不是已验证SRAM宏实现。若改同步读SRAM，必须重做RMW旁路、端口与时序/credit设计。
- 当前DMA/命令队列/完整K_total与依赖检查/量化/IRQ仍未实现；DMA集成必须遵守ready/valid，不能仅延迟响应almost_full。
- 旧SoC wrapper端口尚未迁移，不能直接运行旧卷积固件；本次没有原SoC、全网络、PPA/STA/CDC签核结论。
