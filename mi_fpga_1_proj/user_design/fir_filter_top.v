module fir_filter_top (
    input  wire        clk,
    input  wire [27:0] io_in,
    output wire [27:0] io_out,
    output wire [27:0] io_oeb
);
    wire signed [7:0] x     = io_in[7:0];
    wire              valid = io_in[8];
    wire              rst   = io_in[9];

    reg signed [7:0] d1, d2, d3;   // x[n-1], x[n-2], x[n-3]
    reg signed [7:0] y;
    reg              yv;

    wire signed [10:0] xe = x;
    wire signed [10:0] e1 = d1;
    wire signed [10:0] e2 = d2;
    wire signed [10:0] e3 = d3;
    wire signed [10:0] sum = xe + e1 + (e1 <<< 1) + e2 + (e2 <<< 1) + e3;

    always @(posedge clk) begin
        yv <= 1'b0;
        if (rst) begin
            d1 <= 8'sd0;
            d2 <= 8'sd0;
            d3 <= 8'sd0;
            y  <= 8'sd0;
        end else if (valid) begin
            d3 <= d2;
            d2 <= d1;
            d1 <= x;
            y  <= sum[10:3];       // desplazamiento aritmetico >>> 3
            yv <= 1'b1;
        end
    end

    assign io_out = {9'b0, yv, y, 10'b0};
    //                28'b: [27:19]=0, [18]=yv, [17:10]=y, [9:0]=0
    assign io_oeb = {9'b111111111, 9'b000000000, 10'b1111111111};
endmodule
`resetall
