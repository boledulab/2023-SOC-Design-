`timescale 1ns / 1ps

`define SS_IDLE 1'b1
`define SS_DONE 1'b0

`define SM_IDLE 1'b1
`define SM_DONE 1'b0

`define AP_PROC 2'b00
`define AP_IDLE 2'b01
`define AP_DONE 2'b10

module fir 
  #(parameter pADDR_WIDTH = 12,
    parameter pDATA_WIDTH = 32,
    parameter Tape_Num    = 11,
    parameter Data_Num    = 600
    )
    (
//----------- AXI-Lite Interface (Read/Write Transaction) ------
    output wire                     awready,    // address write ready
    output wire                     wready,     // data    write ready
    input  wire                     awvalid,    // address write valid
    input  wire                     wvalid,     // data    write valid
    input  wire [(pADDR_WIDTH-1):0] awaddr,     // address write data  => Write the Address of Coefficient
    input  wire [(pDATA_WIDTH-1):0] wdata,      // data    write data  => Write the Coefficient
    output wire                     arready,    // address read ready
    input  wire                     rready,     // data    read ready
    input  wire                     arvalid,    // address read valid
    output wire                     rvalid,     // data    read valid
    input  wire [(pADDR_WIDTH-1):0] araddr,     // address read data   => Send the Address of Coefficient to Read
    output wire [(pDATA_WIDTH-1):0] rdata,      // data    read data   => Coefficient of that Address
    
//------------------ AXI-Stream In X[n] ----------------------
    output wire                     ss_tready,
    input  wire                     ss_tvalid,
    input  wire [(pDATA_WIDTH-1):0] ss_tdata,   // data input x[t-i]
    input  wire                     ss_tlast,
//----------------- AXI-Stream Out Y[t] ----------------------
    input  wire                     sm_tready,
    output wire                     sm_tvalid,
    output wire [(pDATA_WIDTH-1):0] sm_tdata,   // data after calculation Y[t]
    output wire                     sm_tlast,
//-------------------- BRAM for tap RAM ----------------------
    output wire [3:0]               tap_WE,
    output wire                     tap_EN,
    output wire [(pDATA_WIDTH-1):0] tap_Di,     // transfer tape from fir to memory
    output wire [(pADDR_WIDTH-1):0] tap_A,     
    input  wire [(pDATA_WIDTH-1):0] tap_Do,     // output from Tape_Ram
//-------------------- BRAM for data RAM --------------------
    output wire [3:0]               data_WE,
    output wire                     data_EN,
    output wire [(pDATA_WIDTH-1):0] data_Di,   // data after calculation
    output wire [(pADDR_WIDTH-1):0] data_A,
    input  wire [(pDATA_WIDTH-1):0] data_Do,   // output from Data_Ram
    
    input  wire                     axis_clk,
    input  wire                     axis_rst_n
    );
    
