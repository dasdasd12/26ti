# 李萨如图形控制装置 FPGA 初版

本工程面向 Vivado 2019.2，完成题目第 1～4 问所需的 FPGA RTL 初步搭建。当前版本使用 10 位并行 AD/DA、100 MHz 系统时钟和 30 MHz AD/DA 时钟，不包含引脚约束。

## 当前信号通路

### 有线模式：DAC1 连续 DPLL

AD1 的每一个采样点都会送入 `continuous_iq_dpll.sv`，有效路径已经完全取消过零检测，也不使用 AD2 回环或 KEY4 的无线校准结果。

DPLL 分为三步：

1. 在 1～110 kHz 范围内，以 1 kHz 间隔执行 1 ms I/Q 相关粗扫。
2. 在最佳粗扫点附近，以 100 Hz 间隔和 262144 点窗口执行 I/Q 相关细扫。
3. 进入连续跟踪，用 CORDIC 求复相关向量相角；20 kHz 及以上使用 65536 点窗口，低频使用 262144 点窗口。相邻块相角差修正 48 位 DDS 频率字，绝对相角修正输出相位。

跟踪窗口都是 2 的幂，频率校正只需要算术移位，不在实时 DPLL 路径中使用除法。参考正弦和对应 ADC 样点同时寄存一级，使插值 LUT 与后续 I/Q、幅值比较和频率字更新之间形成明确的流水线边界。

进入跟踪状态后，DAC1 会持续输出。短时频率漂移可能使调试用 `locked` 标志暂时清零，但不会中断 DAC1；只有连续相关能量不足、DPLL 返回重新扫频时，DAC1 才回到中值码。

DAC1 的图形由同一条 DPLL 相位产生：

- 直线：与 AD1 同频、同相的 DDS 正弦。
- 正交：在锁定相位上增加 90°。
- 二倍频：使用两倍锁定相位。

这不是复制 ADC 样本。输出幅度由 DDS 固定生成，不跟随输入瞬时幅度抖动。

### KEY4 校准与 DAC2

KEY4 启动一条完全独立的 10 kHz 全采样 I/Q 频率校准通路。默认参数使用 1 ms 数据块并平均 256 次相邻块估计，约 257 ms 完成。锁定后冻结 48 位频率字，LED4 点亮。

这条冻结结果只供 DAC2 和无线模式使用，绝不控制有线 DAC1：

- 校准完成前，DAC2 输出中值码 512。
- 校准完成后，DAC2 默认输出 `10 kHz × 489 / 50 = 97.8 kHz` 正弦。
- KEY5 在 97.8 kHz 和校准后的 10 kHz 之间切换。
- 再按 KEY4 会重新校准；校准期间 DAC1 的连续 DPLL 输出不受影响。

97.8 kHz 的频率字直接由校准结果计算：

```text
phase_step_97k8 = round(phase_step_10k × 489 / 50)
```

因此两种 DAC2 频率继承相同的晶振 ppm 校正。

### 无线模式

无线模式下 DAC1、DAC2 输出相同的周期性锯齿脉冲。重复周期为 10 ms：每个周期开始发送一个 10 kHz 单周期上升锯齿，其余时间保持高电平。若 KEY4 已完成校准，锯齿使用冻结的 10 kHz 频率字；否则使用标称 30 MHz 计算值。

无线内容仍是预留实现，尚未接入摄像头闭环。

## 按键和 LED

所有按键和四个 PL LED 都按低有效处理。

| 控件 | 有线模式功能 |
|---|---|
| KEY1 | 切换有线/无线模式 |
| KEY2 | 直线 → 正交 → 二倍频循环 |
| KEY3 | 1/4 → 1/2 → 3/4 → 满幅循环；复位默认满幅 |
| KEY4 | 启动或重新启动独立 10 kHz 频率校准 |
| KEY5 | DAC2 在 97.8 kHz / 10 kHz 之间切换；复位默认 97.8 kHz |
| KEY6 | 未使用 |

