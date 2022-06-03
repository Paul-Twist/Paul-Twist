//------------------------------------------------------------------------
// CLIO_Interface_top.v
//
// Verilog source for the control of a CLIO chip.
//
// There is one dual-ported block ram for the pattern storage. From 
// the PC side it is 16 bits wide and to the application it is 256 
// bits wide to match the number of nozzles. It has 4096 256 bit wide 
// locations to hold one full swath on the Titin chip.
//
// Pattern RAM: The 16-bit port is connected to the PipeIn.  Data is 
//              written directly from the pipe to the RAM.  The 256-bit port is
//              connected to the state machine and sources the 256 nozzle pattern.
//
// Adjust RAM:  Adjust RAM moves firing pulse forward or back to compensate for 
//              encoder tape or stage movement errors. 
//
// Nozzle RAM:  Nozzle adjust RAM enables the nozzles during 1 of the 8 firing pulses
//              For Q heads this is to compensate for the Y-Bow, for the D128s we will
//              simulate Y-Bow by adding a theta error.   
//
// Revisions     3.4 - Fixed pattern ram addressing on app side
//               5.1 - First Rev 2.0 board supported, 5V and 48V shdn
//               B.1 - Changed PSO divider to DDS/NCO structure for interferometer
//               C.1 - Added Pulse Counter and Max Delay to monitor PSO pulses.
// Things to fix:
//               1) ramp voltage before enabling relay to avoid unwanted printing
//               2) delete external SRAM, never used, now obsolete
//               3) change to 8 output connections from 2
//               4) add waveform segments and move registers
//               5) delete heater output, there is none in a Q head
//               
// ti_clk is 48 MHz
//
//------------------------------------------------------------------------

`default_nettype none
`timescale 1ns / 1ps

module CLIO_Interface_top(
	input  wire [7:0]  hi_in,
	output wire [1:0]  hi_out,
	inout  wire [15:0] hi_inout,
	inout  wire        hi_aa,
	
	output wire [9:1]  debug,        // To TAG Connect header
	
	input  wire        pzt_clim_n,   // Excess current on +120 or +5 to head
	output wire        shdn_5v,      // Turns off +5 to head
	output wire        shdn_120v,    // Turns off +120 to head
	input  wire        pzt_err_n,    // Excess DC current through head

	output wire        drv_half,
	output wire        drv_qtr,
    
	output wire        strobe,
	output wire        spare_2,
   input  wire        DAC_EN_IN,    // Square wave from NI DAQ, forwarded to CLIO
   input  wire [2:1]  pd,           // Adjacent pins, also pulldown 
   output wire        waste2,
	output wire        i2c_sda,
	output wire        i2c_scl,
	output wire        hi_muxsel,

	input  wire        clk1,
	output wire [7:0]  led,
   input  wire        pso,                   // PSO pulse, x stage movement, drives everything
	output wire        waste,
	output wire        valve_on,              // Turns on purge valve, pushes ink through head to prime
	output wire        ok_led,
	output wire        jet_led,
	output wire        spare_led,
   output wire        heat_on,
   output wire        amp_en,                // When high, opens relay to enable amp
	output wire        asic_clk,
	output wire        asic_blanking,         // Turns all switches on, also refresh 
   output wire        asic_polarity,
	output wire        asic_latch,
             
   output wire        CLIO_RSTN,             // Global reset for CLIO   
   output wire        DAC_EN,                // Global external DAC enable line, to allow pulsing.
   output wire        MCLK,                  // Master, fastest, clock to CLIO                
	output wire [7:0]  asic_data,             // Actual data to CLIO synth locations
   output wire        FRAME,
   output wire        CCLK,
   input  wire        SPI_MISO,              // New SPI input wire
   output wire        SPI_MOSI,              // Actual SPI output wire to chip
   output wire        SPI_SCLK,              // Actual SPI clock wire
   output wire        SPI_CS,                // CS to CLIO, active low
	output wire        adc_cs,
	output wire        adc_chsel,
	output wire        adc_clk,
	input  wire        adc_dout, 
   input  wire        K_A_INPUT,             // Trigger signal from K & A Synthesizer
	output wire [13:0] dac,                   // New 14 bit Twist Bio Inkjet DAC   
	output wire        dac_clk						// and its clock.     
	);

wire        ti_clk;
wire [30:0] ok1;
wire [16:0] ok2;

wire [15:0] WireIn10, WireIn11, WireIn12, WireIn13, WireIn14, WireIn15, WireIn16, WireIn17;
wire [15:0] WireIn18, WireIn19, WireIn1A, WireIn1B, WireIn1C, WireIn1D, WireIn1E, WireIn1F;
wire [15:0] TrigIn40, TrigIn41, TrigIn42, TrigIn43, TrigIn44, TrigIn45, TrigIn46, TrigIn47;
wire [15:0] TrigIn48, TrigIn49, TrigIn4A, TrigIn4B, TrigIn4C, TrigIn4D, TrigIn4E, TrigOut60;

wire [11:0] pattern_addr;               // For 4096 printing columns
wire [3:0]  nozzle_addr;                // For 16 nozzle adjust columns
wire        pattern_reset,  pattern_write, pattern_read;
wire [15:0] pattern_r_data, pattern_w_data;
reg  [14:0] pattern_u_addr;

