四类缓存分离、局部零基址；
n_tile → m_tile → k_tile → row 的顺序；
每个 N-tile 更新一次 Bias；
跨 K 使用南侧本地 ACC；
独立权重预取，以及最后结果真正写回后才完成任务。
在以上寄出约束的前提下满足以下要求：
1. 残差使用单独的buffer进行片上缓存
2. 使用原来的VPU模块做后处理
3. 单块片上 Buffer 的位宽定为 64-bit，BIAS buffer的位宽暂时定位256-bit。控制寄存器接口保持 32-bit。
4. 明确以下访问访问方向：
缓存	内部计算侧	外部侧的基本用途
Weight / Activation / Bias	读	写入预装
Output	写	读取结果
这个定向版本使用独立1R1W存储。
5. 运行中DMA不能覆盖本任务稍后还会读取的输入区域： 目前DMA无需实现双Bank设计
6. Sequencer应维护每bank的驻留标签，例如：{valid, task_generation, n_tile, k_tile, loading}
7. 从选定本K块开始，到最后一行激活成功握手之前，都不能让loader驱逐该bank
8. compute_bank与load_bank分别管理
9. Output地址 = (所属m_tile*ACC_ROWS + 输出slot)*n_tiles + 所属n_tile
使用该结果所属的坐标，不使用实时发射计数器。
至少分开：
激活发射游标；
SA→VPU/残差配对游标；
最终写回游标。
