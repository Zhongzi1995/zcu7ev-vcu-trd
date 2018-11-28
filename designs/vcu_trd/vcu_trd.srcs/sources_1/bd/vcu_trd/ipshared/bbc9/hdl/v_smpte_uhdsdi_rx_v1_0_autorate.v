// (c) Copyright 2002 - 2015 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
// 
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
// 
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module, controls a MGT RX operating mode so as to automatically detect 
SD-SDI, HD-SDI, 3G-SDI, 6G-SDI, or 12G-SDI on the incoming bit stream.

The user needs to balance error tolerance against reaction speed in this design.
Occasional errors, or even a burst of errors, should not cause the circuit to
toggle reference clock frequencies prematurely. On the other hand, in some
cases it is necessary to reacquire lock with the bitstream as quickly as
possible after the incoming bitstream changes frequencies.

This module uses missing or erroneous TRS symbols as the detection mechanism for 
determining when to toggle the operating mode. A missing SAV or an SAV 
with protection bit errors will cause the finite state machine to flag the line 
as containing an error. 

Each line that contains an error causes the error counter to increment. If a 
line is found that is error free, the error counter is cleared back to zero. 
When MAX_ERRS_LOCKED consecutive lines occur with errors, the state machine will 
change the mode output to cycle through SD-SDI, HD-SDI, and 3G-SDI until lock
is reacquired. MAX_ERRS_LOCKED is provided to the module as a parameter. The
width of the error counter, as specified by ERRCNT_WIDTH, must be sufficient to
count up to MAX_ERRS_LOCKED (and MAX_ERRS_UNLOCKED).

When the receiver is not locked, the MAX_ERRS_UNLOCKED parameter controls
the maximum number of consecutive lines with TRS errors that must occur before
the state machine moves on to the next operating mode. MAX_ERRS_UNLOCKED
effectively controls the scan rate of the locking process whereas 
MAX_ERRS_LOCKED controls how quickly the module responds to loss of lock (and
how sensitive it is to noise on the input signal).

The TRSCNT_WIDTH parameter determines the width of the counter used to determine
if an SAV was not received during a line. It should be wide enough to count
more than the number of samples in the longest possible video line. For 12G-SDI
with 16 streams interleaved, there may be over 30K words between SAVs so the
TRSCNT_WIDTH parameter is set to 16.

The rst input resets the module asynchronously. However, this signal must be
negated synchronously with the clk signal, otherwise the state machine may
go to an invalid state.

This controller also has an input called mode_enable that allows the supported
modes to be specified. Only those modes whose corresponding bit on the 
mode_enable input will be tried during the search to lock to the input 
bitstream.
--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_uhdsdi_rx_v1_0_0_autorate #(
    parameter ERRCNT_WIDTH      = 4,    // width of counter tracking lines with errors
    parameter TRSCNT_WIDTH      = 16,   // width of missing SAV timeout counter
    parameter MAX_ERRS_LOCKED   = 15,   // max number of consecutive lines with errors
    parameter MAX_ERRS_UNLOCKED = 2)    // max number of lines with errors during search
(
    input  wire         clk,            // rxusrclk input
    input  wire         ce,             // clock enable
    input  wire         rst,            // sync reset input
    input  wire [9:0]   ds1,            // more qualification on mode_lock 
    input  wire         eav,            // asserted during EAV symbols
    input  wire         sav,            // asserted during SAV symbols
    input  wire         trs_err,        // SAV validation signal
    input  wire         rx_ready,       // 1 = RX is ready, 0 = RX is being reset
    input  wire [5:0]   mode_enable,    // b0=HD, b1=SD, b2=3G, b3=6G, b4=12G/1, b5=12G/1.001
    output wire [2:0]   mode,           // 000=HD, 001=SD, 010=3G, 100=6G, 101=12GA, 110=12GB
    output wire         locked          // 1 = locked
);