wire        adjust_reset,  adjust_write, adjust_read;
wire [15:0] adjust_r_data, adjust_w_data;
reg  [11:0] adjust_u_addr;

wire        nozzle_reset,  nozzle_write, nozzle_read;
wire [15:0] nozzle_r_data, nozzle_w_data;
reg  [11:0] nozzle_u_addr;

wire        reg_reset, reg_write, reg_read;
wire [15:0] reg_r_data, reg_w_data;
reg  [9:0]  reg_r_addr, reg_w_addr;

reg  [15:0] reg_low_store;

wire        sreg_reset, sreg_write, sreg_read;
wire [15:0] sreg_r_data, sreg_w_data;
reg  [9:0]  sreg_r_addr, sreg_w_addr;

reg  [15:0] sreg_low_store;

wire        cpu_dac_enable;

wire [31:0] reg_dev_status;
reg  [31:0] reg_dev_control;
reg  [31:0] sreg_dev_control = 0;
wire [31:0] reg_fpga_version;
wire [31:0] reg_pulse_counter;
wire [31:0] reg_max_delay;

reg  [31:0] reg_divider  = 32'h0000_0020;    // 1300 Hz based on 48 MHz clock (Titan)
reg  [31:0] reg_dc_value = 32'h0006_0000;    // Minimal, 4 V
// Pre-load the simple 5 segment waveform for use on jetting stand
reg  [31:0] reg_segment1 = 32'h3400_0071;   // Slope_Length
reg  [31:0] reg_segment2 = 32'h0000_00A4;    // 3.5 us plateau, according to Stephanie
reg  [31:0] reg_segment3 = 32'hcc00_0071;
reg  [31:0] reg_segment4 = 32'h0000_005A;
reg  [31:0] reg_segment5 = 32'h0000_0071;
reg  [31:0] reg_segment6 = 32'h0000_0088;
reg  [31:0] reg_segment7 = 32'h0000_0000;
reg  [31:0] reg_segment8 = 32'h0000_0100;    // 5 usec between pulses.
reg  [31:0] reg_adc_setpoint = 930;          // 30 degree C setpoint
reg  [31:0] reg_adc_value , reg_adc_hs_value;
wire [15:0] adc_value, adc_hs_value;
wire [31:0] jet_stand1, jet_stand2, jet_stand3, jet_stand4;
wire [31:0] jet_stand5, jet_stand6, jet_stand7, jet_stand8;
wire [31:0] dac_act1, dac_act2, dac_act3, dac_act4, dac_act5;

wire [255:0] pattern_column;
wire [15:0]  adjust_column;
wire        heat_en,below;
reg   [2:0] rst_counter = 0;
reg         rstn;

