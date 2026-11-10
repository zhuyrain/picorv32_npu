# SA/VPU 真实联合仿真结果 — 2026-11-04

## 1. 提交与范围

已按用户要求先提交此前VPU工作区：**`be0e35e`**，message：`实现独立向量 VPU 及持久量化与残差融合验证`。

本轮新增本目录的真实联合测试/持久数据/文档，未再次提交或推送。Git检查确认现有SA、PE、南侧ACC/FIFO、VPU及既有单元验证源码均相对该提交无变动，联合验证未发现需要修改RTL的功能问题。

[主联合TB](<tb_sa_vpu_joint.sv>)直接连接实际 [SA](<../../npu_rtl/sa.v>) 的内部南侧FIFO输出到实际 [VPU](<../../npu_rtl/npu_vpu.v>)。未用期待MAC替代SA输出，也未把黄金结果反馈成下一轮输入。

## 2. 持久输入、identity与量化参数

A/B来自 [原im2col头文件](<../sa_unit/reference/test_vector_hwc_im2col_tiles.h>)，原始SHA和source commit由 [manifest](<vectors/manifest.json>)校验。Python任意精度GEMM重算全部1856个C元素，并与头文件expected逐项一致，bias=0。

每组生成独立的M×N随机signed INT8 identity（[-127,127]），seed为固定base `0x5341565055323036` 加case号。完整矩阵/三种后处理黄金在 [vectors.json](<vectors/vectors.json>)，全部case HEX与119位 [params](<vectors/params.hex>)保留在vectors目录，不是临时build文件，没有删除。默认回归只读校验，显式generate才重生成。

每case按整层统一系数，所有lane共享本层M0/M1/SHIFT，不用per-channel系数。M0以裸MAC绝对峰值映射到约80（整数nearest half-up），M1取32768、SHIFT=16，使残差有效增益为0.5：

| case | M×K×N | MULT_MAIN | MULT_IDENTITY | SHIFT | fused饱和元素 |
|---|---|---:|---:|---:|---:|
| 1 | 32×32×16 | 234 | 32768 | 16 | 0 |
| 2 | 32×27×16 | 234 | 32768 | 16 | 0 |
| 3 | 32×8×16 | 38269 | 32768 | 16 | 4 |
| 4 | 32×8×8 | 38269 | 32768 | 16 | 2 |
| 5 | 8×8×8 | 38269 | 32768 | 16 | 1 |

共同右移前的定义是 `C*M0 + identity*M1`，不是预处理A/B或分K量化。融合黄金：`clip((C*M0+R*M1)>>>16,-127,127)`，ReLU profile再max(0,...)。这是合成范围校准，不是从缺失的模型scale元数据恢复真实训练网络量化。

## 3. 实际执行

工具：Synopsys VCS `V-2023.12-SP2_Full64`，SystemVerilog，SA/VPU_CHECKS、`+lint=all`、KDB/FSDB；10ns时钟为功能激励。

```sh
python3 iVerdi/sa_vpu_joint/gen_vectors.py --check
python3 iVerdi/sa_vpu_joint/run_sim.py --self-test
make -C iVerdi/sa_vpu_joint regress
make -C iVerdi/sa_vpu_joint test FSDB=1
make -C iVerdi/sa_vpu_joint test TOP=tb_sa_vpu_joint_fifo17 FSDB=1
```

**FIFO32与FIFO17两个配置，各seed=1/7/42，共6场最终回归全部PASS。** 两个配置另各有一场FSDB仿真，均PASS。运行器检查返回码、Fatal/assert失败及明确完成标记，各run_status均passed=true；`git diff --check`通过。

### 功能与数值

每场三种profile×五组矩阵：ordinary/ReLU关、fused/ReLU关、fused/ReLU开。均成功核对：

- **5568个最终INT8元素**，包括三profile各1856个元素。
- **5568个原始MAC元素**；实际SA FIFO头每个valid周期（包括blocked）都比对期待C，唯一元素计数只按fire。
- 1848个SA输入K行token、696个最终SA/VPU向量、464次原子残差配对。
- case1 K32零尾、case2 K27按8/8/8/3；case3–5激活全1。
- 双bank逆序装载/并行预载、仅南侧本地ACC跨K、无部分和外部反馈。
- 独立残差按N-tile优先再M行顺序配对；bank/slot/tag/mask/error正确，ordinary不消费残差。
- case间不reset；全部旧输出退休且VPU5级为空之后才切换逐层系数/模式。

### 真实端到端反压

profile1/case1停止最终消费者，等待实际SA FIFO Q达到深度且reserved满额，并确认bank_busy=0，再保持25周期主动释放。释放线程不等待生产者结束，实际证明旧阵列结果自然排空而不是把PE冻结。

| FIFO深度 | seed | SA输入credit阻塞周期 | FIFO实际满周期 | 缺残差等待周期 | 下游停止时SA南侧仍提交 |
|---:|---:|---:|---:|---:|---:|
| 32 | 1 | 45 | 25 | 1703 | 532 |
| 32 | 7 | 53 | 25 | 1752 | 541 |
| 32 | 42 | 47 | 25 | 1721 | 574 |
| 17 | 1 | 38 | 25 | 1682 | 470 |
| 17 | 7 | 37 | 25 | 1728 | 506 |
| 17 | 42 | 36 | 25 | 1696 | 522 |

释放后全部结果按序无丢失/重复、无fault/context残留。SA FIFO头、VPU输出和残差源在各自blocked期间的稳定性均检查。FIFO17覆盖非2幂回绕。

## 4. 日志、波形与复现入口

- [完整6场回归日志](<build/regress.log>)。
- [FIFO32 seed1](<build/tb_sa_vpu_joint/sim_seed1.log>)、[FIFO17 seed1](<build/tb_sa_vpu_joint_fifo17/sim_seed1.log>)。
- [检查后的运行状态示例](<build/tb_sa_vpu_joint_fifo17_fsdb/run_status_seed1.json>)。
- [FIFO32波形](<build/tb_sa_vpu_joint_fsdb/joint.fsdb>)、[FIFO17波形](<build/tb_sa_vpu_joint_fifo17_fsdb/joint.fsdb>)。

```sh
make -C iVerdi/sa_vpu_joint wave FSDB=1
make -C iVerdi/sa_vpu_joint wave TOP=tb_sa_vpu_joint_fifo17 FSDB=1
```

最终构建无宽度/符号或未命名断言lint提示；保留TB事件等待空语句与LCA提醒。不把功能仿真称作物理签核，也没有启动或声称人工逐信号浏览桌面GUI。

## 5. 设计取舍与未覆盖

逐层量化形式不等于真实模型校准；header没有实际分支scale，随机identity也不是实际网络shortcut。本轮只验当前raw融合公式，不能自动代替旧Spec的“Conv3先requant/clip，再INT8 Add”边界。反例与参数推导见 [README](<README.md>)。

硬件tag只编码local bank/ACC slot，全局矩阵位置靠有序流重建，不冒充完整global row ID。当前header无M/N ragged尾，K尾A为0也会掩盖B尾残留，因此不能仅以C正确宣称所有低层尾写行为已独立证明；仍需结合已有SA权重捕获测试。默认80位极端乘法主要由已提交VPU单测覆盖。

没有真实DMA/DDR、命令ABI、训练模型精度、全网络bittrue、联合中途flush/跨epoch取消或PPA/STA/CDC验收。硬件源无改动不等于已经完成系统级集成。
