`timescale 1ns / 1ps

`define SS_IDLE 1'b1
`define SS_DONE 1'b0

`define SM_IDLE 1'b1
`define SM_DONE 1'b0

`define AP_PROC 2'b00
`define AP_IDLE 2'b01
`define AP_DONE 2'b10

module fir 
  #(parameter pADDR_WIDTH = 32,
    parameter pDATA_WIDTH = 32,
    parameter Tape_Num    = 11,
    parameter Data_Num    = 11
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
    
    reg  [5:0]  ap_ctrl;
    reg  [1:0]  ap_state;
    reg  [1:0]  next_ap_state;

    reg  [31:0] data_length;
    wire [31:0] data_length_tmp;
    reg         write_len;

    wire [5:0] next_init_addr;
    reg  [5:0] init_addr;

    reg sm_state;
    reg next_sm_state;

    reg _sm_tlast;

    reg  [5:0] y_cnt;       // count to the cycle where output Y has calculated
    reg  [5:0] y_cnt_tmp;
 
    reg  [9:0] tlast_cnt;    // count to data length 600
    wire [9:0] tlast_cnt_tmp; 

    reg  [5:0] tap_AR;    // address which will send into tap_RAM
    reg  [4:0] k;
    reg  [4:0] k_tmp;

    reg  [5:0] data_A_tmp;

    wire [(pDATA_WIDTH-1):0] h_tmp; // coefficient
    wire [(pDATA_WIDTH-1):0] x_tmp; // Data stream-in

    reg  [(pDATA_WIDTH-1):0] h;
    reg  [(pDATA_WIDTH-1):0] x;

    wire [(pDATA_WIDTH-1):0] m_tmp; // after multi
    reg  [(pDATA_WIDTH-1):0] m;

    wire [(pDATA_WIDTH-1):0] y_tmp; // Y[t] = sigma (h[i] * X[t-i])   
    reg  [(pDATA_WIDTH-1):0] y;     // Data Stream-out

    reg  [3:0] x_cnt;
    reg  [3:0] x_cnt_tmp;

    reg  [(pDATA_WIDTH-1):0] data_ff;

    wire [(pDATA_WIDTH-1):0] x_sel;
    reg   mux_data_sel;

