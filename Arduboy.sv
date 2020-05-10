//============================================================================
//  Arduboy MiSTer core by uXeBoy (Dan O'Shea)
//
//  XMEGA-CORE by Iulian Gheorghiu (morgoth@devboard.tech) Copyright (C) 2020
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
    //Master input clock
    input         CLK_50M,

    //Async reset from top-level module.
    //Can be used as initial reset.
    input         RESET,

    //Must be passed to hps_io module
    inout  [45:0] HPS_BUS,

    //Base video clock. Usually equals to CLK_SYS.
    output        VGA_CLK,

    //Multiple resolutions are supported using different VGA_CE rates.
    //Must be based on CLK_VIDEO
    output        VGA_CE,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE, // = ~(VBlank | HBlank)
    output        VGA_F1,

    //Base video clock. Usually equals to CLK_SYS.
    output        HDMI_CLK,

    //Multiple resolutions are supported using different HDMI_CE rates.
    //Must be based on CLK_VIDEO
    output        HDMI_CE,

    output  [7:0] HDMI_R,
    output  [7:0] HDMI_G,
    output  [7:0] HDMI_B,
    output        HDMI_HS,
    output        HDMI_VS,
    output        HDMI_DE, // = ~(VBlank | HBlank)
    output  [1:0] HDMI_SL, // scanlines fx

    //Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
    output  [7:0] HDMI_ARX,
    output  [7:0] HDMI_ARY,

    output        LED_USER, // 1 - ON, 0 - OFF.

    // b[1]: 0 - LED status is system status OR'd with b[0]
    //       1 - LED status is controled solely by b[0]
    // hint: supply 2'b00 to let the system control the LED.
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,

    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned

    // Open-drain User port.
    // 0 - D+/RX
    // 1 - D-/TX
    // 2..6 - USR2..USR6
    // Set USER_OUT to 1 to read from USER_IN.
	output	USER_OSD,
	output	[1:0] USER_MODE,
	input	[7:0] USER_IN,
	output	[7:0] USER_OUT,

	input         OSD_STATUS
);


assign HDMI_ARX    = status[1] ? 8'd9  : 8'd16;
assign HDMI_ARY    = status[1] ? 8'd16 : 8'd9;
assign VGA_F1      = 0;

