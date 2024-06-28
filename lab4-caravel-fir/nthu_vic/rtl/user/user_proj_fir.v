`timescale 1ns /1ps
// SPDX-FileCopyrightText: 2020 Efabless Corporation
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// SPDX-License-Identifier: Apache-2.0

`default_nettype wire


`define MPRJ_IO_PADS 38

module user_proj_fir #(
    parameter BITS = 32,
    parameter DELAYS=2,
    parameter Tape_Num    = 11
)(
`ifdef USE_POWER_PINS
    inout vccd1,	// User area 1 1.8V supply
    inout vssd1,	// User area 1 digital ground
`endif

    // Wishbone Slave ports (WB MI A)
    input         wb_clk_i,     // clock
    input         wb_rst_i,     // reset (active high)
    input         wbs_stb_i,    // strobe (valid)
    input         wbs_cyc_i,    // cycle (bus cycle in progress)
    input         wbs_we_i,     // READ: 0, WRITE: 1
    input  [3:0]  wbs_sel_i,    // valid data, byte enable for bram
    input  [31:0] wbs_dat_i,    // wishbone data-in
    input  [31:0] wbs_adr_i,    // wishbone addr-in
    output        wbs_ack_o,    // ACK out (ready)
    output [31:0] wbs_dat_o,    // wishbone data-out

    // Logic Analyzer Signals
    input  [127:0] la_data_in,  // 128-input port on user project
    output [127:0] la_data_out, // 128-output port on user project
    input  [127:0] la_oenb,

    // IOs
    input  [`MPRJ_IO_PADS-1:0] io_in,
    output [`MPRJ_IO_PADS-1:0] io_out,
    output [`MPRJ_IO_PADS-1:0] io_oeb,

    // IRQ
    output [2:0] irq
);

    assign irq = 3'b000; // will not be used
    
    wire            usr_decode; // If MPRJ_addr = 0x3800_0000
    wire            fir_decode; // If MPRJ_addr = 0x3000_0000
    wire            wb_valid;   // input by master(VALID)
    reg             wb_ready;   // output by slave(READY)
    wire [3:0]      bram_WE;    // bram write enable(byte)
    wire [31:0]     usr_adr_i;  // address in bram
    wire [BITS-1:0] usr_dat_o;  // bram data_read-out
    wire [BITS-1:0] usr_dat_i;  // bram data write-in

    
//================== Wishbone Handshake Signals ===================== 
//----------------- User Project Area 0x3800_0000 -------------------
    assign usr_decode = (wbs_adr_i[31:16] == 16'h3800)? 1'b1 : 1'b0; // Send to user project memory
    
    assign wb_valid  = wbs_cyc_i && wbs_stb_i && usr_decode; // VALID when both cycle, strobe asserted
    assign wbs_ack_o = wb_ready;  // slave side program READY
    
    assign bram_WE   = wbs_sel_i & {4{wbs_we_i}};  // extend we to 4 bit in order to match the byte enable
    
    // Address 
    assign usr_adr_i = wbs_adr_i;
    
    // Data in/out
    assign wbs_dat_o = usr_dat_o; // RISC-V CPU read the code in out bram
    assign usr_dat_i = wbs_dat_i;
    
    // Delay Count
    reg  [3:0] delay_cnt; // count the delay cycle
    wire [3:0] next_delay_cnt;
    wire       next_wb_ready;
    
    assign next_delay_cnt = (delay_cnt == DELAYS-1)? 4'd0 : delay_cnt + 1'b1;
    assign next_wb_ready  = (delay_cnt == DELAYS-1)? 1'b1 : 1'b0;

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            delay_cnt <= 4'd0;
        end 
        else begin
            if (wb_valid && !wb_ready) begin // If VALID, wait for READY
                delay_cnt <= next_delay_cnt;
            end
            else begin
                delay_cnt <= 4'd0;
            end
        end
    end
    // ready asserted in the next cycle
    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            wb_ready <= 1'b0;
        end
        else begin
            wb_ready <= next_wb_ready;
        end
    end
    
    
    bram user_bram (
        .CLK(wb_clk_i),
        .WE0(bram_WE),
        .EN0(wb_valid),
        .Di0(usr_dat_i),
        .Do0(usr_dat_o),
        .A0 (usr_adr_i)
    );
   
endmodule

`default_nettype wire
