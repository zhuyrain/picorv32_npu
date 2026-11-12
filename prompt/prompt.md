基础约束：
1. 五类缓存物理分离（Weight / Activation / Bias / Residual / Output）、局部零基址；
2. 严格遵循 n_tile → m_tile → k_tile → row 的循环顺序；
3. 每个 n_tile 更新一次 Bias；跨 K 使用南侧本地 ACC 累加；
4. 独立权重预取，且必须等最后一笔结果流过 VPU 并真正写入 Output Buffer 后才拉高任务 done。
具体修正与补充要求：
1. 新增独立残差缓存（res_buf）：残差（Identity）使用单独的第 5 个片上 Buffer 进行缓存，采用与 Output Buffer 完全相同的 [M][N_tiles][64-bit] NHWC 零基址排布。
2. 统一使用现有 VPU 模块做后处理（仅支持 INT8 写回）：串联已验证的 VPU（支持 ready/valid、tag、mask、error 及残差配对），固定工作于 INT8 量化输出模式；不支持将 SA 的 48-bit RAW 宽累加值绕过 VPU 写回 Output Buffer。
3. 缓存位宽与控制接口位宽：Weight / Activation / Residual / Output 单块缓存的数据位宽统一为 64-bit（8 * 8-bit），Bias 缓存的数据位宽定为 256-bit（8 * 32-bit）；控制寄存器（CSR）接口保持 32-bit。
4. 明确 1R1W 定向访问方向：
   1. Weight / Activation / Bias / Residual：内部计算侧只读，外部侧（DMA/TB）只写（预装填）；
   2. Output：内部计算侧只写，外部侧（DMA/TB）只读（读取结果）；
   3. 全部采用独立的标准 1R1W（一读一写伪双端口）存储结构。
   4. 各片上缓存深度全部参数化定义（地址位宽由 $clog2(DEPTH) 自动推导），默认参数设为：WGT_DEPTH = 512、ACT_DEPTH = 512、RES_DEPTH = 512、OUT_DEPTH = 512（对应单块 64-bit × 512 的 4KB BRAM，支持最大 64×64×64等任意乘积不超限的分块组合），BIAS_DEPTH = 64。
5. 单任务串行边界（不做任务级双页缓存）：运行期间外部 DMA 严禁覆盖当前任务尚未读完的输入区域；各缓存无需实现跨任务的 Ping-Pong 双页设计。
6. 维护 Weight Bank 驻留标签（Residency Tag）：Sequencer 需为 sa.v 的两个物理权重 Bank（Bank 0/1）分别维护驻留状态标签 {valid, task_gen, n_tile, k_tile, loading}。当最后一行权重发完后需等待南侧加载完成（bank_ready 重新拉高且 loading 结束）才将标签置为 valid；仅当目标 (n_tile, k_tile) 与某 Bank 标签匹配且 valid == 1 时，才允许发射该块的激活。
7. 计算 Bank 保留锁（防中途驱逐）：从激活发射器选定某个 (n_tile, k_tile) 对应的 Bank 开始，直到需要该权重的所有激活行（含 k_tiles == 1 时跨多个 m_tile 复用的情况）全部完成 in_fire 握手、且 sa.v 的 bank_busy 归零之前，必须锁住该 Bank，严禁 Weight Loader 驱逐或覆写该 Bank。
8. compute_bank 与 load_bank 解耦管理：激活发射侧使用的 compute_bank 与权重加载侧使用的 load_bank 必须独立维护，Loader 翻转 load_bank 时绝不能顺带篡改激活侧正在使用的 compute_bank。
9. 三游标解耦（严禁使用发射侧实时计数器寻址输出）：
   1. 激活发射游标：跟踪 (issue_n, issue_m, issue_k, issue_row)，随 sa 输入握手推进；
   2. SA→VPU 残差配对游标：跟踪已完成 K 累加并从 sa 吐出的 (pair_n, pair_m, pair_row_cnt)，根据 (pair_m * ACC_ROWS + sa_out_acc_addr) * n_tiles + pair_n 计算地址读取 res_buf，并将该目标写回地址（或坐标）通过 VPU 的 tag 端口随数据打拍透传；
   3. 最终写回游标：跟踪从 VPU 退休输出的记账计数，利用透传出的地址（或独立退休坐标 (wb_n, wb_m)）写入 Output Buffer，计满 n_tiles * m_tiles * ACC_ROWS 笔写回后置位任务 done。

针对 ⑤ ~ ⑧ 点的补充实现约束（接前文 1 ~ 9 条）：

1. 同步 SRAM 读请求与响应解耦（对应第 ⑤ 点）：
   1. 五类缓存全部采用 1 拍同步读（Registered Read），严禁退化为大位宽组合逻辑读。
   2. 在每个读取通道（Weight / Activation / Bias / Residual）与下游消费者之间，实现轻量级 响应保持队列 / Skid Buffer（如容量 response_capacity = 2），严格遵守 pending_reads + held_responses <= response_capacity 的信用预留约束。
   3. **读请求游标（req_cursor）**按 SRAM 读请求发射（req_fire）推进；**执行/发射游标（exec_cursor）**按 sa.v / vpu.v 实际输入握手推进，返回的 SRAM 数据与伴随元数据（bank / row / first / last / addr）同步存入保持队列，确保反压时不丢数、不错拍。
2. 任务配置快照与参数解耦（对应第 ⑥ 点）：
   1. 首版约定输入矩阵均已完整 Padding 对齐为整块（m_tiles * ACC_ROWS、k_tiles * ROWS、n_tiles * COLS），支持传入任务级列掩码配置。
   2. 任务启动（cmd_fire）时，一次性锁存 m_tiles, k_tiles, n_tiles 以及 VPU 所需的全部后处理配置（MULT, SHIFT, relu_en, res_en 等），任务运行期间（busy == 1）忽略外部配置端口变化。
   3. 严禁混用 ROWS（K维并行度）与 ACC_ROWS（M维累加槽数）。
   4. 任务启动时自动检查零维度（任一 tile 数为 0）及缓存容量越界（对比 각 Buffer 物理深度参数），若违例则立即拒绝执行并置位错误标志，不启动内部状态机。
3. Bias 切换防死锁约定（对应第 ⑦ 点）：
   1. 仅在每个 n_tile 开始前（发起该 n_tile 的首个 m_tile=0, k_tile=0 激活之前）读取 Bias Buffer 并等待 sa.v 的 bias_ready 完成握手；严禁在非最终 k_tile 之间等待 acc_busy 清零。
   2. VPU 量化配置在整个任务期间保持恒定，无需跨 n_tile 切换 VPU 配置。
4. 任务完成、错误与 flush 完整语义（对应第 ⑧ 点）：
   1. 维护明确的任务结果状态输出（如 done、result_valid、fault/error）：仅当全部 n_tiles * m_tiles * ACC_ROWS 笔输出无错写入 Output Buffer 后，才置位 done = 1, result_valid = 1。
   2. 若运行中检测到配置非法、sa.v 报错或 vpu.v 报错，记录错误状态并拉高 fault/error，且 result_valid 保持为 0。
   3. 触发 flush 时，同步清空 Sequencer 全部游标、SRAM 未决读计数与响应保持队列、Weight Bank 驻留标签，并向 sa.v 和 vpu.v 传递 flush，同时将 result_valid 置 0。
5. Output 整表提交后读取约定：
   1. 由于计算按 n_tile 优先产生而写回按行优先地址落盘，约定外部 DMA / Testbench 仅在 done && result_valid 拉高后才从地址 0 读取 Output Buffer，首版无需维护分块级提前读取位图。