`default_nettype none

// -----------------------------------------------------------------------------
// chip_top: configuracion JTAG + eFPGA (FABulous)
//   - jtag_fabric_config genera FrameData / FrameStrobe
//   - eFPGA es el fabric generado (o eFPGA_mock.v para simular sin fabric)
//   - Los 24 IO del fabric salen como pad_in / pad_out / pad_oe
// Generado por gen_glue.py
// -----------------------------------------------------------------------------
module chip_top #(
    parameter ROWS               = 14,
    parameter COLS               = 2,
    parameter FRAME_BITS_PER_ROW = 32,
    parameter MAX_FRAMES_PER_COL = 20
) (
    // JTAG (pines dedicados, fuera del fabric)
    input  wire        tck,
    input  wire        tms,
    input  wire        tdi,
    input  wire        trst_n,
    output wire        tdo,          // alta impedancia fuera de Shift-DR/IR

    // Reloj y reset del sistema
    input  wire        clk,          // UserCLK del fabric y reloj del lado clk del JTAG
    input  wire        rst_n,

    // IO de usuario del fabric
    input  wire [23:0]  pad_in,       // pad -> fabric
    output wire [23:0]  pad_out,      // fabric -> pad
    output wire [23:0]  pad_oe,       // 1 = el fabric maneja el pad

    output wire        cfg_busy
);

    localparam FRAME_W  = FRAME_BITS_PER_ROW * ROWS;
    localparam N_STROBE = MAX_FRAMES_PER_COL * COLS;

    wire [FRAME_W-1:0]  FrameData;
    wire [N_STROBE-1:0] FrameStrobe;
    wire                tdo_int, tdo_oe;

    jtag_fabric_config #(
        .FRAME_BITS_PER_ROW (FRAME_BITS_PER_ROW),
        .ROWS               (ROWS),
        .COLS               (COLS),
        .MAX_FRAMES_PER_COL (MAX_FRAMES_PER_COL)
    ) jtag_i (
        .tck         (tck),
        .tms         (tms),
        .tdi         (tdi),
        .trst_n      (trst_n),
        .tdo         (tdo_int),
        .tdo_oe      (tdo_oe),
        .clk         (clk),
        .rst_n       (rst_n),
        .FrameData   (FrameData),
        .FrameStrobe (FrameStrobe),
        .cfg_busy    (cfg_busy)
    );

    assign tdo = tdo_oe ? tdo_int : 1'bz;

    // Convencion de la celda IO_1_bidirectional_frame_config_pass:
    //   I_top = dato del fabric hacia el pad,
    //   T_top = habilitacion de salida, activa en alto (la celda hace T_top = ~T),
    //   O_top = dato del pad hacia el fabric.
    wire [23:0] fab_i, fab_t;
    assign pad_out = fab_i;
    assign pad_oe  = fab_t;     // T_top = ~T en la celda IO -> ya es habilitacion de salida

    eFPGA fabric_i (
        .UserCLK     (clk),
        .FrameData   (FrameData),
        .FrameStrobe (FrameStrobe),
        .Tile_X0Y1_A_O_top (pad_in[23]),
        .Tile_X0Y1_A_I_top (fab_i[23]),
        .Tile_X0Y1_A_T_top (fab_t[23]),
        .Tile_X0Y1_B_O_top (pad_in[22]),
        .Tile_X0Y1_B_I_top (fab_i[22]),
        .Tile_X0Y1_B_T_top (fab_t[22]),
        .Tile_X0Y1_A_config_C_bit0 (),
        .Tile_X0Y1_A_config_C_bit1 (),
        .Tile_X0Y1_A_config_C_bit2 (),
        .Tile_X0Y1_A_config_C_bit3 (),
        .Tile_X0Y1_B_config_C_bit0 (),
        .Tile_X0Y1_B_config_C_bit1 (),
        .Tile_X0Y1_B_config_C_bit2 (),
        .Tile_X0Y1_B_config_C_bit3 (),
        .Tile_X0Y2_A_O_top (pad_in[21]),
        .Tile_X0Y2_A_I_top (fab_i[21]),
        .Tile_X0Y2_A_T_top (fab_t[21]),
        .Tile_X0Y2_B_O_top (pad_in[20]),
        .Tile_X0Y2_B_I_top (fab_i[20]),
        .Tile_X0Y2_B_T_top (fab_t[20]),
        .Tile_X0Y2_A_config_C_bit0 (),
        .Tile_X0Y2_A_config_C_bit1 (),
        .Tile_X0Y2_A_config_C_bit2 (),
        .Tile_X0Y2_A_config_C_bit3 (),
        .Tile_X0Y2_B_config_C_bit0 (),
        .Tile_X0Y2_B_config_C_bit1 (),
        .Tile_X0Y2_B_config_C_bit2 (),
        .Tile_X0Y2_B_config_C_bit3 (),
        .Tile_X0Y3_A_O_top (pad_in[19]),
        .Tile_X0Y3_A_I_top (fab_i[19]),
        .Tile_X0Y3_A_T_top (fab_t[19]),
        .Tile_X0Y3_B_O_top (pad_in[18]),
        .Tile_X0Y3_B_I_top (fab_i[18]),
        .Tile_X0Y3_B_T_top (fab_t[18]),
        .Tile_X0Y3_A_config_C_bit0 (),
        .Tile_X0Y3_A_config_C_bit1 (),
        .Tile_X0Y3_A_config_C_bit2 (),
        .Tile_X0Y3_A_config_C_bit3 (),
        .Tile_X0Y3_B_config_C_bit0 (),
        .Tile_X0Y3_B_config_C_bit1 (),
        .Tile_X0Y3_B_config_C_bit2 (),
        .Tile_X0Y3_B_config_C_bit3 (),
        .Tile_X0Y4_A_O_top (pad_in[17]),
        .Tile_X0Y4_A_I_top (fab_i[17]),
        .Tile_X0Y4_A_T_top (fab_t[17]),
        .Tile_X0Y4_B_O_top (pad_in[16]),
        .Tile_X0Y4_B_I_top (fab_i[16]),
        .Tile_X0Y4_B_T_top (fab_t[16]),
        .Tile_X0Y4_A_config_C_bit0 (),
        .Tile_X0Y4_A_config_C_bit1 (),
        .Tile_X0Y4_A_config_C_bit2 (),
        .Tile_X0Y4_A_config_C_bit3 (),
        .Tile_X0Y4_B_config_C_bit0 (),
        .Tile_X0Y4_B_config_C_bit1 (),
        .Tile_X0Y4_B_config_C_bit2 (),
        .Tile_X0Y4_B_config_C_bit3 (),
        .Tile_X0Y5_A_O_top (pad_in[15]),
        .Tile_X0Y5_A_I_top (fab_i[15]),
        .Tile_X0Y5_A_T_top (fab_t[15]),
        .Tile_X0Y5_B_O_top (pad_in[14]),
        .Tile_X0Y5_B_I_top (fab_i[14]),
        .Tile_X0Y5_B_T_top (fab_t[14]),
        .Tile_X0Y5_A_config_C_bit0 (),
        .Tile_X0Y5_A_config_C_bit1 (),
        .Tile_X0Y5_A_config_C_bit2 (),
        .Tile_X0Y5_A_config_C_bit3 (),
        .Tile_X0Y5_B_config_C_bit0 (),
        .Tile_X0Y5_B_config_C_bit1 (),
        .Tile_X0Y5_B_config_C_bit2 (),
        .Tile_X0Y5_B_config_C_bit3 (),
        .Tile_X0Y6_A_O_top (pad_in[13]),
        .Tile_X0Y6_A_I_top (fab_i[13]),
        .Tile_X0Y6_A_T_top (fab_t[13]),
        .Tile_X0Y6_B_O_top (pad_in[12]),
        .Tile_X0Y6_B_I_top (fab_i[12]),
        .Tile_X0Y6_B_T_top (fab_t[12]),
        .Tile_X0Y6_A_config_C_bit0 (),
        .Tile_X0Y6_A_config_C_bit1 (),
        .Tile_X0Y6_A_config_C_bit2 (),
        .Tile_X0Y6_A_config_C_bit3 (),
        .Tile_X0Y6_B_config_C_bit0 (),
        .Tile_X0Y6_B_config_C_bit1 (),
        .Tile_X0Y6_B_config_C_bit2 (),
        .Tile_X0Y6_B_config_C_bit3 (),
        .Tile_X0Y7_A_O_top (pad_in[11]),
        .Tile_X0Y7_A_I_top (fab_i[11]),
        .Tile_X0Y7_A_T_top (fab_t[11]),
        .Tile_X0Y7_B_O_top (pad_in[10]),
        .Tile_X0Y7_B_I_top (fab_i[10]),
        .Tile_X0Y7_B_T_top (fab_t[10]),
        .Tile_X0Y7_A_config_C_bit0 (),
        .Tile_X0Y7_A_config_C_bit1 (),
        .Tile_X0Y7_A_config_C_bit2 (),
        .Tile_X0Y7_A_config_C_bit3 (),
        .Tile_X0Y7_B_config_C_bit0 (),
        .Tile_X0Y7_B_config_C_bit1 (),
        .Tile_X0Y7_B_config_C_bit2 (),
        .Tile_X0Y7_B_config_C_bit3 (),
        .Tile_X0Y8_A_O_top (pad_in[9]),
        .Tile_X0Y8_A_I_top (fab_i[9]),
        .Tile_X0Y8_A_T_top (fab_t[9]),
        .Tile_X0Y8_B_O_top (pad_in[8]),
        .Tile_X0Y8_B_I_top (fab_i[8]),
        .Tile_X0Y8_B_T_top (fab_t[8]),
        .Tile_X0Y8_A_config_C_bit0 (),
        .Tile_X0Y8_A_config_C_bit1 (),
        .Tile_X0Y8_A_config_C_bit2 (),
        .Tile_X0Y8_A_config_C_bit3 (),
        .Tile_X0Y8_B_config_C_bit0 (),
        .Tile_X0Y8_B_config_C_bit1 (),
        .Tile_X0Y8_B_config_C_bit2 (),
        .Tile_X0Y8_B_config_C_bit3 (),
        .Tile_X0Y9_A_O_top (pad_in[7]),
        .Tile_X0Y9_A_I_top (fab_i[7]),
        .Tile_X0Y9_A_T_top (fab_t[7]),
        .Tile_X0Y9_B_O_top (pad_in[6]),
        .Tile_X0Y9_B_I_top (fab_i[6]),
        .Tile_X0Y9_B_T_top (fab_t[6]),
        .Tile_X0Y9_A_config_C_bit0 (),
        .Tile_X0Y9_A_config_C_bit1 (),
        .Tile_X0Y9_A_config_C_bit2 (),
        .Tile_X0Y9_A_config_C_bit3 (),
        .Tile_X0Y9_B_config_C_bit0 (),
        .Tile_X0Y9_B_config_C_bit1 (),
        .Tile_X0Y9_B_config_C_bit2 (),
        .Tile_X0Y9_B_config_C_bit3 (),
        .Tile_X0Y10_A_O_top (pad_in[5]),
        .Tile_X0Y10_A_I_top (fab_i[5]),
        .Tile_X0Y10_A_T_top (fab_t[5]),
        .Tile_X0Y10_B_O_top (pad_in[4]),
        .Tile_X0Y10_B_I_top (fab_i[4]),
        .Tile_X0Y10_B_T_top (fab_t[4]),
        .Tile_X0Y10_A_config_C_bit0 (),
        .Tile_X0Y10_A_config_C_bit1 (),
        .Tile_X0Y10_A_config_C_bit2 (),
        .Tile_X0Y10_A_config_C_bit3 (),
        .Tile_X0Y10_B_config_C_bit0 (),
        .Tile_X0Y10_B_config_C_bit1 (),
        .Tile_X0Y10_B_config_C_bit2 (),
        .Tile_X0Y10_B_config_C_bit3 (),
        .Tile_X0Y11_A_O_top (pad_in[3]),
        .Tile_X0Y11_A_I_top (fab_i[3]),
        .Tile_X0Y11_A_T_top (fab_t[3]),
        .Tile_X0Y11_B_O_top (pad_in[2]),
        .Tile_X0Y11_B_I_top (fab_i[2]),
        .Tile_X0Y11_B_T_top (fab_t[2]),
        .Tile_X0Y11_A_config_C_bit0 (),
        .Tile_X0Y11_A_config_C_bit1 (),
        .Tile_X0Y11_A_config_C_bit2 (),
        .Tile_X0Y11_A_config_C_bit3 (),
        .Tile_X0Y11_B_config_C_bit0 (),
        .Tile_X0Y11_B_config_C_bit1 (),
        .Tile_X0Y11_B_config_C_bit2 (),
        .Tile_X0Y11_B_config_C_bit3 (),
        .Tile_X0Y12_A_O_top (pad_in[1]),
        .Tile_X0Y12_A_I_top (fab_i[1]),
        .Tile_X0Y12_A_T_top (fab_t[1]),
        .Tile_X0Y12_B_O_top (pad_in[0]),
        .Tile_X0Y12_B_I_top (fab_i[0]),
        .Tile_X0Y12_B_T_top (fab_t[0]),
        .Tile_X0Y12_A_config_C_bit0 (),
        .Tile_X0Y12_A_config_C_bit1 (),
        .Tile_X0Y12_A_config_C_bit2 (),
        .Tile_X0Y12_A_config_C_bit3 (),
        .Tile_X0Y12_B_config_C_bit0 (),
        .Tile_X0Y12_B_config_C_bit1 (),
        .Tile_X0Y12_B_config_C_bit2 (),
        .Tile_X0Y12_B_config_C_bit3 ()
    );

endmodule
`resetall
