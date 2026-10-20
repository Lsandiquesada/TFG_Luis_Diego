module jtag_fabric_config #(
    // Parametros del fabric (ajustar a tu fabric.csv / eFPGA generado)
    parameter FRAME_BITS_PER_ROW  = 32,
    parameter ROWS                = 16,
    parameter COLS                = 10,
    parameter MAX_FRAMES_PER_COL  = 20,
    // Derivados (no sobreescribir)
    parameter FRAME_W             = FRAME_BITS_PER_ROW * ROWS,
    parameter N_STROBE            = MAX_FRAMES_PER_COL * COLS,
    parameter ADDR_W              = (N_STROBE > 1) ? $clog2(N_STROBE) : 1,
    // Otros
    parameter [31:0] IDCODE_VALUE = 32'h1FAB0001,
    parameter STROBE_CYCLES       = 2
) (
    // Puerto JTAG
    input  wire                 tck,
    input  wire                 tms,
    input  wire                 tdi,
    input  wire                 trst_n,
    output reg                  tdo,
    output wire                 tdo_oe,

    // Lado fabric
    input  wire                 clk,
    input  wire                 rst_n,
    output reg  [FRAME_W-1:0]   FrameData,
    output reg  [N_STROBE-1:0]  FrameStrobe,
    output wire                 cfg_busy
);

    localparam [3:0] IR_IDCODE    = 4'b0001;
    localparam [3:0] IR_CFG_FRAME = 4'b0010;
    localparam [3:0] IR_BYPASS    = 4'b1111;

    localparam DR_CFG_W = FRAME_W + ADDR_W;

    // ------------------------------------------------------------------
    // Maquina de estados del TAP
    // ------------------------------------------------------------------
    localparam [3:0]
        S_TLR  = 4'hF, S_RTI  = 4'hC,
        S_SDRS = 4'h7, S_CDR  = 4'h6, S_SDR  = 4'h2,
        S_E1DR = 4'h1, S_PDR  = 4'h3, S_E2DR = 4'h0, S_UDR = 4'h5,
        S_SIRS = 4'h4, S_CIR  = 4'hE, S_SIR  = 4'hA,
        S_E1IR = 4'h9, S_PIR  = 4'hB, S_E2IR = 4'h8, S_UIR = 4'hD;

    reg [3:0] state;

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) state <= S_TLR;
        else case (state)
            S_TLR : state <= tms ? S_TLR  : S_RTI;
            S_RTI : state <= tms ? S_SDRS : S_RTI;
            S_SDRS: state <= tms ? S_SIRS : S_CDR;
            S_CDR : state <= tms ? S_E1DR : S_SDR;
            S_SDR : state <= tms ? S_E1DR : S_SDR;
            S_E1DR: state <= tms ? S_UDR  : S_PDR;
            S_PDR : state <= tms ? S_E2DR : S_PDR;
            S_E2DR: state <= tms ? S_UDR  : S_SDR;
            S_UDR : state <= tms ? S_SDRS : S_RTI;
            S_SIRS: state <= tms ? S_TLR  : S_CIR;
            S_CIR : state <= tms ? S_E1IR : S_SIR;
            S_SIR : state <= tms ? S_E1IR : S_SIR;
            S_E1IR: state <= tms ? S_UIR  : S_PIR;
            S_PIR : state <= tms ? S_E2IR : S_PIR;
            S_E2IR: state <= tms ? S_UIR  : S_SIR;
            S_UIR : state <= tms ? S_SDRS : S_RTI;
            default: state <= S_TLR;
        endcase
    end

    // ------------------------------------------------------------------
    // Registro de instruccion
    // ------------------------------------------------------------------
    reg [3:0] ir_sr;   // desplazamiento
    reg [3:0] ir;      // instruccion activa

    always @(posedge tck) begin
        case (state)
            S_CIR: ir_sr <= 4'b0101;                  // patron fijo xx01
            S_SIR: ir_sr <= {tdi, ir_sr[3:1]};
            default: ;
        endcase
    end

    always @(negedge tck or negedge trst_n) begin
        if (!trst_n)             ir <= IR_IDCODE;
        else if (state == S_TLR) ir <= IR_IDCODE;
        else if (state == S_UIR) ir <= ir_sr;
    end

    // ------------------------------------------------------------------
    // Registros de datos
    // ------------------------------------------------------------------
    reg [31:0]         id_sr;
    reg                byp_sr;
    reg [DR_CFG_W-1:0] cfg_sr;

    always @(posedge tck) begin
        case (state)
            S_CDR: begin
                id_sr  <= IDCODE_VALUE;
                byp_sr <= 1'b0;
                cfg_sr <= {DR_CFG_W{1'b0}};
            end
            S_SDR: begin
                id_sr  <= {tdi, id_sr[31:1]};
                byp_sr <= tdi;
                cfg_sr <= {tdi, cfg_sr[DR_CFG_W-1:1]};
            end
            default: ;
        endcase
    end

    // TDO cambia en flanco de bajada
    always @(negedge tck) begin
        case (state)
            S_SIR:   tdo <= ir_sr[0];
            S_SDR:   case (ir)
                         IR_IDCODE   : tdo <= id_sr[0];
                         IR_CFG_FRAME: tdo <= cfg_sr[0];
                         default     : tdo <= byp_sr;
                     endcase
            default: tdo <= 1'b0;
        endcase
    end

    assign tdo_oe = (state == S_SDR) || (state == S_SIR);

    // ------------------------------------------------------------------
    // Update-DR: guardar frame y avisar al dominio clk (toggle)
    // ------------------------------------------------------------------
    reg [DR_CFG_W-1:0] cfg_hold;
    reg                upd_toggle;

    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            cfg_hold   <= {DR_CFG_W{1'b0}};
            upd_toggle <= 1'b0;
        end else if (state == S_UDR && ir == IR_CFG_FRAME) begin
            cfg_hold   <= cfg_sr;
            upd_toggle <= ~upd_toggle;
        end
    end

    // ------------------------------------------------------------------
    // Dominio clk: sincronizacion y generacion de FrameData / FrameStrobe
    // ------------------------------------------------------------------
    reg [2:0] sync;
    wire      upd_pulse = sync[2] ^ sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync <= 3'b000;
        else        sync <= {sync[1:0], upd_toggle};
    end

    localparam [1:0] C_IDLE = 2'd0, C_SETUP = 2'd1, C_STROBE = 2'd2;
    reg [1:0]        cst;
    reg [ADDR_W-1:0] addr_q;
    reg [7:0]        cnt;

    assign cfg_busy = (cst != C_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst         <= C_IDLE;
            FrameData   <= {FRAME_W{1'b0}};
            FrameStrobe <= {N_STROBE{1'b0}};
            addr_q      <= {ADDR_W{1'b0}};
            cnt         <= 8'd0;
        end else begin
            case (cst)
                C_IDLE: begin
                    FrameStrobe <= {N_STROBE{1'b0}};
                    if (upd_pulse) begin
                        FrameData <= cfg_hold[FRAME_W-1:0];
                        addr_q    <= cfg_hold[DR_CFG_W-1:FRAME_W];
                        cst       <= C_SETUP;
                    end
                end
                C_SETUP: begin   // un ciclo para que FrameData se asiente
                    if (addr_q < N_STROBE) begin
                        FrameStrobe <= {{(N_STROBE-1){1'b0}}, 1'b1} << addr_q;
                        cnt         <= STROBE_CYCLES - 1;
                        cst         <= C_STROBE;
                    end else begin
                        cst <= C_IDLE;   // direccion fuera de rango: se ignora
                    end
                end
                C_STROBE: begin
                    if (cnt == 8'd0) begin
                        FrameStrobe <= {N_STROBE{1'b0}};
                        cst         <= C_IDLE;
                    end else begin
                        cnt <= cnt - 8'd1;
                    end
                end
                default: cst <= C_IDLE;
            endcase
        end
    end

endmodule
