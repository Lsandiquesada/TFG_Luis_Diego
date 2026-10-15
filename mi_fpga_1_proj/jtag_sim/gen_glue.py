#!/usr/bin/env python3
"""
Genera:
  chip_top.v          -> JTAG + eFPGA (conexion de los 28 IO del fabric)
  eFPGA_mock.v        -> modelo de reemplazo del fabric (solo para simular sin el eFPGA real)
  mock_bitstream.hex  -> bitstream falso (200 frames) con el formato que espera el TB

Si los nombres de puerto de tu eFPGA.v generado por FABulous son distintos,
cambia NAME_FMT y vuelve a ejecutar.
"""
import random

# ---- Ajustar a tu fabric.csv ------------------------------------------------
ROWS, COLS = 16, 10
BITS_PER_ROW, FRAMES_PER_COL = 32, 20
IO_Y_RANGE = range(1, 15)                 # X0Y1 .. X0Y14
NAME_FMT = "Tile_X0Y{y}_{ab}_{sig}_top"   # sig = I | T | O
# -----------------------------------------------------------------------------

FRAME_W = BITS_PER_ROW * ROWS
N_STROBE = FRAMES_PER_COL * COLS
ADDR_W = (N_STROBE - 1).bit_length()
N_IO = 2 * len(IO_Y_RANGE)


def io_list():
    """(indice de pad, y, A/B). Mismo orden que top_wrapper.v: io27 = X0Y1.A ... io0 = X0Y14.B"""
    out = []
    for k, y in enumerate(IO_Y_RANGE):
        for j, ab in enumerate("AB"):
            out.append((N_IO - 1 - (2 * k + j), y, ab))
    return out


def nm(y, ab, sig):
    return NAME_FMT.format(y=y, ab=ab, sig=sig)


def gen_chip_top(conn=None, n_io=None, rows=None, cols=None, bits=None, frames=None):
    global N_IO, ROWS, COLS, BITS_PER_ROW, FRAMES_PER_COL
    if n_io:
        N_IO, ROWS, COLS, BITS_PER_ROW, FRAMES_PER_COL = n_io, rows, cols, bits, frames
    if conn is None:
        conn = []
        for idx, y, ab in io_list():
            conn.append(f"        .{nm(y, ab, 'I')} (fab_i[{idx}]),")
            conn.append(f"        .{nm(y, ab, 'T')} (fab_t[{idx}]),")
            conn.append(f"        .{nm(y, ab, 'O')} (pad_in[{idx}]),")
    conn_txt = "\n".join(conn).rstrip(",")
    return f"""`default_nettype none

// -----------------------------------------------------------------------------
// chip_top: configuracion JTAG + eFPGA (FABulous)
//   - jtag_fabric_config genera FrameData / FrameStrobe
//   - eFPGA es el fabric generado (o eFPGA_mock.v para simular sin fabric)
//   - Los {N_IO} IO del fabric salen como pad_in / pad_out / pad_oe
// Generado por gen_glue.py
// -----------------------------------------------------------------------------
module chip_top #(
    parameter ROWS               = {ROWS},
    parameter COLS               = {COLS},
    parameter FRAME_BITS_PER_ROW = {BITS_PER_ROW},
    parameter MAX_FRAMES_PER_COL = {FRAMES_PER_COL}
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
    input  wire [{N_IO-1}:0]  pad_in,       // pad -> fabric
    output wire [{N_IO-1}:0]  pad_out,      // fabric -> pad
    output wire [{N_IO-1}:0]  pad_oe,       // 1 = el fabric maneja el pad

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
    wire [{N_IO-1}:0] fab_i, fab_t;
    assign pad_out = fab_i;
    assign pad_oe  = fab_t;     // T_top = ~T en la celda IO -> ya es habilitacion de salida

    eFPGA fabric_i (
        .UserCLK     (clk),
        .FrameData   (FrameData),
        .FrameStrobe (FrameStrobe),
{conn_txt}
    );

endmodule
`resetall
"""