//-----------------------------------------------------------------------------
// Parameter definitions
//
// Changing the ERRCNT_WIDTH parameter changes the width of the counter that is
// used to keep track of the number of consecutive lines that contained errors.
// By changing the counter width and changing the two MAX_ERRS parameters, the
// latency for refclksel switching can be changed. Making the MAX_ERRS values
// smaller will reduce the switching latency, but will also reduce the tolerance
// to errors and cause unintentional rate switching.
//
// There are two different MAX_ERRS parameters, one that is effective when the
// FSM is locked and and when it is unlocked. By making the MAX_ERRS_UNLOCKED
// value smaller, the scan process is more rapid. By making the MAX_ERRS_LOCKED
// parameter larger, the process is less sensitive to noise induced errors.
//
// The TRSCNT_WIDTH parameter determines the width of the missing SAV timeout
// counter. Increasing this counter's width causes the state machine to wait
// longer before determining that a SAV was missing. Note that the counter
// is actually implemented as one bit wider than the value given in TRSCNT_MSB
// allowing the MSB to be the timeout error flag.
//
localparam ERRCNT_MSB = ERRCNT_WIDTH - 1;    
localparam TRSCNT_MSB = TRSCNT_WIDTH;    

//
// This group of parameters defines the states of the FSM.
//                                              
localparam STATE_MSB = 2;

localparam [STATE_MSB:0]
    UNLOCK  = 0,
    LOCK1   = 1,
    LOCK2   = 2,
    LOCK3   = 3,
    ERR1    = 4,
    ERR2    = 5,
    CHANGE  = 6;
    
// 
// These parameters define the values used on the mode output
//      
localparam [2:0]
    MODE_HD  = 3'b000,
    MODE_SD  = 3'b001,
    MODE_3G  = 3'b010,
    MODE_X0  = 3'b011,
    MODE_6G  = 3'b100,
    MODE_12GA= 3'b101,
    MODE_12GB= 3'b110,
    MODE_X1  = 3'b111;

// 
// These parameters define the mode_enable input port bits.
//     
localparam
    VALID_BIT_HD  = 0,
    VALID_BIT_SD  = 1,
    VALID_BIT_3G  = 2,
    VALID_BIT_6G  = 3,
    VALID_BIT_12GA= 4,
    VALID_BIT_12GB= 5;

//-----------------------------------------------------------------------------
// Signal definitions
//

// internal signals
(* fsm_safe_state = "default_state" *)
reg     [STATE_MSB:0]   current_state = UNLOCK; // FSM current state
reg     [STATE_MSB:0]   next_state;             // FSM next state
reg     [ERRCNT_MSB:0]  errcnt = 0;             // error counter
reg     [TRSCNT_MSB:0]  trscnt = 0;             // TRS timeout counter
reg                     clr_errcnt;             // FSM output that clears errcnt
reg                     inc_errcnt;             // FSM output that increments errcnt
wire                    max_errcnt;             // asserted when errcnt = MAX_ERRS
wire                    trs_tc;                 // terminal count output from trscnt
wire                    sav_ok;                 // asserted during SAV if no protection errors
wire                    xyz_ok;                 // asserted during EAV if XYZ checking passing 
reg     [2:0]           mode_int = 3'b000;      // internal version of mode output
reg                     change_mode;            // FSM output that changes mode
reg                     set_locked;             // FSM output that sets locked_int
reg                     clr_locked;             // FSM output that clears locked_int
reg                     locked_int = 1'b0;      // internal version of locked signal
wire    [ERRCNT_MSB:0]  max_errs;               // max errcnt mux
reg     [2:0]           next_mode;
reg     [1:0]           rx_ready_ss = 2'b00;    // synchronizer for rx_ready input
wire                    rx_ready_s;             // synchronous version of rx_ready
 // video lock enhancement 
    wire  XYZ_chk            ;
    wire  xor_vh             ;
    wire  xor_fh             ;
    wire  xor_fv             ;
    wire  xor_fvh            ;

//
// Synchronize the rx_ready signal to the local clock
//
always @ (posedge clk)
    rx_ready_ss <= {rx_ready_ss[0], rx_ready};

assign rx_ready_s = rx_ready_ss[1];

//
// Error signals
//
// sav_ok is only asserted during the XYZ word of SAV symbols when there trs_err
// is not asserted.
//
assign sav_ok = sav & ~trs_err;