//----------------------- AXI-Lite -----------------------------
    reg ARREADY;
    reg AWREADY;
    reg WREADY;
    
    always @(posedge axis_clk) ARREADY <= (arvalid)?           1 : 0;
    always @(posedge axis_clk) AWREADY <= (awvalid && wvalid)? 1 : 0;
    always @(posedge axis_clk) WREADY  <= (awvalid && wvalid)? 1 : 0;
    
    assign awready = (axis_rst_n)? AWREADY : 0;
    assign arready = (axis_rst_n)? ARREADY : 0; 
    assign wready  = (axis_rst_n)? WREADY  : 0;

    reg tmp_rvalid;
    always @(posedge axis_clk) tmp_rvalid <= arvalid;
    
    assign rvalid  = tmp_rvalid;
    
    assign rdata   = (arvalid && araddr[7:0] == 8'd0)? ap_ctrl : tap_Do; // read tap
    
//-------------- Configuration Register control --------------- 
    always @* begin
        /*----- ap_idle -----*/
        if (ap_state == `AP_IDLE)
            ap_ctrl[2] = 1;
        else
            ap_ctrl[2] = 0;
        
        /*----- ap_start ----*/
        if (ap_state == `AP_IDLE && awaddr == 32'h3000_0000 && wdata == 1)
            ap_ctrl[0] = 1;
        else
            ap_ctrl[0] = 0;
        
        /*----- ap_done -----*/
        if (sm_tvalid && sm_tlast)
            ap_ctrl[1] = 1;
        else if (ap_state == `AP_DONE)
            ap_ctrl[1] = 1;
        else
            ap_ctrl[1] = 0;
            
        ap_ctrl[3] = 0;         // read zero
        ap_ctrl[4] = ss_tready; // X[n] ready to accept input
        ap_ctrl[5] = sm_tvalid; // Y[y] is ready to read
    end            
        
    always @* begin
        case (ap_state)
            `AP_IDLE:
            begin  // 0x00: bit 0: ap_start, bit 1: ap_done, bit 2: ap_idle
                if (awvalid && awaddr == 32'h3000_0000 && wdata == 1) begin
                    next_ap_state = `AP_PROC; 
                end
                else begin
                    // should clear the dataRAM
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
                if (arvalid && araddr == 32'h3000_0000) begin
                    next_ap_state = `AP_IDLE;
                end
                else begin
                    next_ap_state = `AP_DONE;
                end
            end
            default:
            begin
                if (awvalid && awaddr == 32'h3000_0000 && wdata == 1) begin
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

//---------------- 0x10-14: data length ------------------
    always @* begin
        if(awaddr == 32'h3000_0010 && awvalid) 
            write_len = 1'b1;
        else 
            write_len = 1'b0;
    end
    
    assign data_length_tmp = (write_len)? wdata : data_length; // 0x3000_0010
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n)
            data_length <= 1'b0;
        else
            data_length <= data_length_tmp;
    end
    
//-------------- 0x80-FF: tap parameter ------------------
    assign tap_EN = 1;
    assign tap_WE = ((wvalid == 1) && (awaddr[7:0] != 0))? 4'b1111 : 4'b0000;
    assign tap_A  = (awvalid == 1)? awaddr[5:0] : tap_AR[5:0]; // write prioirty
    assign tap_Di = wdata;
    
//------------------------- data_RAM signals -----------------------------
    assign data_EN = 1;
    assign data_WE = (((ss_tvalid == 1) && (awaddr[7:0] == 8'h80)) 
                  || (init_addr != 6'd44))? 4'b1111 : 4'b0000;  // if ss_tlast not asserted, still can write
    assign data_A  = (init_addr != 6'd44)? init_addr : data_A_tmp; // data initialize before ap_start
    assign data_Di = (init_addr != 6'd44)? 0 : ss_tdata;
    
    // data RAM initialize    
    assign next_init_addr = (init_addr == 6'd44)? init_addr : init_addr + 6'd4;
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2])
            init_addr <= 0;
        else
            init_addr <= next_init_addr;
    end

//-------------------- Stream-in X ------------------------//
    // Only input when FIR is processing and k = 0
    assign ss_tready = (k == 5'd0 && ap_ctrl[2] == 0 && init_addr == 6'd44)? 1'b1 : 1'b0; ///////////
    
//-------------------- Stream-out Y -----------------------//
    assign sm_tvalid = (y_cnt == 5'd0 && ap_ctrl[2] == 0)? 1'b1 : 1'b0;
    assign sm_tdata  = y;                               // data after calculation Y[t]
    assign sm_tlast  = _sm_tlast; 
    
//-------------- FSM for AXI-Stream output Y (sm_tlast)-------------    
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
    always @* begin
        if (ss_tready) begin
            if (ss_tvalid) // If fir is ready for new data in
                y_cnt_tmp = y_cnt + 1'b1;
            else
                y_cnt_tmp = y_cnt;
        end
        else if (y_cnt == 0) begin
            if (sm_tvalid && sm_tready) // If firmware send the signal for Y output request
                y_cnt_tmp = 0 - 6'd14;
            else
                y_cnt_tmp = y_cnt;
        end
        else begin
            y_cnt_tmp = y_cnt + 1'b1;
        end
    end
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2]) 
            y_cnt <= 6'd0 - 6'd25; // 3 for operation pipeline, 11 for calculation
        else
            y_cnt <= y_cnt_tmp;
    end
    
    //-------------- For sm_tlast. count to data length ------------------    
    assign tlast_cnt_tmp = (sm_tvalid && sm_tready && araddr == 32'h3000_0084)? tlast_cnt + 1'b1 : tlast_cnt;
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2]) 
            tlast_cnt <= 10'd0;
        else
            tlast_cnt <= tlast_cnt_tmp;
    end
    
//---------------------- Pipeline Operation ------------------------------
//------------ FIR Operation: One Multiplier and one Adder ---------------
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
            if (sm_tready && sm_tvalid)
                y <= 0;
            else
                y <= y_tmp;
        end
    end
    
//---------------------- Address Generator ----------------------   
    always @* begin
        if (ss_tready && ss_tvalid) begin
            k_tmp = k + 1;
	    /*
	    if (ss_tvalid) // if firmware tell as input X is valid
                k_tmp = k + 5'd1;
            else
                k_tmp = k;
	    */
        end
        else if (y_cnt == 0) begin
            if (sm_tvalid && sm_tready)
                k_tmp = 0;
            else
                k_tmp = k;
        end
	else if (init_addr != 6'd44) begin
	    k_tmp = 0;
	end
        else begin
            k_tmp = k + 1;
        end
    end
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (!axis_rst_n || ap_ctrl[2])
            k <= 0;
        else
            k <= k_tmp;
    end
    
    // use the value of address generator if ap_idle=0
    always @* begin
        if (ap_ctrl[2] == 1'b0) begin
            if (k >= 0 && k <= 10)
                tap_AR = 12'h040 + 4 * k;
            else
                tap_AR = 12'h040;
        end
        else begin
            tap_AR = araddr[5:0];
        end
    end
    
//-------------------- Address Generator(Data) ------------------
    // count x[t]    
    always @* begin
        if (ap_ctrl[2] == 1'b0) begin // if FIR is executing
            if (k == 4'd10)
                if (x_cnt != 4'd10)
                    x_cnt_tmp = x_cnt + 1'b1;
                else
                    x_cnt_tmp = 4'd0;
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
    always @* begin
        if (k >= 0 && k <= 10) begin
            if (k <= x_cnt)
                data_A_tmp = 4 * (x_cnt -k);
            else
                data_A_tmp = 4 * (11 + x_cnt - k);
        end
        else begin
            data_A_tmp = 0;
        end
    end   
    
//-------------------------- 32-bit FF --------------------------    
    // FF store one value, the first x is from FF.
    always @(posedge axis_clk) begin
        if(ss_tvalid) begin
            data_ff <= ss_tdata;
        end
        else begin
            data_ff = 32'd0;
        end
    end
    
//--------------- MUX to select X from FF or data_RAM -------------
    // MUX to select x from FF or Data_RAM
    always @* begin
        if (k == 4'd0)
            mux_data_sel = 1;
        else
            mux_data_sel = 0;
    end
    // output from MUX
//    assign x_sel = (mux_data_sel)? data_ff : data_Do;
    
    assign x_sel = (ss_tvalid && mux_data_sel)? ss_tdata : data_Do;

endmodule
