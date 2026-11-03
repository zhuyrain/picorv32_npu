# SA 独立验证结果 — 2026-11-02

## 版本与范围

- 硬件改造前基线：`d1299002ef3a4b6e9213bc58c30619c2a93bb3de`，本报告对应当前未提交改动。
- 软件分支 `duos_tpu` 固定提交：[`7b2d27f9f65e3ae51a3a20b90ce88caa23aac898`](<https://github.com/zhuyrain/CNN-CIFAR-10/commit/7b2d27f9f65e3ae51a3a20b90ce88caa23aac898>)。
- 已完整读取并冻结 [NPU Spec](<reference/NPU_Spec.md>)、[五组矩阵向量](<reference/test_vector_hwc_im2col_tiles.h>)；来源 URL/SHA256 见 [manifest](<reference/manifest.json>)。生成器默认强制核验向量哈希，再独立重算黄金值。
- 对象：[SA](<../../npu_rtl/sa.v>)、[PE](<../../npu_rtl/pe.v>)。默认64个 PE，每 PE **仅两个 INT8 权重寄存器**，共128B权重数据；没有权重循环索引或9/64项权重RF。seed/psum 全链48位。
- 工具：Synopsys VCS `V-2023.12-SP2_Full64`，SystemVerilog、`SA_CHECKS`，Verdi KDB/FSDB。测试时钟10ns只是仿真激励，不是100MHz时序收敛证明。

## 实际执行

```sh
make -C iVerdi/sa_unit regress
make -C iVerdi/sa_unit test FSDB=1
```

全部退出码为0。`regress`对三个顶层分别执行 seed=1/7/42，共9场仿真；shape测试使用固定背压，因此其三个seed重复同一参数用例。FSDB单独再跑一场主向量测试，亦通过。

### 五组黄金 GEMM

| case | M×K×N | 每次检查元素 | 三个seed |
|---|---|---:|---|
| 1 | 32×32×16 | 512 | PASS |
| 2 | 32×27×16 | 512 | PASS |
| 3 | 32×8×16 | 512 | PASS |
| 4 | 32×8×8 | 256 | PASS |
| 5 | 8×8×8 | 64 | PASS |

每个seed检查全部1856个最终输出、616行物理 K 块结果；独立 Python 任意精度整数 GEMM也验证全部1856项。没有 bias/量化/clip/ReLU。case3–5的A为**全1**。case2按8/8/8/3分块，A尾列/B尾行补0，权重bank先完整污染为127再全行覆盖。跨K种子取自实际上一块输出，未把黄金中间结果喂回 DUT。

| seed | 计算期间另一bank写握手 | 输出背压周期 |
|---:|---:|---:|
| 1 | 381 | 342 |
| 7 | 374 | 304 |
| 42 | 378 | 346 |

### 协议与数值边界

三个seed均接受88行，正常退休86行，flush/reset各主动丢弃1行；背压周期分别58/54/60，冻结期间另一bank各完成8次权重写。

通过的定向检查：

- 未加载/半加载/半重装bank不能接收输入；完整bank重装首行撤销旧ready。
- 同拍同bank新计算优先，禁止覆写计算或输出尚未退休的bank。
- 连续32行混bank、随机输入bubble/反压/列mask；逐周期检查精确15级有效时序与输出稳定性。
- 不同行/列不同正负宽seed；INT32中间越界后用实际结果反馈、反向K块抵消回原范围，未中途截32位。
- 有符号激活与127/-127/-128二补码边界；mask=0输出0且行token保留。
- flush取消被阻塞输出并保留权重；reset取消在途输出并使两个bank重新不可用。

### 参数分支

1×1、1×8、8×1、3×5各连续输入32行，混bank、非零宽seed和固定反压全部PASS；检查空skew/deskew边界及非法物理行编码无副作用。

### 构建与波形

最终 `+lint=all` 构建未出现 RTL 宽度/符号或未命名断言提示。保留的提示为测试台事件等待空语句 `Lint-[NS]` 与工具 `LCA_FEATURES_ENABLED` 提醒；不把它表述为零提示或专业静态lint签核。

- [完整回归日志](<build/regress.log>)；各顶层分seed日志位于各自build目录。
- [FSDB运行日志](<build/tb_sa_fsdb/sim_seed1.log>)、[SA波形](<build/tb_sa_fsdb/sa.fsdb>)；KDB位于相同目录。已生成波形，未启动桌面GUI或声称人工逐信号浏览。
- 打开波形：`make -C iVerdi/sa_unit wave FSDB=1`。

## 未实现 / 未验收

这是Q1的 **单8×8 WS计算原语**，不是完整NPU Spec实现。跨K持久ACC在本次TB中模拟；DMA/片上SP与ACC SRAM、命令队列、INIT/FINAL上下文、最终INT32溢出检查、量化与IRQ均未实现/未验证。

旧卷积wrapper仍连接旧SA端口、外部skew和32位ACC，**尚不兼容新接口，原SoC构建/固件不能直接沿用**；本次刻意使用独立顶层，未声称原SoC回归通过。后续应单独迁移EX馈送与ACC，再连接DMA/队列，而非把新SA直接接旧packed卷积流。

未进行综合/PPA/Fmax/时序签核、CDC或全网络16项黄金验收；未声称完成Spec的其他里程碑。接口、重装规则和复现方式见 [README](<README.md>)。