//video locked detection: try to fix the lock high but no video plug issue from sdi core
assign xor_vh = ds1[7] ^ ds1[6];
assign xor_fh = ds1[8] ^ ds1[6];
assign xor_fv = ds1[8] ^ ds1[7];
assign xor_fvh = ds1[8] ^ ds1[7] ^ ds1[6];
//when eav=1, do XYZ calculation
assign xyz_ok = (ds1[9] == 1'b1 && ds1[6] == 1'b1 && ds1[5] == xor_vh && ds1[4] == xor_fh && ds1[3] == xor_fv && ds1[2] == xor_fvh && ds1[1:0] == 2'b0) ? eav : 1'b0;

// 
// mode register
//
// The mode register changes when the change_mode signal from the FSM is 
// asserted.. The normal scan sequence is HD -> 3G -> 6G -> 12GA -> 12GB -> SD -> HD if 
// all 6 modes are enabled by the mode_enable port. Any modes that are not enabled are
// skipped. 
//
always @ (*)
    case(mode_int)
        MODE_HD:    if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else if (mode_enable[VALID_BIT_6G])
                        next_mode = MODE_6G;
                    else if (mode_enable[VALID_BIT_12GA])
                        next_mode = MODE_12GA;
                    else if (mode_enable[VALID_BIT_12GB])
                        next_mode = MODE_12GB;
                    else if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else
                        next_mode = MODE_HD;

        MODE_3G:    if (mode_enable[VALID_BIT_6G])
                        next_mode = MODE_6G;
                    else if (mode_enable[VALID_BIT_12GA])
                        next_mode = MODE_12GA;
                    else if (mode_enable[VALID_BIT_12GB])
                        next_mode = MODE_12GB;
                    else if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else
                        next_mode = MODE_3G;

        MODE_6G:    if (mode_enable[VALID_BIT_12GA])
                        next_mode = MODE_12GA;
                    else if (mode_enable[VALID_BIT_12GB])
                        next_mode = MODE_12GB;
                    else if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else
                        next_mode = MODE_6G;

        MODE_12GA:  if (mode_enable[VALID_BIT_12GB])
                        next_mode = MODE_12GB;
                    else if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else if (mode_enable[VALID_BIT_6G])
                        next_mode = MODE_6G;
                    else
                        next_mode = MODE_12GA;

        MODE_12GB:  if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else if (mode_enable[VALID_BIT_6G])
                        next_mode = MODE_6G;
                    else if (mode_enable[VALID_BIT_12GA])
                        next_mode = MODE_12GA;
                    else 
                        next_mode = MODE_12GB;

        MODE_SD:    if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else if (mode_enable[VALID_BIT_6G])
                        next_mode = MODE_6G;
                    else if (mode_enable[VALID_BIT_12GA])
                        next_mode = MODE_12GA;
                    else if (mode_enable[VALID_BIT_12GB])
                        next_mode = MODE_12GB;
                    else
                        next_mode = MODE_SD;

        default:    next_mode = MODE_HD;
    endcase

always @ (posedge clk)
    if (ce & change_mode)
        mode_int <= next_mode;

assign mode = mode_int;

//
// locked signal
//
// This flip-flop generates the locked signal based on set and clr signals from
// the FSM.
//
always @ (posedge clk)
    if (rst)
        locked_int <= 1'b0;
    else if (ce)
    begin
        if (set_locked)
            locked_int <= 1'b1;
        else if (clr_locked)
            locked_int <= 1'b0;
    end

assign locked = locked_int;

//
// TRS timeout counter
//
// This counter is reset whenever a SAV signal is received, otherwise it
// increments. When it reaches its terminal count, the trs_tc signal is
// asserted and the the counter will roll over to zero on the next clock cycle.
//
always @ (posedge clk)
    if (ce)
        begin
            if (sav_ok | trs_tc)
                trscnt <= 0;
            else
                trscnt <= trscnt + 1;
        end

assign trs_tc = trscnt[TRSCNT_MSB];

//
// Error counter
//
// The error counter increments each time the inc_errcnt output from the FSM
// is asserted. It clears to zero when clr_errcnt is asserted. The max_errcnt
// output is asserted if the error counter equals max_errs. A MUX selects
// the correct MAX_ERRS parameter for the max_errs signal based on the locked
// signal from the FSM.
//
always @ (posedge clk)
    if (ce)
        begin
            if (inc_errcnt)
                errcnt <= errcnt + 1;
            else if (clr_errcnt)
                errcnt <= 0;
        end

assign max_errs = locked_int ? MAX_ERRS_LOCKED : MAX_ERRS_UNLOCKED;
assign max_errcnt = errcnt == max_errs;

// FSM
//
// The finite state machine is implemented in three processes, one for the
// current_state register, one to generate the next_state value, and the
// third to decode the current_state to generate the outputs.
 
//
// FSM: current_state register
//
// This code implements the current state register. It loads with the UNLOCK
// state on reset and the next_state value with each rising clock edge.
//
always @ (posedge clk)
    if (rst)
        current_state <= UNLOCK;
    else if (ce)
        current_state <= next_state;

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        //
        // The FSM begins in the UNLOCK state and stays there until a SAV
        // symbol is found. In this state, if the TRS timeout counter reaches
        // its terminal count, the FSM moves to the ERR1 state to increment the
        // error counter.
        //
        UNLOCK: if (!rx_ready_s)
                    next_state = UNLOCK;
                else if (mode_int == MODE_X0 || mode_int == MODE_X1)
                    next_state = CHANGE;
                else if (sav_ok)
                    next_state = LOCK1;
                else if (trs_tc)
                    next_state = ERR1;
                else
                    next_state = UNLOCK;

        //
        // This is the main locked state LOCK1. Once a SAV has been found, the
        // FSM stays here until either another SAV is found or the TRS counter
        // times out.
        //
        LOCK1:  if (!rx_ready_s)
                    next_state = UNLOCK;
                else if (sav_ok)
                    next_state = LOCK2;
                else if (trs_tc)
                    next_state = ERR1;
                else
                    next_state = LOCK1;

        //
        // The FSM moves to LOCK2 from LOCK1 if a SAV is found. The error
        // counter is reset in LOCK2.
        //
        LOCK2:  if (!rx_ready_s)
                    next_state = UNLOCK;
                else if (xyz_ok)
                    next_state = LOCK3;
                else if (trs_tc)
                    next_state = ERR1;
                else
                    next_state = LOCK2;

        LOCK3:  next_state = LOCK1;

        //
        // The FSM moves to ERR1 from LOCK 1 if the TRS timeout counter reaches
        // its terminal count before a SAV is found. In this state, the error
        // counter is incremented and the FSM moves to ERR2.
        //
        ERR1:   next_state = ERR2;

        //
        // The FSM enters ERR2 from ERR1 where the error counter was
        // incremented. In this state the max_errcnt signal is tested. If it
        // is asserted, the FSM moves to the TOGGLE state, otherwise the FSM
        // returns to LOCK1.
        //
        ERR2:   if (max_errcnt)
                    next_state = CHANGE;
                else if (locked_int)
                    next_state = LOCK1;
                else
                    next_state = UNLOCK;
                  
        //
        // In the CHANGE state, the FSM sets the change_mode signal and returns
        // to the UNLOCK state.
        //
        CHANGE: next_state = UNLOCK;

        default: next_state = UNLOCK;
    endcase

        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*) 
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // are low.
    change_mode     = 1'b0;
    clr_errcnt      = 1'b0;
    inc_errcnt      = 1'b0;
    set_locked      = 1'b0;
    clr_locked      = 1'b0;
                                
    case(current_state) 
        
        UNLOCK: clr_locked = 1'b1;

        LOCK3:  begin
                    clr_errcnt = 1'b1;
                    set_locked = 1'b1;
                end

        CHANGE: begin
                    change_mode = 1'b1;
                    clr_errcnt = 1'b1;
                end

        ERR1: inc_errcnt = 1'b1;
    endcase
end

endmodule
