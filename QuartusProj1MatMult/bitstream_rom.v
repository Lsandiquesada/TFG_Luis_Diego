`default_nettype none
// -----------------------------------------------------------------------------
// bitstream_rom: ROM sincrona de palabras de 32 bits con el bitstream de configuracion.
//
// Contenido (lo genera jtag_hex2rom.py): por cada frame se guardan ROWS+1 palabras
// consecutivas:
//   palabras 0..ROWS-1 : FrameData de la fila r (bit 0 = primer bit que se envia por JTAG)
//   palabra  ROWS      : indice de strobe (direccion del frame), en los bits bajos
// Una palabra hexadecimal por linea en INIT_FILE.
// -----------------------------------------------------------------------------
module bitstream_rom #(
    parameter WIDTH     = 32,
    parameter DEPTH     = 3400,
    parameter INIT_FILE = "bitstream_rom.hex",
    parameter AW        = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  wire             clk,
    input  wire [AW-1:0]    addr,
    output reg  [WIDTH-1:0] q
);
    (* romstyle = "M10K" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    initial $readmemh(INIT_FILE, mem);

    always @(posedge clk)
        q <= mem[addr];
endmodule
`resetall