//----------------------- AXI-Lite -----------------------------
    reg ARREADY;
    reg AWREADY;
    reg WREADY;
    reg RVALID;
    
    wire tmp_rvalid;
    
    assign tmp_rvalid = (arvalid | rvalid & ~rready); // set by ARVALID, reset by RREADY
    always @(posedge axis_clk) RVALID  = (tmp_rvalid)?        1 : 0;
    always @(posedge axis_clk) ARREADY = (arvalid)?           1 : 0;
    always @(posedge axis_clk) AWREADY = (awvalid && wvalid)? 1 : 0;    
    always @(posedge axis_clk) WREADY  = (awvalid && wvalid)? 1 : 0;

    assign awready = AWREADY;
    assign arready = ARREADY; 
    assign wready  = WREADY;
    assign rvalid  = RVALID;
    assign rdata   = (araddr[7:0] == 8'd0)? ap_ctrl : tap_Do; // if read 0x00, ap_ctrl
    
//-------------- Configuration Register control ---------------
    reg [2:0]  ap_ctrl;     //bit 0: ap_start, bit 1: ap_done, bit 2: ap_idle
    reg [1:0]  ap_state;
    reg [1:0]  next_ap_state;
    
    // 0x00: bit 0: ap_start, bit 1: ap_done, bit 2: ap_idle
    
    always @* begin
        /*-------- ap_idle --------*/
        if (ap_state == `AP_IDLE)
            ap_ctrl[2] = 1;
        else
            ap_ctrl[2] = 0;
            
        /*------- ap_start --------*/
        if (ap_state == `AP_IDLE && awaddr == 12'd0 
        && wdata[0] == 1 && tlast_cnt != data_length)
            ap_ctrl[0] = 1;
        else
            ap_ctrl[0] = 0;
            
        /*-------- ap_done --------*/
        if (sm_tvalid && sm_tlast)
            ap_ctrl[1] = 1;
        else if (ap_state == `AP_DONE)
            ap_ctrl[1] = 1;
        else
            ap_ctrl[1] = 0;
    
    end
    
    always @* begin
        case (ap_state)
            `AP_IDLE:
            begin
                if (awaddr == 12'd0 && wdata[0] == 1 && tlast_cnt != data_length) begin
                    next_ap_state = `AP_PROC;
                end
                else begin
                    next_ap_state = `AP_IDLE;
                end  
            end
            `AP_PROC:
            begin
                if (sm_tvalid && sm_tlast) begin // finish last Y
                    next_ap_state = `AP_DONE;
                end
                else begin
                    next_ap_state = `AP_PROC;
                end
            end
            `AP_DONE:
            begin
                if (araddr == 12'd0 && arvalid && rvalid) begin
                    next_ap_state = `AP_IDLE;
                end
                else begin
                    next_ap_state = `AP_DONE;
                end
            end
            default:
            begin
                if (awaddr == 12'd0 && wdata[0] == 1 && tlast_cnt != data_length) begin
                    next_ap_state = `AP_PROC; 
                end
                else begin
                    next_ap_state = `AP_IDLE;
                end 
            end
        endcase
    end
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            ap_state <= `AP_IDLE;  // ap_idle = 1
        else
            ap_state <= next_ap_state;
    end

    // 0x10-14: data length
    reg  [31:0] data_length;
    wire [31:0] data_length_tmp;
    
    assign data_length_tmp = (awaddr == 8'h10)? wdata : data_length;
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            data_length <= 0;
        else
            data_length <= data_length_tmp;
    end
    
    // 0x80-FF: tap parameter
    assign tap_EN = 1;
    assign tap_WE = ((wvalid == 1) && (awaddr[7:0] != 0))? 4'b1111 : 4'b0000;
    assign tap_A  = (awvalid == 1)? awaddr[5:0] : tap_AR[5:0]; // write prioirty
    assign tap_Di = wdata;
    
//------------------------- data_RAM signals -----------------------------
    assign data_EN = ss_tvalid; // Since we only write in, no READ
    assign data_WE = (ss_tready & ss_idle || init_addr != 6'd44)? 4'b1111 : 4'b0000;  // if ss_tlast not asserted, still can write
    assign data_A  = (ap_ctrl[2] == 1 && init_addr != 6'd44)? init_addr : data_A_tmp; // data initialize before ap_start
    assign data_Di = (ap_ctrl[2] == 1 && init_addr != 6'd44)? 0 : ss_tdata;
    
    // data RAM initialize
    wire [5:0] next_init_addr;
    reg  [5:0] init_addr;
    
    assign next_init_addr = (init_addr == 6'd44)? init_addr : init_addr + 6'd4;
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            init_addr <= -6'd4;
        else
            init_addr <= next_init_addr;
    end
 
//---------------------- AXI-Stream ---------------------------
// tvalid is driven by the source (master) side of the channel and
// tready is driven by the destination (slave) side.
// 
// tvalid signal indicates that the value (tdata & tlast) are valid 
// tready signal indicates that the slave is ready to accept data.
// 
// When both tvalid and tready are asserted in the same clock, a transfer occurs.

    // Stream-in X
    assign ss_tready = (init_addr == 6'd44 && k == 4'd0)? 1'b1 : 1'b0;           // write in data_RAM
    
    // Stream-out Y
    assign sm_tvalid = (y_cnt == 5'd0)? 1'b1 : 1'b0;    // send output Y to tb
    assign sm_tdata  = y;                               // data after calculation Y[t]
    
    assign sm_tlast  = _sm_tlast; 
    
    //-------------- FSM for AXI-Stream input X (ss_tlast)-------------
    reg ss_state;
    reg next_ss_state;
    reg ss_idle;
    
    always @* begin
        case (ss_state)
        `SS_IDLE:
        begin
            if (ss_tvalid && ss_tlast) begin
                next_ss_state = `SS_DONE;
                ss_idle = 1;
            end
            else begin
                next_ss_state = `SS_IDLE;
                ss_idle = 1;
            end
        end
        `SS_DONE:
        begin
            if (ss_tvalid) begin
                next_ss_state = `SS_IDLE;
                ss_idle = 1;
            end
            else begin
                next_ss_state = `SS_DONE;
                ss_idle = 0;
            end
        end
        default:
        begin
            if (ss_tvalid) begin
                next_ss_state = `SS_IDLE;
                ss_idle = 1;
            end
            else begin
                next_ss_state = `SS_DONE;
                ss_idle = 0;
            end
        end
        endcase
    end
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            ss_state <= `SS_DONE;
        else
            ss_state <= next_ss_state;
    end
    
    //-------------- FSM for AXI-Stream output Y (sm_tlast)-------------
    reg sm_state;
    reg next_sm_state;
    
    reg _sm_tlast;
    
    always @* begin
        case (sm_state)
            `SM_IDLE:
            begin
                if (tlast_cnt_tmp == data_length) begin
                    _sm_tlast     = 1'b1;
                    next_sm_state = `SM_DONE;
                end
                else begin
                    _sm_tlast     = 1'b0;
                    next_sm_state = `SM_IDLE;
                end
            end
            `SM_DONE:
            begin
                if (sm_tvalid == 1'b1) begin
                    _sm_tlast     = 1'b0;
                    next_sm_state = `SM_IDLE;
                end
                else begin
                    _sm_tlast     = 1'b0;
                    next_sm_state = `SM_DONE;
                end
            end
        endcase
    end
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            sm_state <= `SM_DONE;
        else
            sm_state <= next_sm_state;
    end
    
    //------------------ For AXI-Stream output Y -----------------------
    reg  [4:0] y_cnt;       // count to the cycle where output Y has calculated
    wire [4:0] y_cnt_tmp;
    
    assign y_cnt_tmp = (y_cnt != 6'd10 && ap_ctrl[2] == 1'b0)? y_cnt + 1'b1 : 5'd0;
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2]) 
            y_cnt <= 5'd0 - 5'd15; // 3 for operation pipeline, 11 for calculation
        else
            y_cnt <= y_cnt_tmp;
    end
    
    //-------------- For sm_tlast. count to data length ------------------
    reg  [9:0] tlast_cnt;    // count to data length 600
    wire [9:0] tlast_cnt_tmp;
    
    assign tlast_cnt_tmp = (sm_tvalid == 1'b1)? tlast_cnt + 1'b1 : tlast_cnt;
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n) 
            tlast_cnt <= 10'd0;
        else
            tlast_cnt <= tlast_cnt_tmp;
    end
    
//---------------------- Pipeline Operation ------------------------------
//------------ FIR Operation: One Multiplier and one Adder ---------------

    wire [(pDATA_WIDTH-1):0] h_tmp; // coefficient
    wire [(pDATA_WIDTH-1):0] x_tmp; // Data stream-in
       
    reg  [(pDATA_WIDTH-1):0] h;
    reg  [(pDATA_WIDTH-1):0] x;
    
    wire [(pDATA_WIDTH-1):0] m_tmp; // after multi
    reg  [(pDATA_WIDTH-1):0] m; 
    
    wire [(pDATA_WIDTH-1):0] y_tmp; // Y[t] = sigma (h[i] * X[t-i])   
    reg  [(pDATA_WIDTH-1):0] y;     // Data Stream-out
    
    assign h_tmp = tap_Do;          // h[i]
    assign x_tmp = x_sel;           // x[t-i]
    assign m_tmp = h * x;           // h[i] * x[t-i]
    assign y_tmp = m + y;  
            
    // Operation Pipeline
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2]) begin
            h <= 32'd0;
            x <= 32'd0;
            m <= 32'd0;
            y <= 32'd0;
        end
        else begin
            h <= h_tmp;
            x <= x_tmp;
            m <= m_tmp;
            if (y_cnt == 4'd0)
                y <= 0;
            else
                y <= y_tmp;
        end
    end
    
//---------------------- Address Generator ----------------------
    wire [5:0] tap_AR;    // address which will send into tap_RAM
    reg  [3:0] k;
    wire [3:0] k_tmp;
    
    assign k_tmp = (k != 4'd10)? k+1 : 4'd0;

    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2])
            k <= 4'd10;
        else
            k <= k_tmp;
    end
    
    // if ap_idle = 0, use value of address generator
    assign tap_AR = (ap_ctrl[2] == 1'b0)? 4 * k : araddr[5:0]; // else, tb check value
    
//-------------------- Address Generator(Data) ------------------
    // count x[t]
    reg [3:0] x_cnt;
    reg [3:0] x_cnt_tmp;
    
    always @* begin
        if (ap_ctrl[2] == 1'b0) begin
            if (k == 4'd10)
                if (x_cnt != 4'd10)
                    x_cnt_tmp = x_cnt + 1'b1;
                else
                    x_cnt_tmp =  4'd0;
            else
                x_cnt_tmp = x_cnt;
        end
        else
            x_cnt_tmp = 4'd0;
    end
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            x_cnt <= 4'd0;
        else
            x_cnt <= x_cnt_tmp;
    end
    
    // count x[t-i]    
    wire [5:0] data_A_tmp;
    
    assign data_A_tmp = (k <= x_cnt)? 4 * (x_cnt - k) : 4 * (11 + x_cnt - k);
    
//-------------------------- 32-bit FF --------------------------
    reg  [(pDATA_WIDTH-1):0] data_ff;
    
    // FF store one value, the first x is from FF.
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n) begin
            data_ff <= 32'd0;
        end
        else begin
            data_ff <= ss_tdata;
        end
    end
    
//--------------- MUX to select X from FF or data_RAM -------------
    wire [(pDATA_WIDTH-1):0] x_sel;
    reg  mux_data_sel;
    
    // MUX to select x from FF or Data_RAM
    always @* begin
        if (k == 4'd0)
            mux_data_sel = 1;
        else
            mux_data_sel = 0;
    end
    // output from MUX
    assign x_sel = (mux_data_sel)? data_ff : data_Do;
    

endmodule
