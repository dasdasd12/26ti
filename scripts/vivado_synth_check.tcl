set project_root [file normalize [file join [file dirname [info script]] ..]]
set tool_version [version -short]
if {![string match "2019.2*" $tool_version]} {
    puts "ERROR: Vivado 2019.2 is required, found $tool_version"
    exit 5
}
if {[info exists ::env(FPGA_PART)] && ($::env(FPGA_PART) ne "")} {
    set part_name $::env(FPGA_PART)
} else {
    set part_name xc7z020clg400-2
}
set output_dir [file join $project_root build vivado_synth_check $part_name]
file mkdir $output_dir

set rtl_files [glob -nocomplain [file join $project_root rtl *.sv]]
if {[llength $rtl_files] == 0} {
    puts "ERROR: no RTL files found"
    exit 2
}

read_verilog -sv $rtl_files
read_verilog -sv [file join $project_root scripts vivado_ip_stubs.sv]

synth_design -top lissajous_top -part $part_name

# Timing-only constraints for synthesis verification. The Clocking Wizard is
# a black box in this standalone source check, so constrain its two output
# pins explicitly. A normal Vivado project obtains equivalent generated clocks
# from the generated clk_wiz_0 IP.
create_clock -name pl_clk_50m -period 20.000 [get_ports pl_clk_50m]
set sys_clk_pin [get_pins -quiet u_system_clock_pll/clk_out1]
set converter_clk_pin [get_pins -quiet u_system_clock_pll/clk_out2]
if {[llength $sys_clk_pin] != 1 ||
    [llength $converter_clk_pin] != 1} {
    puts "ERROR: clk_wiz_0 output pins were not found"
    exit 6
}
create_clock -name sys_clk_100m -period 10.000 $sys_clk_pin
create_clock -name converter_clk_30m -period 33.333 $converter_clk_pin

# Every control crossing between these domains has an explicit synchronizer.
# Treat the standalone black-box clocks as asynchronous; the real Clocking
# Wizard project may instead retain their generated-clock relationship.
set_clock_groups -asynchronous \
    -group [get_clocks pl_clk_50m] \
    -group [get_clocks sys_clk_100m] \
    -group [get_clocks converter_clk_30m]

report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 50 \
    -file [file join $output_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 50 -nworst 5 \
    -file [file join $output_dir timing_paths.rpt]
check_timing -verbose \
    -file [file join $output_dir check_timing.rpt]

set stale_cells [get_cells -hier -quiet -filter \
    {NAME =~ *fractional_phase_calibrator*}]
if {[llength $stale_cells] != 0} {
    puts "ERROR: stale fractional_phase_calibrator logic is still present"
    exit 7
}

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    puts "ERROR: no timing path was produced"
    exit 3
}

set worst_slack [get_property SLACK [lindex $timing_paths 0]]
puts "SYNTH_CHECK_WORST_SLACK_NS=$worst_slack"
if {$worst_slack < 0.0} {
    puts "ERROR: synthesized design does not meet timing"
    exit 4
}

puts "SYNTH_CHECK_PASS tool=$tool_version part=$part_name"
exit 0