def gen_mock():
    ports = []
    pin_o, drv = [], []
    for idx, y, ab in io_list():
        ports.append(f"    output wire {nm(y, ab, 'I')}")
        ports.append(f"    output wire {nm(y, ab, 'T')}")
        ports.append(f"    input  wire {nm(y, ab, 'O')}")
        pin_o.append(f"    assign io_in[{idx}] = configured ? {nm(y, ab, 'O')} : 1'b0;")
        drv.append(f"    assign {nm(y, ab, 'I')} = configured ? io_out[{idx}] : 1'b0;")
        drv.append(f"    assign {nm(y, ab, 'T')} = configured ? ~io_oeb[{idx}] : 1'b0;")
    return f"""`default_nettype none

// -----------------------------------------------------------------------------
// eFPGA_mock: SUSTITUTO de comportamiento del fabric, solo para validar
// chip_top + JTAG + testbench sin tener el eFPGA real de FABulous.
//   - Guarda cada frame recibido en cfg_mem[strobe]
//   - Cuando se han escrito TODOS los strobes (configured = 1) conecta
//     fir_filter_top a los IO; antes de eso los IO quedan en alta impedancia.
// No modela el fabric real. Para la simulacion real, sustituye este archivo
// por los .v que genera FABulous (mismo nombre de modulo: eFPGA).
// -----------------------------------------------------------------------------
module eFPGA (
    input  wire UserCLK,
    input  wire [{FRAME_W-1}:0] FrameData,
    input  wire [{N_STROBE-1}:0] FrameStrobe,
{(","+chr(10)).join(ports)}
);
    localparam FRAME_W  = {FRAME_W};
    localparam N_STROBE = {N_STROBE};

    reg [FRAME_W-1:0]  cfg_mem [0:N_STROBE-1];
    reg [N_STROBE-1:0] written;
    integer i;

    initial begin
        written = {{N_STROBE{{1'b0}}}};
        for (i = 0; i < N_STROBE; i = i + 1) cfg_mem[i] = {{FRAME_W{{1'b0}}}};
    end

    always @(posedge UserCLK)
        for (i = 0; i < N_STROBE; i = i + 1)
            if (FrameStrobe[i]) begin
                cfg_mem[i] <= FrameData;
                written[i] <= 1'b1;
            end

    wire configured = &written;

    wire [{N_IO-1}:0] io_in, io_out, io_oeb;
{chr(10).join(pin_o)}
{chr(10).join(drv)}

    fir_filter_top user_i (
        .clk    (UserCLK),
        .io_in  (io_in),
        .io_out (io_out),
        .io_oeb (io_oeb)
    );

endmodule
`resetall
"""


def gen_bitstream(path="mock_bitstream.hex", seed=1):
    """Una linea por frame: [addr (ADDR_W bits)][FrameData (FRAME_W bits)] en hex.
       ancho total = FRAME_W + ADDR_W = 520 bits = 130 digitos hex."""
    rnd = random.Random(seed)
    nhex = (FRAME_W + ADDR_W) // 4
    with open(path, "w") as f:
        for addr in range(N_STROBE):
            data = rnd.getrandbits(FRAME_W)
            f.write(f"{(addr << FRAME_W) | data:0{nhex}x}\n")


def gen_from_efpga(path):
    """Lee la cabecera del modulo eFPGA generado por FABulous y arma chip_top.v:
       - pines Tile_X0Y*_{A|B}_{I|T|O}_top -> pad_in / pad_out / pad_oe
       - UserCLK / FrameData / FrameStrobe -> JTAG
       - cualquier otra entrada (RAM2FAB_*, ...) -> 1'b0 ; otra salida -> sin conectar"""
    import re
    txt = open(path).read()
    head = txt[txt.index("module eFPGA"):]
    head = head[:head.index(");")]
    defaults = dict(re.findall(r"parameter\s+(\w+)\s*=\s*(\d+)", head))
    bits, frames = int(defaults["FrameBitsPerRow"]), int(defaults["MaxFramesPerCol"])
    rows = int(re.search(r"FrameBitsPerRow\*(\d+)\)-1:0\]\s*FrameData", head).group(1))
    cols = int(re.search(r"MaxFramesPerCol\*(\d+)\)-1:0\]\s*FrameStrobe", head).group(1))
    ports = re.findall(r"^\s*(input|output)\s+(?:\[[^\]]*\]\s*)?(\w+)\s*,?", head, re.M)
    pin_re = re.compile(r"^Tile_X0Y(\d+)_([AB])_([ITO])_top$")
    pins = sorted({(int(m.group(1)), m.group(2)) for _, n in ports if (m := pin_re.match(n))})
    n_io = len(pins)
    idx = {p: n_io - 1 - k for k, p in enumerate(pins)}
    conn, tied, open_ = [], 0, 0
    for d, n in ports:
        m = pin_re.match(n)
        if n in ("UserCLK", "FrameData", "FrameStrobe"):
            continue          # ya los conecta la plantilla de chip_top
        elif m:
            i = idx[(int(m.group(1)), m.group(2))]
            tgt = {"I": f"fab_i[{i}]", "T": f"fab_t[{i}]", "O": f"pad_in[{i}]"}[m.group(3)]
            conn.append(f"        .{n} ({tgt}),")
        elif d == "input":        conn.append(f"        .{n} (1'b0),"); tied += 1
        else:                     conn.append(f"        .{n} (),");     open_ += 1
    print(f"eFPGA: {n_io} IO, ROWS={rows} COLS={cols} bits/row={bits} frames/col={frames}; "
          f"{tied} entradas a 0, {open_} salidas sin conectar")
    open("chip_top.v", "w").write(
        gen_chip_top(conn, n_io, rows, cols, bits, frames))


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:          # modo real: python3 gen_glue.py <ruta>/Fabric/eFPGA.v
        gen_from_efpga(sys.argv[1])
        sys.exit(0)
    assert (FRAME_W + ADDR_W) % 4 == 0, "ancho del DR no multiplo de 4: ajustar formato hex"
    open("chip_top.v", "w").write(gen_chip_top())
    open("eFPGA_mock.v", "w").write(gen_mock())
    gen_bitstream()
    print(f"FRAME_W={FRAME_W} N_STROBE={N_STROBE} ADDR_W={ADDR_W} DR_W={FRAME_W+ADDR_W}")
