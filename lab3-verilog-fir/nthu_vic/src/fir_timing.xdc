create_clock -period 10.000 -name fir_timing -waveform {0.000 5.000} -add [get_ports axis_clk]
set _xlnx_shared_i0 [all_inputs]
set_input_delay -add_delay 2.000 $_xlnx_shared_i0

set _xlnx_shared_i0 [get_ports -filter { NAME =~  "*" && DIRECTION == "OUT" }]
set_output_delay -add_delay -1.000 $_xlnx_shared_i0