always @ (posedge ti_clk)
   begin
      if (rst_counter != 3'b111)
         begin
            rstn <= 1'b0;  
            rst_counter <= rst_counter + 1; 
          end
       else
          begin
             rstn <= 1'b1;
          end
   end

//-----------------------------------------------------------------------
// Q Management TDI and DAC control 3/21 PMH
//-----------------------------------------------------------------------
	Q256_mgt Q256(
		.clk48mhz(ti_clk),
      .rstn(rstn),
		.dac(dac),
		.status_reg(reg_dev_status),
		.debug_control(debug_control),
		.debug_status(debug_status),
		.control_reg(reg_dev_control),
		.version_reg(reg_fpga_version),
      .pulse_counter(reg_pulse_counter),
      .max_delay(reg_max_delay),
		.dc_value_reg(reg_dc_value),
		.divider_reg(reg_divider),
      .length_reg(reg_length),
		.delay_reg(reg_delay),
		
		.pattern_addr(pattern_addr),
		.pattern_column(pattern_column),
      .adjust_column(adjust_column),
      .nozzle_column(nozzle_column),
      .nozzle_addr(nozzle_addr),
		
		.segment1(reg_segment1),
		.segment2(reg_segment2),
      .segment3(reg_segment3),
      .segment4(reg_segment4),
		.segment5(reg_segment5),
		.segment6(reg_segment6),
		.segment7(reg_segment7),
		.segment8(reg_segment8),
      
		.jet_stand1(jet_stand1),
		.jet_stand2(jet_stand2),
		.jet_stand3(jet_stand3),
		.jet_stand4(jet_stand4),
		.jet_stand5(jet_stand5),
		.jet_stand6(jet_stand6),
		.jet_stand7(jet_stand7),
		
      .monitor1(dac_act1),
      .monitor2(dac_act2),
		.monitor3(dac_act3),
      .monitor4(dac_act4),
		.monitor5(dac_act5),

      .PSO(pso),
    //  .LED(led),
		.ASIC_DATA(),
		.ASIC_CLOCK(asic_clk),
		.ASIC_LATCH(asic_latch),
		.ASIC_POLARITY(asic_polarity),
      .ASIC_BLANKING(asic_blanking),
		.WASTE(waste),		
		.ok_led(ok_led),
		.jet_led(jet_led),
		.spare_led(spare_led),
		.valve_on(valve_on),
      .heat_en(heat_en),
      .sreg_heat_en(sreg_heat_en),
      .heat_on(heat_on),
		.amp_en(amp_en),
		.shdn_5v(shdn_5v),
		.shdn_120v(shdn_120v),
		.pzt_err_n(pzt_err_n),
		.pzt_clim_n(pzt_clim_n)
		);

// Need to keep the router happy by creating a clock signal to 
// be sent outside. Need to check the actual clock edges for 
// the DAC. 
ODDR2 ODDR2_inst(
 .D0(1), .D1(0), .C0(ti_clk), .C1(~ti_clk), .Q(dac_clk) );
// Flipped clock phase back, didn't help to get centered in data
// Problem was they did not document the need for >8 MCLK long CCLK signal  
ODDR2 ODDR2_CLIO(
  .D0(1), .D1(0), .C0(ti_clk), .C1(~ti_clk), .Q(MCLK) );
// Could provide signal based flipping of clocks by putting the signal into
// the D0 and D1 ports. 
 
ODDR2 ODDR2_debug1(
  .D0(1), .D1(0), .C0(ti_clk), .C1(~ti_clk), .Q(debug[1]) );

wire   sreg_heat_en = sreg_dev_control[0];

assign heat_on   = below && (heat_en || sreg_heat_en) ;

always @(posedge ti_clk) 
begin
  reg_adc_value <= adc_value;
  reg_adc_hs_value <= adc_hs_value;
end

ADC_SPI adc_interface(
      .clk48mhz(ti_clk),
      .rstn(rstn),
      .adc_cs(adc_cs),
      .adc_clk(adc_clk),
      .adc_chsel(adc_chsel),
      .adc_value(adc_value),
      .adc_hs_value(adc_hs_value),
      .adc_setpoint(reg_adc_setpoint[15:0]),
      .below(below),
      .adc_dout(adc_dout)
      );
      

assign drv_half = 1'b1;
assign drv_qtr  = 1'b1;

//assign spare[2] = pzt_clim_n;
//assign spare[1] = pzt_err_n;   
	 
assign i2c_sda = 1'bz;			// These are floated to not interfere 
assign i2c_scl = 1'bz;			// with existing Opal Kelly I2C interface.
assign hi_muxsel = 1'b0;
         
assign cpu_dac_enable = WireIn10[0];  // Controlled by cpu to toggle dacs and make pulse waveforms

assign reg_reset     = TrigIn44[0];
assign pattern_reset = TrigIn45[0];
assign sreg_reset    = TrigIn46[0];
assign adjust_reset  = TrigIn47[0];
assign nozzle_reset  = TrigIn48[0];
   
// Instantiate the pattern RAM, 128 KBytes, 16 bit on USB side, 256 bit on Application side

always @(posedge ti_clk) 
begin
	if (pattern_reset == 1'b1) begin
		pattern_u_addr <= 0;
	end 
   else 
   begin
		if ((pattern_write == 1'b1) || (  pattern_read == 1'b1))
			pattern_u_addr <= pattern_u_addr + 1;
	end
end
 		
wire [255:0] app_rddata;  
assign pattern_column = app_rddata;
// Instantiate the RAM
dpram132K_a16_b256 pattern_ram(.clk(ti_clk),             // Common clock
                          .wea(pattern_write),         
                          .addra(pattern_u_addr),
                          .dia(pattern_w_data),
                          .doa(pattern_r_data), 
                          .addrb(pattern_addr),
                          .dob(app_rddata));             

// Instantiate the adjust RAM, 8 KBytes, 16 bit on USB side, 16 bit on Application side
// It uses the same read address from the Application side as the pattern memory since
// both the pattern and the location adjustment are on the same column. 



always @(posedge ti_clk) 
begin
	if (adjust_reset == 1'b1) begin
		adjust_u_addr <= 0;
	end 
   else 
   begin
		if ((adjust_write == 1'b1) || (  adjust_read == 1'b1))
			adjust_u_addr <= adjust_u_addr + 1;
	end
end
 		
wire [15:0] adj_rddata;  
assign adjust_column = adj_rddata;
// Instantiate the RAM
dpram8K_a16_b16 adjust_ram(.clk(ti_clk),             // Common clock S
                          .wea(adjust_write),         
                          .addra(adjust_u_addr),
                          .dia(adjust_w_data),
                          .doa(adjust_r_data), 
                          .addrb(pattern_addr),  // Same column as pattern 
                          .dob(adj_rddata)); 
                                                    
                                                

   reg  [31:0] reg_length   = 2250;    // 2250 bytes in a column, 18,000 bits 0x8ca
   reg  [31:0] reg_delay    = 10001;    // # of columns in pattern, 10,000 switch columns + 1 DAC column
   wire [15:0] read_byte_count, read_count;
   wire [15:0] write_word_count; 
   wire [7:0] dout;   
   wire frame_rd_en;      
   wire dac_ready;
/* FIFO moved into Frame State machine to handle byte swizzling
// FIFO created by Core Generator, doesn't work when asked to do 16 to 8 conversion   
// Frame FIFO to load the switches in the CLIO switch matrix
// Also does the 16 bit to 8 bit conversion
// Needs two clock inputs to do width conversion.

fifo_16w_32768deep frame_fifo(
  .rst(rst),                        // input rst
  .clk(ti_clk),                     // input wr_clk
  //.rd_clk(ti_clk),                // input rd_clk
  .din(adjust_w_data),              // input [15 : 0] din
  .wr_en(adjust_write),             // input wr_en
  .rd_en(frame_rd_en),              // input rd_en
  .dout(dout),                      // output [15 : 0] dout
  .full(),                          // output full
  .empty(),                         // output empty
  .data_count(read_count)          // output [15 : 0] rd_data_count
//  .data_count(write_word_count)     // output [14 : 0] wr_data_count, useless, need to look at read side
);
   
assign read_byte_count = read_count << 1; 
assign write_word_count = read_count;

*/
Frame_State frame_state(
   .rst(rst),
   .ti_clk(ti_clk),
   .din(adjust_w_data),
   .wr_en(adjust_write),
   .dout(dout),
   .reg_length(reg_length),
   .reg_delay(reg_delay),
   .read_byte_count(read_byte_count),
   .frame_rd_en(frame_rd_en),
   .dac_ready(dac_ready),
   .FRAME(FRAME),
   .frame_state(fr_state),
   .CCLK(CCLK)
   );
   
wire [2:0] fr_state;
assign debug[9:2] = {asic_data[4:0], CCLK, FRAME};       

reg [31:0] tx_counter = 32'h0000_0000; // Counter of bytes sent to CLIO
reg cclk_reg; 
reg [15:0] cclk_counter = 0;

always @(posedge ti_clk)
begin
   cclk_reg <= CCLK;
   if (FRAME == 1'b1)
   begin
      tx_counter <= 0;
      cclk_counter <= 0;
   end
   else
   begin
   if (frame_rd_en == 1'b1)
   begin
      tx_counter <= tx_counter + 1;
   end
   if (CCLK==1 && cclk_reg == 0) 
   begin
      cclk_counter <= cclk_counter + 1;
   end
   end
end

assign asic_data = dout; //WireIn12[7:0] ; // col[7:0]; // col //8'hFF; //clk_div[33:26]; //{8{clk_div[26]}};     // Toggle all switches

assign CLIO_RSTN = rstn;

// assign DAC_EN = cpu_dac_enable && dac_ready;
assign DAC_EN = DAC_EN_IN;       // Signal from NI DAQ forwarded to CLIO chip.

// State machine to load frame buffer
// Reset, Idle, Loading, Column_Clock, DAC_Enable

 /*  
   // Select from the 16 bit wirein(12) toggling.
   reg [15:0] col;
   wire      fb;
   always@(posedge ti_clk)
   begin
	if(Frame_r)
		begin
			col<=WireIn12;
		end
	else
		begin
			col<={col[7:0],col[15:8]};   // Swap byte to send out to CLIO to send a 16 bit value
		end
   end
*/
// P(x) = x^8+x^6+x^5+x^4+1

//assign fb=col[7]^col[5]^col[4]^col[3];
   
reg [34:0] clk_div = 0;
/*
assign CCLK = 1'b0;
//assign MCLK = ti_clk; //clk_div[0];   
 */
always @(posedge ti_clk)
begin
      clk_div <= clk_div + 1;
//      if (clk_div[25:0] == 0)
//         Frame_r <= 1'b1;
//      else
//         Frame_r <= 1'b0;
end
                                              
                                                  
// Instantiate the Nozzle RAM, 2 KBytes, 16 bit on USB side, 256 bit on Application side
// The read address from the Application side advances 16 times for each pattern column
// It repeats at each pattern column location. Designed to compensate for Y-Bow.

always @(posedge ti_clk) 
begin
	if (nozzle_reset == 1'b1) begin
		nozzle_u_addr <= 0;
	end 
   else 
   begin
		if ((nozzle_write == 1'b1) || (  nozzle_read == 1'b1))
			nozzle_u_addr <= nozzle_u_addr + 1;
	end
end
 		
wire [15:0] noz_rddata, nozzle_column;  
assign nozzle_column = noz_rddata;
// Instantiate the RAM
dpram2K_a16_b256 nozzle_ram(.clk(ti_clk),             // Common clock
                          .wea(nozzle_write),         
                          .addra(nozzle_u_addr),
                          .dia(nozzle_w_data),
                          //.doa(nozzle_r_data),           // Stolen for FIFO testing 
                          .addrb(nozzle_addr),           // Generated near main pulse 
                          .dob(noz_rddata)); 

// Opal Kelly board LED    D9      D8             D7   D6              D5               D4               D3           D2 (blinky)
assign   led         = { ~DAC_EN,   1'b0, 1'b0,~SPI_SCLK ,   ~SPI_MISO      , ~SPI_CS          , ~SPI_MOSI,   clk_div[24]} ;

assign waste2 = pd[1] && pd[2];               // Adjacent pins to DAC_EN_IN, may be connected with solder

// SPI Interface, FIFO fills from Nozzle write and is read back by Nozzle read
// First Word Fall Through is needed on the write to SPI side.
// Switched to conventional FIFO for the read side.
 

wire [15:0] SPI_w_data, spi_read_count, spi_write_count, w_fifo_out;
wire SPI_data_av, clk_toggle;                                                    
              
wire rst, w_fifo_empty;
assign rst = !rstn;           
                                        
wire w_master_ready, w_TX_Ready;
wire o_RX_DV, o_SPI_MOSI, i_SPI_MISO, i_TX_DV, o_SPI_CLK;
wire  o_SPI_CS_n;
wire [15:0] o_RX_Word;
assign i_SPI_MISO = SPI_MISO;
reg read_fifo, r_TX_Ready, rr_TX_Ready;
reg [6:0] clk_counter;   
reg [2:0] word_counter = 0;

assign spare_2 = o_SPI_CLK;
assign SPI_SCLK = o_SPI_CLK;
//assign spare[1] = o_SPI_MOSI;
assign SPI_MOSI = o_SPI_MOSI;

                                    
assign strobe = o_SPI_MOSI; 

assign SPI_CS   = rr_TX_Ready; //o_SPI_CS_n;                // Need to shift later to include final clock edge
                              
fifo_16w_32768deep SPI_write_fifo(
  .clk(ti_clk),               // input clk
  .rst(rst),                  // input rst
  .din(nozzle_w_data),        // input [15 : 0] din
  .wr_en(nozzle_write),       // input wr_en
  .rd_en(read_fifo),          // input rd_en
  .dout(w_fifo_out),          // output [15 : 0] dout
  .full(),                    // output full
  .empty(w_fifo_empty),       // output empty
  .data_count(spi_write_count)               // output [10 : 0] data_count
);          

fifo_16w_32768deep_no_fwft SPI_read_fifo(
  .clk(ti_clk),               // input clk
  .rst(rst),                  // input rst
  .din(o_RX_Word),            // input [15 : 0] din
  .wr_en(o_RX_DV),            // input wr_en
  .rd_en(nozzle_read),        // input rd_en
  .dout(nozzle_r_data),       // output [15 : 0] dout
  .full(),                    // output full
  .empty(),                   // output empty
  .data_count(spi_read_count)     // output [10 : 0] data_count
);                           

always @(posedge ti_clk)
begin
   r_TX_Ready <= w_TX_Ready;
 //  rr_TX_Ready <= r_TX_Ready;
   read_fifo <= i_TX_DV;
   if (~read_fifo)
      clk_counter <= clk_counter + 1;              // Single clock stretch needed to complete last SCLK edge
   if (i_TX_DV && rr_TX_Ready)
      word_counter <= 0;
   if (read_fifo)
      word_counter <= word_counter + 1;            // Break the CS at third word to allow packed operation
   if ((word_counter == 3) && i_TX_DV)
   begin
      word_counter <= 0;
      rr_TX_Ready <= 1;
   end
      else
      rr_TX_Ready <= r_TX_Ready;
end
assign i_TX_DV = (clk_counter[6:0]==0) && !w_fifo_empty;

// debug outputs are numbered 9-1, ti_clk is on pin 0. Shows up as D0 on scope. So shift them up by 1, debug[2] is D1 on scope
//assign debug[9:2] = {w_fifo_empty,SPI_SCLK,SPI_MOSI, word_counter[0],SPI_MISO, i_TX_DV, SPI_CS,read_fifo};   

  // Instantiate Master
  SPI_Master_Reference SPI_Master_Inst (
   // Control/Data Signals,
   .i_Rst_L(rstn),               // FPGA Reset
   .i_Clk(ti_clk),               // FPGA Clock
   
   // TX (MOSI) Signals
   .i_TX_Word(w_fifo_out),       // Word to transmit
   .i_TX_DV(i_TX_DV),            // Data Valid Level
   .o_TX_Ready(w_TX_Ready),      // Transmit Ready for Word
   
   // RX (MISO) Signals
   .o_RX_DV(o_RX_DV),            // Data Valid pulse (1 clock cycle)
   .o_RX_Word(o_RX_Word),        // Word received on MISO

   // SPI Interface
   .o_SPI_Clk(o_SPI_CLK),
   .i_SPI_MISO(i_SPI_MISO),
   .o_SPI_MOSI(o_SPI_MOSI)
   );

                                   
//Other than printing registers available to software
always @(posedge ti_clk) 
begin
	if (sreg_reset == 1'b1) begin
		sreg_r_addr <= 10'd0;
      sreg_w_addr <= 10'd0;
	end 
   else 
   begin
      if (sreg_write == 1'b1)   
      	sreg_w_addr <= sreg_w_addr + 1;
			
		if (sreg_read  == 1'b1)
			sreg_r_addr <= sreg_r_addr + 1;
	end
	if (sreg_w_addr[0] == 1'b0)   // low 16 bits, comes first 
		sreg_low_store = sreg_w_data;		
end

// Register writing
always @(posedge ti_clk)
begin 
	if (sreg_w_addr[9:8] == 0 && sreg_w_addr[0] == 1'b1) begin
		case (sreg_w_addr[7:1])
      // 0x00 - 0x0C
		7'b0_0000_00: sreg_dev_control  			<= {sreg_w_data, sreg_low_store};  
      7'b0_0000_01: reg_adc_setpoint         <= {sreg_w_data, sreg_low_store};     
		default: begin
		         end
	   endcase
   end
end

reg [31:0] sreg_data;

// Register reading, accessing quad (32 bit) registers with a word (16 bit) address.
assign sreg_r_data = (sreg_r_addr[0] == 1'b0) ? sreg_data[31:16] : sreg_data[15:0];

always @(posedge ti_clk)
begin 
	if (sreg_r_addr[9:8] == 0) begin
		case (sreg_r_addr[7:1])
      // 0x0-0xC
      7'b0_0000_00: sreg_data <= sreg_dev_control;          
      7'b0_0000_01: sreg_data <= reg_adc_setpoint;         // Readback setpoint
      7'b0_0000_10: sreg_data <= reg_adc_value;            // ADC value from printhead
      7'b0_0000_11: sreg_data <= reg_adc_hs_value;         // ADC value from heat sink
		default: begin
					sreg_data <= 32'hfacecafe;
		         end
	   endcase
   end
end



//Printing registers, passed down to Q256_mgt
always @(posedge ti_clk) 
begin
	if (reg_reset == 1'b1) begin
		reg_r_addr <= 10'd0;
      reg_w_addr <= 10'd0;
	end 
   else 
   begin
      if (reg_write == 1'b1)   
      	reg_w_addr <= reg_w_addr + 1;
			
		if (reg_read  == 1'b1)
			reg_r_addr <= reg_r_addr + 1;
	end
	if (reg_w_addr[0] == 1'b0)   // low 16 bits, comes first 
		reg_low_store = reg_w_data;		
end

// Register writing
always @(posedge ti_clk)
begin 
	if (reg_w_addr[9:8] == 0 && reg_w_addr[0] == 1'b1) begin
		case (reg_w_addr[7:1])
		7'b0_0000_01: reg_dev_control  			<= {reg_w_data, reg_low_store};   
		// 0x10-0x1C 
		7'b0_0001_00: reg_length   <= {reg_w_data, reg_low_store} ; // # of bytes in a column
	 	7'b0_0001_01: reg_delay    <= {reg_w_data, reg_low_store};  // # of columns in a frame
	   7'b0_0001_10: reg_divider  <= {reg_w_data, reg_low_store};  // Encoder and clock divider
	 //  7'b0_0001_11: reg_tx_count <= {reg_w_data, reg_low_store};  // Keep track of # of bytes sent 
		// 0x20-0x2C
		7'b0_0010_00: reg_segment1 <= {reg_w_data, reg_low_store}; 	// Waveform length and slope
		7'b0_0010_01: reg_segment2 <= {reg_w_data, reg_low_store};
		7'b0_0010_10: reg_segment3 <= {reg_w_data, reg_low_store};
		7'b0_0010_11: reg_segment4 <= {reg_w_data, reg_low_store};
		// 0x30-0x3C
		7'b0_0011_00: reg_segment5 <= {reg_w_data, reg_low_store};
		7'b0_0011_01: reg_segment6 <= {reg_w_data, reg_low_store};  
		7'b0_0011_10: reg_segment7 <= {reg_w_data, reg_low_store}; 
		7'b0_0011_11: reg_segment8 <= {reg_w_data, reg_low_store}; 		
      // 0x40-0x4C      
  
		default: begin
		         end
	   endcase
   end
end

reg [31:0] reg_data;

// Register reading, accessing quad (32 bit) registers with a word (16 bit) address.
assign reg_r_data = (reg_r_addr[0] == 1'b0) ? reg_data[31:16] : reg_data[15:0];

always @(posedge ti_clk)
begin 
	if (reg_r_addr[9:8] == 0) begin
		case (reg_r_addr[7:1])
		7'b0_0000_00: reg_data <= reg_dev_status;
		7'b0_0000_01: reg_data <= reg_dev_control;
		7'b0_0000_10: reg_data <= reg_fpga_version;
		7'b0_0000_11: reg_data <= reg_adc_setpoint;        //ADC desired value, 1024 = 25C, 930 = 30C
		// 0x10-0x1C 
		7'b0_0001_00: reg_data <= reg_length; 					// # of bytes in a column
		7'b0_0001_01: reg_data <= reg_delay;               // # of columns in a frame
	   7'b0_0001_10: reg_data <= reg_divider;             // Encoder and clock divider
	   7'b0_0001_11: reg_data <= tx_counter;            // Keep track of # of bytes sent 
		// 0x20-0x2C
		7'b0_0010_00: reg_data <= reg_segment1; 				// Waveform length and slope
		7'b0_0010_01: reg_data <= reg_segment2;
		7'b0_0010_10: reg_data <= reg_segment3;
		7'b0_0010_11: reg_data <= reg_segment4;
		// 0x30-0x3C
		7'b0_0011_00: reg_data <= reg_segment5;
		7'b0_0011_01: reg_data <= reg_segment6;  
		7'b0_0011_10: reg_data <= reg_segment7; 
		7'b0_0011_11: reg_data <= reg_segment8; 
      // 0x40-0x4C          additional waveform segments to be added
      7'b0_0101_00: reg_data <= reg_adc_value;            // ADC value from printhead
      7'b0_0101_01: reg_data <= reg_adc_hs_value;         // ADC value from heat sink
      7'b0_0101_10: reg_data <= reg_pulse_counter;        // Total number of PSO pulses since trigger
      7'b0_0101_11: reg_data <= reg_max_delay;            // Maximum number of clock pulse between PSO
      // 0x50-0x5C

		default: begin
					reg_data <= 32'hdeadbeef;                 // Go with the classic
		         end
	   endcase
   end
end

wire [15:0]  debug_control, debug_status; // = 16'b0000_0000_0000_0000;
assign debug_control = WireIn11;
assign jet_stand1 = {WireIn13 , WireIn12};
assign jet_stand2 = {WireIn15 , WireIn14};
assign jet_stand3 = {WireIn17 , WireIn16};
assign jet_stand4 = {WireIn19 , WireIn18};
assign jet_stand5 = {WireIn1B , WireIn1A};
assign jet_stand6 = {WireIn1D , WireIn1C};
assign jet_stand7 = {WireIn1F , WireIn1E};

// Instantiate the okHost and connect endpoints.
wire [17*40-1:0]  ok2x;
okHost okHI(
	.hi_in(hi_in), .hi_out(hi_out), .hi_inout(hi_inout), .hi_aa(hi_aa), .ti_clk(ti_clk),
	.ok1(ok1), .ok2(ok2));

okWireOR # (.N(40)) wireOR (ok2, ok2x);

okWireIn     ep10 (.ok1(ok1),                           .ep_addr(8'h10), .ep_dataout(WireIn10)); // CPU control of DAC ENABLE bit 0
okWireIn     ep11 (.ok1(ok1),                           .ep_addr(8'h11), .ep_dataout(WireIn11)); // Reset Frame 
okWireIn     ep12 (.ok1(ok1),                           .ep_addr(8'h12), .ep_dataout(WireIn12)); // Length 1
okWireIn     ep13 (.ok1(ok1),                           .ep_addr(8'h13), .ep_dataout(WireIn13)); // Slope 1
okWireIn     ep14 (.ok1(ok1),                           .ep_addr(8'h14), .ep_dataout(WireIn14)); // Length 2
okWireIn     ep15 (.ok1(ok1),                           .ep_addr(8'h15), .ep_dataout(WireIn15)); // Slope 2 
okWireIn     ep16 (.ok1(ok1),                           .ep_addr(8'h16), .ep_dataout(WireIn16)); // Length 3
okWireIn     ep17 (.ok1(ok1),                           .ep_addr(8'h17), .ep_dataout(WireIn17)); // Slope 3
okWireIn     ep18 (.ok1(ok1),                           .ep_addr(8'h18), .ep_dataout(WireIn18)); // Length 4
okWireIn     ep19 (.ok1(ok1),                           .ep_addr(8'h19), .ep_dataout(WireIn19)); // Slope 4
okWireIn     ep1A (.ok1(ok1),                           .ep_addr(8'h1A), .ep_dataout(WireIn1A)); // Length 5 
okWireIn     ep1B (.ok1(ok1),                           .ep_addr(8'h1B), .ep_dataout(WireIn1B)); // Slope 5 
okWireIn     ep1C (.ok1(ok1),                           .ep_addr(8'h1C), .ep_dataout(WireIn1C)); // Length 6 
okWireIn     ep1D (.ok1(ok1),                           .ep_addr(8'h1D), .ep_dataout(WireIn1D)); // Slope 6 
okWireIn     ep1E (.ok1(ok1),                           .ep_addr(8'h1E), .ep_dataout(WireIn1E)); // Length 7 
okWireIn     ep1F (.ok1(ok1),                           .ep_addr(8'h1F), .ep_dataout(WireIn1F)); // Slope 7 

okWireOut 	 ep21 (.ok1(ok1), .ok2(ok2x[ 9*17 +: 17 ]), .ep_addr(8'h21), .ep_datain(read_byte_count));  
okWireOut 	 ep22 (.ok1(ok1), .ok2(ok2x[11*17 +: 17 ]), .ep_addr(8'h22), .ep_datain(read_byte_count));
okWireOut 	 ep23 (.ok1(ok1), .ok2(ok2x[12*17 +: 17 ]), .ep_addr(8'h23), .ep_datain(write_word_count));  // Write count is odd, always has a 1
okWireOut 	 ep24 (.ok1(ok1), .ok2(ok2x[13*17 +: 17 ]), .ep_addr(8'h24), .ep_datain(tx_counter[15:0]));
okWireOut 	 ep25 (.ok1(ok1), .ok2(ok2x[14*17 +: 17 ]), .ep_addr(8'h25), .ep_datain(tx_counter[31:16]));
okWireOut 	 ep26 (.ok1(ok1), .ok2(ok2x[15*17 +: 17 ]), .ep_addr(8'h26), .ep_datain(cclk_counter));
okWireOut 	 ep27 (.ok1(ok1), .ok2(ok2x[16*17 +: 17 ]), .ep_addr(8'h27), .ep_datain(dac_act3[31:16]));
okWireOut 	 ep28 (.ok1(ok1), .ok2(ok2x[17*17 +: 17 ]), .ep_addr(8'h28), .ep_datain(dac_act4[15:0]));
okWireOut 	 ep29 (.ok1(ok1), .ok2(ok2x[18*17 +: 17 ]), .ep_addr(8'h29), .ep_datain(dac_act4[31:16]));
okWireOut 	 ep2A (.ok1(ok1), .ok2(ok2x[19*17 +: 17 ]), .ep_addr(8'h2A), .ep_datain(spi_write_count));
okWireOut    ep2B (.ok1(ok1), .ok2(ok2x[21*17 +: 17 ]), .ep_addr(8'h2B), .ep_datain(spi_read_count)); 
okWireOut    ep2C (.ok1(ok1), .ok2(ok2x[22*17 +: 17 ]), .ep_addr(8'h2C), .ep_datain(~K_A_INPUT)); 

okTriggerIn  ep40 (.ok1(ok1),                           .ep_addr(8'h40), .ep_clk(ti_clk), .ep_trigger(TrigIn40));
okTriggerIn  ep41 (.ok1(ok1),                           .ep_addr(8'h41), .ep_clk(ti_clk), .ep_trigger(TrigIn41));
okTriggerIn  ep42 (.ok1(ok1),                           .ep_addr(8'h42), .ep_clk(ti_clk), .ep_trigger(TrigIn42));
okTriggerIn  ep43 (.ok1(ok1),                           .ep_addr(8'h43), .ep_clk(ti_clk), .ep_trigger(TrigIn43));
okTriggerIn  ep44 (.ok1(ok1),                           .ep_addr(8'h44), .ep_clk(ti_clk), .ep_trigger(TrigIn44));
okTriggerIn  ep45 (.ok1(ok1),                           .ep_addr(8'h45), .ep_clk(ti_clk), .ep_trigger(TrigIn45));
okTriggerIn  ep46 (.ok1(ok1),                           .ep_addr(8'h46), .ep_clk(ti_clk), .ep_trigger(TrigIn46));
okTriggerIn  ep47 (.ok1(ok1),                           .ep_addr(8'h47), .ep_clk(ti_clk), .ep_trigger(TrigIn47));
okTriggerIn  ep48 (.ok1(ok1),                           .ep_addr(8'h48), .ep_clk(ti_clk), .ep_trigger(TrigIn48));
okTriggerIn  ep49 (.ok1(ok1),                           .ep_addr(8'h49), .ep_clk(ti_clk), .ep_trigger(TrigIn49));
okTriggerIn  ep4A (.ok1(ok1),                           .ep_addr(8'h4A), .ep_clk(ti_clk), .ep_trigger(TrigIn4A));
okTriggerIn  ep4B (.ok1(ok1),                           .ep_addr(8'h4B), .ep_clk(ti_clk), .ep_trigger(TrigIn4B));
okTriggerIn  ep4C (.ok1(ok1),                           .ep_addr(8'h4C), .ep_clk(ti_clk), .ep_trigger(TrigIn4C));
okTriggerIn  ep4D (.ok1(ok1),                           .ep_addr(8'h4D), .ep_clk(ti_clk), .ep_trigger(TrigIn4D));
okTriggerIn  ep4E (.ok1(ok1),                           .ep_addr(8'h4E), .ep_clk(ti_clk), .ep_trigger(TrigIn4E));
//okTriggerOut ep60 (.ok1(ok1), .ok2(ok2x[ 0*17 +: 17 ]), .ep_addr(8'h60), .ep_clk(clk1), .ep_trigger(TrigOut60));

okPipeIn     ep84 (.ok1(ok1), .ok2(ok2x[  5*17 +: 17 ]), .ep_addr(8'h84), .ep_write(reg_write),     .ep_dataout(reg_w_data));
okPipeIn     ep85 (.ok1(ok1), .ok2(ok2x[ 20*17 +: 17 ]), .ep_addr(8'h85), .ep_write(pattern_write), .ep_dataout(pattern_w_data));
okPipeIn     ep86 (.ok1(ok1), .ok2(ok2x[  6*17 +: 17 ]), .ep_addr(8'h86), .ep_write(sreg_write),    .ep_dataout(sreg_w_data));
okPipeIn     ep87 (.ok1(ok1), .ok2(ok2x[ 23*17 +: 17 ]), .ep_addr(8'h87), .ep_write(adjust_write),  .ep_dataout(adjust_w_data));
okPipeIn     ep88 (.ok1(ok1), .ok2(ok2x[ 24*17 +: 17 ]), .ep_addr(8'h88), .ep_write(nozzle_write),  .ep_dataout(nozzle_w_data));

okPipeOut    epA4 (.ok1(ok1), .ok2(ok2x[ 10*17 +: 17 ]), .ep_addr(8'ha4), .ep_read(reg_read),       .ep_datain(reg_r_data));
okPipeOut    epA5 (.ok1(ok1), .ok2(ok2x[ 30*17 +: 17 ]), .ep_addr(8'ha5), .ep_read(pattern_read),   .ep_datain(pattern_r_data)); /* pattern_u_addr*/
okPipeOut    epA6 (.ok1(ok1), .ok2(ok2x[  7*17 +: 17 ]), .ep_addr(8'ha6), .ep_read(sreg_read),      .ep_datain(sreg_r_data));
okPipeOut    epA7 (.ok1(ok1), .ok2(ok2x[  8*17 +: 17 ]), .ep_addr(8'ha7), .ep_read(adjust_read),    .ep_datain(adjust_r_data)); /* adjust_u_addr*/
okPipeOut    epA8 (.ok1(ok1), .ok2(ok2x[ 25*17 +: 17 ]), .ep_addr(8'ha8), .ep_read(nozzle_read),    .ep_datain(nozzle_r_data)); /* nozzle_u_addr*/

endmodule