| LED | 点亮条件 |
|---|---|
| LED1 | 无线模式 |
| LED2 | 不使用，恒灭 |
| LED3 | 不使用，恒灭 |
| LED4 | KEY4 的 10 kHz 频率校准完成 |

LED 不闪烁。Mizar Z7 的 PL 侧只有四个板载用户按键，因此 `key5_n` 若要实际上板使用，需要另接外部按键或复用其他输入；本工程不提供该引脚约束。

## 幅度和编码

AD/DA 均使用 10 位 offset-binary：

- 满量程：±5 V，对应 0～1023。
- 当前目标幅度：±2 V，即 4 Vpp。
- 中值码：512。
- 数字峰值：`round(512 × 2 / 5) = 205`。
- 未反相的目标范围：307～717。

板外模拟输出级会反相，因此顶层在送往 DAC 前执行 `1024-code` 数字反相。数字总线范围仍为 307～717，经过模拟反相后才得到预期方向。无线锯齿在 FPGA 端表现为 717 向 307 下降，经过模拟反相后为 −2 V 向 +2 V 上升。

## 时钟、复位和接口

顶层 `lissajous_top.sv` 直接预留 `clk_wiz_0`：

```text
clk_in1  = 50 MHz
clk_out1 = 100 MHz  系统/按键域
clk_out2 = 30 MHz   AD、DA、DPLL、DDS 域
```

请在 Vivado 2019.2 中生成同名 Clocking Wizard IP，端口为 `clk_in1`、`clk_out1`、`clk_out2` 和 `locked`。仿真使用 `sim/clk_wiz_0_sim.sv`，不要把该仿真模型加入综合源。

工程没有外部复位端口。PLL 锁定后，`soft_power_on_reset.sv` 自动产生内部软复位；30 MHz 域再同步释放复位。

AD1、AD2、DA1、DA2 各自有独立的时钟输出端口。四路时钟目前同为 30 MHz、同相，并分别由独立 Xilinx `ODDR` 原语转发到顶层端口，ODDR 输出不回读到 fabric。AD1/AD2 的 OE 均固定为低有效。

主要端口：

- AD1：`ad_data[9:0]`、`ad_clk`、`ad_oe_n`
- AD2：`ad2_data[9:0]`、`ad2_clk`、`ad2_oe_n`
- DA1：`da_data[9:0]`、`da_clk`
- DA2：`da2_data[9:0]`、`da2_clk`

AD2 目前仅保留作后续无线反馈接口，不参与有线 DPLL。

工程不含 `PACKAGE_PIN`、`IOSTANDARD` 或外部输入输出延时约束，需要根据最终 AD/DA 型号和实际接线补充。

## ILA

当前 ILA 连接为：

- `probe0`：AD1 原始 10 位数据。
- `probe1`：DAC1 顶层 10 位数据。
- `probe2`：有线 DPLL 的严格锁定标志。
- `probe3`：32 位 DPLL 相位误差字的高 16 位。
- `probe4`：`probe3[15:8]`。

`probe3` 保留了旧信号名 `phase_error_q8`，但当前不再表示“采样点误差”。其 1 LSB 等于一周的 `1/65536`，约为 0.005493°。

## 主要 RTL 文件

- `rtl/lissajous_top.sv`：顶层时钟、跨时钟、按键、ILA 和双 DAC 路由。
- `rtl/lissajous_core.sv`：AD1 预处理、连续 DPLL、图形和幅度控制。
- `rtl/continuous_iq_dpll.sv`：无过零的全采样 I/Q 捕获与连续锁相/锁频环。
- `rtl/cordic_atan2.sv`：DPLL 复相关向量相角计算。
- `rtl/reference_frequency_calibrator.sv`：KEY4 独立 10 kHz 全采样 I/Q 频率校准。
- `rtl/calibrated_sine_test_tone.sv`：DAC2 的校准 10 kHz / 97.8 kHz 正弦。
- `rtl/dds_sine_lut.sv`：DDS 正弦查找与插值。
- `rtl/wireless_sawtooth_pulse.sv`：10 ms 周期锯齿脉冲。
- `rtl/manual_control.sv`、`rtl/button_debounce.sv`：按键控制。
- `rtl/status_leds.sv`：四个低有效 LED。

