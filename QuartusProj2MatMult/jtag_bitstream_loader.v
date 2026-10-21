`default_nettype none
// -----------------------------------------------------------------------------
// jtag_bitstream_loader: maestro JTAG interno.
//
// Lee el bitstream de la ROM (palabras de 32 bits) y genera TCK/TMS/TDI hacia el TAP de
// jtag_fabric_config con EXACTAMENTE la secuencia del testbench de simulacion:
//
//   1. Reset del TAP : TMS = 1,1,1,1,1,0                       -> Run-Test/Idle
//   2. Shift-IR      : TMS = 1,1,0,0 | 4 bits de IR (LSB 1o, ultimo con TMS=1) | 1,0
//                      IR = CFG_FRAME (4'b0010)
//   3. Por cada frame: TMS = 1,0,0 | DR_W bits (LSB 1o, el ultimo con TMS=1) | 1,0
//                      DR = {indice_de_strobe, FrameData}: primero las ROWS palabras de
//                      FrameData (bit 0 de la fila 0 primero) y al final ADDR_W bits del indice
//   4. Shift-IR BYPASS (4'b1111), como el testbench
//   5. Espera a que cfg_busy baje de forma estable y activa `done`
//
// `start` (nivel, asincrono) inicia la carga. `done` queda a 1 hasta que `start` vuelve a 0.
//
// Un TCK dura 2*HALF ciclos de clk (TCK = clk / (2*HALF)). TMS/TDI cambian en el mismo
// ciclo en que TCK baja, asi que quedan estables HALF ciclos antes y despues del flanco de
// subida. HALF >= 3 recomendado; el testbench de simulacion usaba 2.5.
// -----------------------------------------------------------------------------
module jtag_bitstream_loader #(
    parameter ROWS               = 16,    // filas del fabric (FrameData = 32*ROWS bits)
    parameter COLS               = 10,
    parameter MAX_FRAMES_PER_COL = 20,
    parameter N_FRAMES           = 200,   // frames guardados en la ROM
    parameter HALF               = 3,
    // Derivados (no sobreescribir)
    parameter N_STROBE           = MAX_FRAMES_PER_COL * COLS,
    parameter ADDR_W             = (N_STROBE > 1) ? $clog2(N_STROBE) : 1,
    parameter ROM_DEPTH          = N_FRAMES * (ROWS + 1),
    parameter ROM_AW             = (ROM_DEPTH > 1) ? $clog2(ROM_DEPTH) : 1
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire                 cfg_busy,

    output reg  [ROM_AW-1:0]    rom_addr,
    input  wire [31:0]          rom_q,

    output wire                 tck,
    output reg                  tms,
    output reg                  tdi,

    output wire                 busy,
    output wire                 done
);
    localparam [3:0] IR_CFG_FRAME = 4'b0010;
    localparam [3:0] IR_BYPASS    = 4'b1111;

    localparam [3:0] ST_IDLE = 4'd0, ST_RST = 4'd1,
                     ST_IRH  = 4'd2, ST_IRS = 4'd3, ST_IRT = 4'd4,
                     ST_DRH  = 4'd5, ST_DRS = 4'd6, ST_DRT = 4'd7,
                     ST_WAIT = 4'd8, ST_DONE = 4'd9;

    localparam DW       = (HALF > 1) ? $clog2(HALF) : 1;
    localparam WW       = $clog2(ROWS + 1);
    localparam FW       = $clog2(N_FRAMES + 1);
    localparam WAIT_MAX = 6'd63;

    // ---- sincronizacion de start -------------------------------------------
    reg [1:0] start_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) start_s <= 2'b00;
        else        start_s <= {start_s[0], start};
    wire start_q = start_s[1];

    // ---- generador de TCK (solo corre mientras run = 1) ---------------------
    reg          run, tck_r;
    reg [DW-1:0] div;
    wire half_en = (div == HALF - 1);
    wire adv     = run & tck_r & half_en;     // ultimo ciclo de un TCK

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div   <= {DW{1'b0}};
            tck_r <= 1'b0;
        end else if (!run) begin
            div   <= {DW{1'b0}};
            tck_r <= 1'b0;
        end else if (half_en) begin
            div   <= {DW{1'b0}};
            tck_r <= ~tck_r;
        end else begin
            div   <= div + 1'b1;
        end
    end
    assign tck = tck_r;

    // ---- FSM: (st,k) identifica el TCK que se esta emitiendo ----------------
    reg [3:0]    st;
    reg [3:0]    k;
    reg [4:0]    bcnt;            // bit dentro de la palabra
    reg [WW-1:0] wcnt;            // palabra dentro del frame (ROWS = palabra del indice)
    reg [FW-1:0] fcnt;            // frames completados
    reg [30:0]   sh;              // resto de la palabra actual
    reg          ir_final;
    reg [5:0]    wait_cnt;

    wire [3:0] ir_word = ir_final ? IR_BYPASS : IR_CFG_FRAME;

    wire last_in_word = (wcnt == ROWS) ? (bcnt == ADDR_W - 1) : (bcnt == 5'd31);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE;  k <= 4'd0;  bcnt <= 5'd0;  wcnt <= {WW{1'b0}};
            fcnt <= {FW{1'b0}};  sh <= 31'd0;  ir_final <= 1'b0;  wait_cnt <= 6'd0;
            tms <= 1'b0;  tdi <= 1'b0;  run <= 1'b0;  rom_addr <= {ROM_AW{1'b0}};
        end else begin
            case (st)
                ST_IDLE: begin
                    tms <= 1'b0;
                    tdi <= 1'b0;
                    if (start_q) begin
                        st       <= ST_RST;
                        k        <= 4'd0;
                        tms      <= 1'b1;                 // primer TCK del reset: TMS=1
                        fcnt     <= {FW{1'b0}};
                        rom_addr <= {ROM_AW{1'b0}};
                        ir_final <= 1'b0;
                        run      <= 1'b1;
                    end
                end

                // ---- 1) reset del TAP: TMS = 1,1,1,1,1,0
                ST_RST: if (adv) begin
                    if (k < 4'd5) begin
                        k   <= k + 4'd1;
                        tms <= (k < 4'd4);
                    end else begin
                        st  <= ST_IRH;
                        k   <= 4'd0;
                        tms <= 1'b1;
                    end
                end

                // ---- 2) IR: cabecera TMS = 1,1,0,0
                ST_IRH: if (adv) begin
                    if (k < 4'd3) begin
                        k   <= k + 4'd1;
                        tms <= (k < 4'd1);
                    end else begin
                        st  <= ST_IRS;
                        k   <= 4'd0;
                        tms <= 1'b0;
                        tdi <= ir_word[0];
                    end
                end
                // 4 bits de IR, el ultimo con TMS=1
                ST_IRS: if (adv) begin
                    if (k < 4'd3) begin
                        k   <= k + 4'd1;
                        tms <= (k == 4'd2);
                        tdi <= ir_word[k + 4'd1];
                    end else begin
                        st  <= ST_IRT;
                        k   <= 4'd0;
                        tms <= 1'b1;
                        tdi <= 1'b0;
                    end
                end
                // cola: Update-IR y vuelta a Run-Test/Idle (TMS = 1,0)
                ST_IRT: if (adv) begin
                    if (k < 4'd1) begin
                        k   <= 4'd1;
                        tms <= 1'b0;
                    end else if (ir_final) begin
                        st       <= ST_WAIT;
                        run      <= 1'b0;
                        tms      <= 1'b0;
                        wait_cnt <= 6'd0;
                    end else begin
                        st  <= ST_DRH;
                        k   <= 4'd0;
                        tms <= 1'b1;
                    end
                end

                // ---- 3) frame: cabecera DR TMS = 1,0,0
                ST_DRH: if (adv) begin
                    if (k < 4'd2) begin
                        k   <= k + 4'd1;
                        tms <= 1'b0;
                    end else begin
                        // primer bit del frame: palabra 0
                        st       <= ST_DRS;
                        wcnt     <= {WW{1'b0}};
                        bcnt     <= 5'd0;
                        tms      <= 1'b0;
                        tdi      <= rom_q[0];
                        sh       <= rom_q[31:1];
                        rom_addr <= rom_addr + 1'b1;
                    end
                end
                // bits de datos, LSB primero; el ultimo del frame con TMS=1
                ST_DRS: if (adv) begin
                    if (!last_in_word) begin
                        bcnt <= bcnt + 5'd1;
                        tdi  <= sh[0];
                        sh   <= {1'b0, sh[30:1]};
                        tms  <= (wcnt == ROWS) && (bcnt + 5'd1 == ADDR_W - 1);
                    end else if (wcnt == ROWS) begin
                        st  <= ST_DRT;
                        k   <= 4'd0;
                        tms <= 1'b1;
                        tdi <= 1'b0;
                    end else begin
                        wcnt     <= wcnt + 1'b1;
                        bcnt     <= 5'd0;
                        tdi      <= rom_q[0];
                        sh       <= rom_q[31:1];
                        rom_addr <= rom_addr + 1'b1;
                        tms      <= (wcnt + 1'b1 == ROWS) && (ADDR_W == 1);
                    end
                end
                // cola: Update-DR (genera el strobe) y Run-Test/Idle (TMS = 1,0)
                ST_DRT: if (adv) begin
                    if (k < 4'd1) begin
                        k   <= 4'd1;
                        tms <= 1'b0;
                    end else begin
                        fcnt <= fcnt + 1'b1;
                        k    <= 4'd0;
                        tms  <= 1'b1;
                        if (fcnt + 1'b1 == N_FRAMES) begin
                            st       <= ST_IRH;          // ultimo frame: IR = BYPASS
                            ir_final <= 1'b1;
                        end else
                            st <= ST_DRH;
                    end
                end

                // ---- 5) esperar a que el fabric termine de recibir el ultimo frame
                ST_WAIT: begin
                    if (cfg_busy)                 wait_cnt <= 6'd0;
                    else if (wait_cnt == WAIT_MAX) st <= ST_DONE;
                    else                          wait_cnt <= wait_cnt + 6'd1;
                end

                ST_DONE: if (!start_q) st <= ST_IDLE;

                default: st <= ST_IDLE;
            endcase
        end
    end

    assign busy = (st != ST_IDLE) && (st != ST_DONE);
    assign done = (st == ST_DONE);
endmodule
`resetall
