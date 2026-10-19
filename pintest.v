module pintest (
    input  wire        FPGA_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [3:0]  SW,
    output wire [7:0]  LED
);
    reg [25:0] cnt = 26'd0;
    always @(posedge FPGA_CLK1_50) cnt <= cnt + 1'b1;

    assign LED[3:0] = SW;          // cada interruptor enciende su LED
    assign LED[4]   = ~KEY[0];     // se enciende al pulsar KEY[0]
    assign LED[5]   = ~KEY[1];     // se enciende al pulsar KEY[1]
    assign LED[6]   = 1'b0;
    assign LED[7]   = cnt[25];     // parpadea (~0,75 Hz)
endmodule