旧的 `fractional_phase_calibrator.sv`、`phase_step_divider.sv` 和 `ad_da_clock_gen.sv` 已删除；有效设计中不存在过零检测通路，也不存在旧的 ODDR 输出回读结构。

## 仿真

使用 Icarus Verilog/SystemVerilog：

```powershell
.\run_sim.ps1
```

默认测试覆盖 1 kHz / 100 kHz DPLL 捕获和重捕获、三种图形、四档幅度及 KEY5 对 DAC1 的隔离。

DAC2 和 KEY4 专项：

```powershell
.\run_sim.ps1 -Testbench sim/tb_wired_calibration_output.sv `
  -Top tb_wired_calibration_output `
  -Output icarus/tb_wired_calibration_output.vvp `
  -Waveform sim/tb_wired_calibration_output.vcd
```

DPLL 单元专项：

```powershell
.\run_sim.ps1 -Testbench sim/tb_continuous_iq_dpll.sv `
  -Top tb_continuous_iq_dpll `
  -Output icarus/tb_continuous_iq_dpll.vvp `
  -Waveform sim/tb_continuous_iq_dpll.vcd
```

97.8～100 kHz 高频专项：

```powershell
.\run_sim.ps1 -Testbench sim/tb_high_frequency_dpll.sv `
  -Top tb_high_frequency_dpll `
  -Output icarus/tb_high_frequency_dpll.vvp `
  -Waveform sim/tb_high_frequency_dpll.vcd
```

当前回归结果：

- 97.80037 kHz、99.00023 kHz、100.00525 kHz 分别跟踪为 97.800370479 kHz、99.000231204 kHz、100.005247407 kHz。
- 10.10037 kHz 跟踪为 10.100277918 kHz；继续漂移到 10.10087 kHz 后无需返回扫频，跟踪为 10.100812643 kHz。
- 1 kHz、10 kHz、12 kHz、37.40023 kHz、100 kHz 捕获/重捕获通过。
- DAC1 图形、幅度、连续输出，以及 KEY4 校准期间隔离通过。
- DAC2 默认 97.8 kHz、KEY5 切换 10 kHz、再切回 97.8 kHz通过。
- 回归波形中的锁定、跟踪、DAC 数据和各频率字在初始化后均无 X/Z。

## Vivado 2019.2 时序检查

可运行：

```powershell
& 'C:\program1\Xilinx\Vivado\2019.2\bin\vivado.bat' `
  -mode batch -source scripts/vivado_synth_check.tcl `
  -nojournal -nolog
```

当前 `xc7z020clg400-2` 综合后内部时序检查结果为：

- 总体 WNS：+6.856 ns，TNS：0。
- 30 MHz AD/DA 域 WNS：+12.291 ns。
- 100 MHz 系统域 WNS：+6.856 ns。
- 资源估计：4352 LUT、2764 寄存器、51 DSP。

这是无布局布线的综合时序检查。工程按要求没有引脚、`IOSTANDARD` 和外部 I/O delay 约束，因此生成 bitstream 前仍需补齐这些约束，并以实现后的 timing summary 为最终依据。

若 Vivado GUI 仍显示从
`u_fractional_phase_calibrator/phase_calibration_q8_reg` 出发的路径，
说明工程还在使用旧 source set 或旧综合检查点。请从工程中移除已删除的
`fractional_phase_calibrator.sv`、`phase_step_divider.sv`，
确认核心文件指向当前 `rtl/lissajous_core.sv`，然后依次 Reset Runs
中的 `synth_1` 和 `impl_1` 后重新运行。
