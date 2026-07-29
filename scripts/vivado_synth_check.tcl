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

synth_design -top lissajous_top -part $part_name

# Timing-only constraints for synthesis verification. There are deliberately
# no physical pin or electrical-standard assignments in this project.
create_clock -name pl_clk_50m -period 20.000 [get_ports pl_clk_50m]
set sample_history_regs [get_cells -hier -regexp \
    {.*u_lissajous_core/previous_sample_reg(\[[0-9]+\])?}]
set dac_output_regs [get_cells -hier -regexp \
    {.*u_lissajous_core/da_data_reg(\[[0-9]+\])?}]
set_multicycle_path -setup 4 -from $sample_history_regs -to $dac_output_regs
set_multicycle_path -hold 3 -from $sample_history_regs -to $dac_output_regs

report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $output_dir timing_summary.rpt]

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