assign LED_POWER   = 0;
assign LED_DISK[1] = 0;
wire         CLK_JOY = CLK_50M;         //Assign clock between 40-50Mhz
wire   [2:0] JOY_FLAG  = {status[30],status[31],status[29]}; //Assign 3 bits of status (31:29) o (63:61)
wire         JOY_CLK, JOY_LOAD, JOY_SPLIT, JOY_MDSEL;
wire   [5:0] JOY_MDIN  = JOY_FLAG[2] ? {USER_IN[6],USER_IN[3],USER_IN[5],USER_IN[7],USER_IN[1],USER_IN[2]} : 1;
wire         JOY_DATA  = JOY_FLAG[1] ? USER_IN[5] : '1;
assign       USER_OUT  = JOY_FLAG[2] ? {3'b111,JOY_SPLIT,3'b111,JOY_MDSEL} : JOY_FLAG[1] ? {6'b111111,JOY_CLK,JOY_LOAD} : 1;
assign       USER_MODE = JOY_FLAG[2:1] ;
assign       USER_OSD  = joydb_1[10] & joydb_1[6];

assign AUDIO_S     = 0;
assign AUDIO_L     = {1'b0,{15{Buzzer1}}} + {1'b0,{15{Buzzer2}}};
assign AUDIO_R     = AUDIO_L;

///////////////////////////////////////////////////////

wire clk_sys, clk_avr;
pll pll
(
    .refclk(CLK_50M),
    .outclk_0(clk_sys),
    .outclk_1(clk_avr)
);

// make reset at least 65K cycles long.
reg reset = 1;
always @(posedge clk_avr) begin
    reg [15:0] reset_cnt = 0;

    reset <= 0;
    if(~&reset_cnt) begin
        reset_cnt <= reset_cnt + 1'd1;
        reset <= 1;
    end

    if(status[0] | buttons[1] | RESET | ioctl_download) reset_cnt <= 0;
end

///////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR =
{
    "Arduboy;;",
    "F0,BINHEX;",
    "R0,Reset;",
    "-;",
    "O1,Orientation,Horizontal,Vertical;",
    "O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "OUV,UserIO Joystick,Off,DB9MD,DB15 ;",
    "OT,UserIO Players, 1 Player,2 Players;",
    "-;",
    "OFG,ADC,Random,AnalogStick,Paddle;",
    "J1,A,B;",
    "V,v",`BUILD_DATE
};

wire [31:0] joystick_USB;
wire [15:0] joystick_analog;
wire  [7:0] paddle;
wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;

wire        ioctl_download;
wire        ioctl_wr;
wire [14:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;

// B A U D L R 
wire [31:0] joystick = joydb_1ena ? (OSD_STATUS? 32'b000000 : joydb_1[5:0]) : joystick_USB;

wire [15:0] joydb_1 = JOY_FLAG[2] ? JOYDB9MD_1 : JOY_FLAG[1] ? JOYDB15_1 : '0;
wire        joydb_1ena = |JOY_FLAG[2:1]              ;
wire        joydb_2ena = |JOY_FLAG[2:1] & JOY_FLAG[0];

//----BA 9876543210
//----MS ZYXCBAUDLR
reg [15:0] JOYDB9MD_1,JOYDB9MD_2;
joy_db9md joy_db9md
(
  .clk       ( CLK_JOY    ), //40-50MHz
  .joy_split ( JOY_SPLIT  ),
  .joy_mdsel ( JOY_MDSEL  ),
  .joy_in    ( JOY_MDIN   ),
  .joystick1 ( JOYDB9MD_1 ),
  .joystick2 ( JOYDB9MD_2 )	  
);

//----BA 9876543210
//----LS FEDCBAUDLR
reg [15:0] JOYDB15_1,JOYDB15_2;
joy_db15 joy_db15
(
  .clk       ( CLK_JOY   ), //48MHz
  .JOY_CLK   ( JOY_CLK   ),
  .JOY_DATA  ( JOY_DATA  ),
  .JOY_LOAD  ( JOY_LOAD  ),
  .joystick1 ( JOYDB15_1 ),
  .joystick2 ( JOYDB15_2 )	  
);

hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .conf_str(CONF_STR),
    .joystick_0(joystick_USB),
    .joystick_analog_0(joystick_analog),
    .paddle_0(paddle),
    .status(status),
    .buttons(buttons),
    .forced_scandoubler(forced_scandoubler),

    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .joy_raw(OSD_STATUS? joydb_1[5:0] : 6'b000000 )
);

(* ram_init_file = "Arduventure.mif" *)
reg  [1:0][7:0] rom[16384];
wire [13:0] pgm_addr;
reg  [15:0] pgm_data;

always @ (posedge clk_avr) pgm_data <= rom[pgm_addr];

wire [3:0] digit = (ioctl_dout[7:4] != 3) ? (ioctl_dout[3:0] + 4'd9) : ioctl_dout[3:0];
always @ (posedge clk_sys) begin
    reg  [3:0] state = 0;
    reg  [7:0] cnt;
    reg [15:0] addr;
    reg  [3:0] code;

    if (ioctl_wr) begin
        if(!ioctl_index) rom[ioctl_addr[14:1]][ioctl_addr[0]] <= ioctl_dout;
        else begin
            if(state) state <= state + 1'd1;
            case(state)
                 0: if(ioctl_dout == ":") state <= state + 1'd1;
                 1: cnt[7:4]    <= digit;
                 2: cnt[3:0]    <= digit;
                 3: addr[15:12] <= digit;
                 4: addr[11:8]  <= digit;
                 5: addr[7:4]   <= digit;
                 6: addr[3:0]   <= digit;
                 7: code        <= digit;
                 8: if({code,digit}) state <= 0;
                 9: code        <= digit;
                10: begin
                        rom[addr[14:1]][addr[0]] <= {code,digit};
                        addr <= addr + 1'd1;
                        cnt <= cnt - 1'd1;
                        state <= state - 1'd1;
                        if(cnt == 1) state <= 0;
                    end
            endcase
        end
    end

    if(!ioctl_download) state <= 0;
end

wire Buzzer1, Buzzer2;
wire oled_dc, oled_clk, oled_data;

atmega32u4 atmega32u4
(
    .clk(clk_avr),
    .rst(reset),
    .pgm_addr(pgm_addr),
    .pgm_data(pgm_data),
    .buttons(~(status[1] ? {joystick[5:4], joystick[1], joystick[0], joystick[2], joystick[3]} : joystick[5:0])),
    .joystick_analog(status[16] ? {~paddle[7],paddle[6:0]} : joystick_analog[7:0]),
    .status(|status[16:15]),
    .RGB({LED_USER, LED_DISK[0]}),
    .Buzzer1(Buzzer1),
    .Buzzer2(Buzzer2),
    .DC(oled_dc),
    .spi_scl(oled_clk),
    .spi_mosi(oled_data),
    .uart_rx(USER_IN[0]),
    //.uart_tx(USER_OUT[1])
);

wire pixelValue, ce_pix;
wire VSync, HSync, HBlank, VBlank;

vgaHdmi vgaHdmi
(
    .clock(clk_sys),
    .reset(reset),
    .oled_dc(oled_dc),
    .oled_clk(oled_clk),
    .oled_data(oled_data),
    .hsync(HSync),
    .vsync(VSync),
    .hblank(HBlank),
    .vblank(VBlank),
    .pixelValue(pixelValue),
    .ce_pix(ce_pix)
);

arcade_video #(256,144,6) arcade_video
(
    .*,
    .clk_video(clk_sys),
    .RGB_in({6{pixelValue}}),

    .forced_scandoubler(0),
    .gamma_bus(),
    .no_rotate(~status[1]),
    .rotate_ccw(1),
    .fx(status[5:3])
);

endmodule
