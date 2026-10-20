`default_nettype none
// -----------------------------------------------------------------------------
// de0nano_efpga_top: top level para la Terasic DE0-Nano-SoC (Cyclone V SE 5CSEMA4U23C6)
//
//   ROM (bitstream) --> maestro JTAG interno --> jtag_fabric_config --> eFPGA (benchmark)
//
// Reutiliza chip_top.v, el mismo que genera gen_glue.py y que ya paso la simulacion
// (jtag_fabric_config + eFPGA). Aqui se anade lo que en simulacion hacia el testbench:
// la ROM con el bitstream y el maestro JTAG interno.
//
// Uso en la placa:
//   SW[0]    1 = cargar el bitstream por JTAG (nivel; vuelve a 0 y a 1 para recargar)
//   SW[1]    1 = reset del sistema (activo en alto). No se usan los botones KEY.
//   LED[0]   cargando          LED[1] configuracion terminada
//   LED[2]   latido (~1.5 Hz)  LED[3] reset activo
//   LED[7:4] 4 bits de la salida del benchmark, desde el pin LED_BASE (ver parametros)
//   GPIO_1[BM_IO-1:0]  los BM_IO IO del benchmark (los de X0Y1..), bidireccionales.
//                 Solo se manejan como salida cuando done = 1 y el fabric lo habilita.
//   GPIO_0[0..6]  depuracion: TCK, TMS, TDI, cargando, done, cfg_busy, sys_clk
//
// Los nombres de puerto son los del proyecto de Terasic (FPGA_CLK1_50, SW, LED,
// GPIO_0, GPIO_1), asi que sirve el .qsf de la placa tal cual.
// -----------------------------------------------------------------------------
module de0nano_efpga_top #(
    // Geometria del fabric (los valores que imprime run_matmul_test.sh / gen_glue.py)
    //   fabric reducido de 6 filas de datos y W_IO + 3 LUT4AB:  ROWS=8  COLS=4  NIO=12  N_FRAMES=80
    parameter ROWS               = 8,    // filas de FrameData = filas de datos + 2 de borde
    parameter COLS               = 4,    // columnas del fabric (W_IO + las de LUT4AB)
    parameter FRAME_BITS_PER_ROW = 32,
    parameter MAX_FRAMES_PER_COL = 20,
    parameter NIO                = 12,   // IO del fabric (2 por fila de datos)
    parameter BM_IO              = 12,   // pines que usa el benchmark (los de mayor indice de pad)
    parameter LED_BASE           = 4,    // LED[7:4] = bits LED_BASE+3..LED_BASE de io_out del benchmark
    // Bitstream: COLS * MAX_FRAMES_PER_COL frames
    parameter N_FRAMES           = 80,
    parameter INIT_FILE          = "bitstream_rom.hex",
    // Reloj del sistema = 50 MHz / 2^SYS_DIV_LOG2 (lo usan el fabric, el JTAG y el benchmark)
    parameter SYS_DIV_LOG2       = 2,    // >= 1
    // TCK = reloj del sistema / (2*TCK_HALF)
    parameter TCK_HALF           = 3
) (
    input  wire        FPGA_CLK1_50,
    input  wire [3:0]  SW,
    output wire [7:0]  LED,
    inout  wire [35:0] GPIO_0,
    inout  wire [35:0] GPIO_1
);
    localparam ROM_DEPTH = N_FRAMES * (ROWS + 1);
    localparam ROM_AW    = (ROM_DEPTH > 1) ? $clog2(ROM_DEPTH) : 1;
    localparam PAD_BASE  = NIO - BM_IO;   // el benchmark ocupa los BM_IO pads de mayor indice

    wire clk50 = FPGA_CLK1_50;

    // ------------------------------------------------------------------
    // Reloj del sistema (division de 50 MHz) y reset
    // ------------------------------------------------------------------
    reg [SYS_DIV_LOG2-1:0] div_cnt = {SYS_DIV_LOG2{1'b0}};
    always @(posedge clk50) div_cnt <= div_cnt + 1'b1;
    wire sys_clk = div_cnt[SYS_DIV_LOG2-1];

    reg [15:0] por_cnt = 16'd0;                       // ~1.3 ms a 50 MHz
    wire       por_done = &por_cnt;
    always @(posedge clk50) if (!por_done) por_cnt <= por_cnt + 16'd1;

    wire rst_req_n = por_done & ~SW[1];            // SW[1] = 1 mantiene el sistema en reset
    // rst_ff arranca en 11 y el reset de encendido lo baja en el primer ciclo: asi rst_n tiene un
    // flanco de bajada real (en simulacion, los registros con reset asincrono por flanco del JTAG
    // se quedarian en 'x' si rst_n empezara ya en 0).
    reg [1:0] rst_ff = 2'b11;                         // reset asincrono, liberacion sincrona
    always @(posedge sys_clk or negedge rst_req_n)
        if (!rst_req_n) rst_ff <= 2'b00;
        else            rst_ff <= {rst_ff[0], 1'b1};
    wire rst_n = rst_ff[1];

    reg [25:0] hb_cnt = 26'd0;
    always @(posedge clk50) hb_cnt <= hb_cnt + 26'd1;

    // ------------------------------------------------------------------
    // ROM -> maestro JTAG
    // ------------------------------------------------------------------
    wire [ROM_AW-1:0] rom_addr;
    wire [31:0]       rom_q;

    bitstream_rom #(
        .WIDTH(32), .DEPTH(ROM_DEPTH), .INIT_FILE(INIT_FILE)
    ) u_rom (
        .clk(sys_clk), .addr(rom_addr), .q(rom_q)
    );

    wire tck, tms, tdi, tdo_unused, cfg_busy, loading, done;

    jtag_bitstream_loader #(
        .ROWS(ROWS), .COLS(COLS), .MAX_FRAMES_PER_COL(MAX_FRAMES_PER_COL),
        .N_FRAMES(N_FRAMES), .HALF(TCK_HALF)
    ) u_loader (
        .clk(sys_clk), .rst_n(rst_n), .start(SW[0]), .cfg_busy(cfg_busy),
        .rom_addr(rom_addr), .rom_q(rom_q),
        .tck(tck), .tms(tms), .tdi(tdi), .busy(loading), .done(done)
    );

    // ------------------------------------------------------------------
    // JTAG de configuracion + eFPGA (el chip_top generado por gen_glue.py)
    // ------------------------------------------------------------------
    wire [NIO-1:0] pad_in, pad_out, pad_oe;

    chip_top #(
        .ROWS(ROWS), .COLS(COLS),
        .FRAME_BITS_PER_ROW(FRAME_BITS_PER_ROW), .MAX_FRAMES_PER_COL(MAX_FRAMES_PER_COL)
    ) u_chip (
        .tck(tck), .tms(tms), .tdi(tdi), .trst_n(rst_n), .tdo(tdo_unused),
        .clk(sys_clk), .rst_n(rst_n),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe),
        .cfg_busy(cfg_busy)
    );

    // ------------------------------------------------------------------
    // Pines del benchmark: io[b] = pad[PAD_BASE + b]  <->  GPIO_1[b]
    // pad_oe = 1 -> el fabric maneja el pin. Hasta que done = 1 el fabric no tiene una
    // configuracion valida, asi que ningun pin se maneja antes de eso.
    // Las entradas se sincronizan al reloj del sistema (2 FF).
    // ------------------------------------------------------------------
    reg [BM_IO-1:0] gp_s1 = {BM_IO{1'b0}}, gp_s2 = {BM_IO{1'b0}};
    always @(posedge sys_clk) begin
        gp_s1 <= GPIO_1[BM_IO-1:0];
        gp_s2 <= gp_s1;
    end
    wire [NIO-1:0] ext_in = gp_s2;                    // se extiende con ceros
    assign pad_in = ext_in << PAD_BASE;

    wire [BM_IO-1:0] fab_out = pad_out[PAD_BASE +: BM_IO];
    wire [BM_IO-1:0] fab_oe  = pad_oe [PAD_BASE +: BM_IO] & {BM_IO{done}};

    genvar g;
    generate
        for (g = 0; g < BM_IO; g = g + 1) begin : g_gpio1
            assign GPIO_1[g] = fab_oe[g] ? fab_out[g] : 1'bz;
        end
    endgenerate
    assign GPIO_1[35:BM_IO] = {(36-BM_IO){1'bz}};

    // ------------------------------------------------------------------
    // Indicadores y depuracion
    // ------------------------------------------------------------------
    assign LED[0]   = loading;
    assign LED[1]   = done;
    assign LED[2]   = hb_cnt[25];
    assign LED[3]   = ~rst_n;
    assign LED[7:4] = fab_out[LED_BASE +: 4] & fab_oe[LED_BASE +: 4];

    assign GPIO_0[0]    = tck;
    assign GPIO_0[1]    = tms;
    assign GPIO_0[2]    = tdi;
    assign GPIO_0[3]    = loading;
    assign GPIO_0[4]    = done;
    assign GPIO_0[5]    = cfg_busy;
    assign GPIO_0[6]    = sys_clk;
    assign GPIO_0[35:7] = {29{1'bz}};
endmodule
`resetall
