`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench: chip_top (JTAG + eFPGA) con un filtro FIR cargado por JTAG.
//
// Flujo:
//   1. Reset del TAP y lectura de IDCODE (debe ser 32'h1FAB0001)
//   2. IR = CFG_FRAME y envio de cada frame (linea de BITSTREAM) como un DR de
//      FRAME_W + ADDR_W bits: {addr, FrameData}, LSB primero
//   3. Espera a que cfg_busy baje
//   4. (solo -DMOCK_FABRIC) compara cfg_mem del modelo con lo enviado
//   5. Estimulo del filtro por los pads y scoreboard contra el modelo de referencia
//
// Ejecutar (ejemplo con Icarus Verilog):
//   iverilog -g2012 -DMOCK_FABRIC -o sim tb_chip_top_fir.v chip_top.v \
//            jtag_fabric_config.v eFPGA_mock.v fir_filter_top.v
//   vvp sim +BITSTREAM=mock_bitstream.hex [+VCD]
// Diagnostico del fabric real: anadir -DDEBUG_CFG (imprime ConfigBits de las celdas IO)
// Con el fabric real: quitar -DMOCK_FABRIC, sustituir eFPGA_mock.v por los
// .v generados por FABulous y pasar +BITSTREAM=<tu_bitstream>.hex
// -----------------------------------------------------------------------------
module tb_chip_top_fir;

    // ---- Parametros del fabric (iguales a fabric.csv / gen_glue.py) ----------
    localparam ROWS           = 16;
    localparam COLS           = 10;
    localparam BITS_PER_ROW   = 32;
    localparam FRAMES_PER_COL = 20;
    localparam FRAME_W   = BITS_PER_ROW * ROWS;        // 512
    localparam N_STROBE  = FRAMES_PER_COL * COLS;      // 200
    localparam ADDR_W    = $clog2(N_STROBE);           // 8
    localparam DR_W      = FRAME_W + ADDR_W;           // 520
    localparam MAX_FRAMES = 1024;

    localparam CLK_HALF = 10;   // clk = 50 MHz
    localparam TCK_HALF = 50;   // tck = 10 MHz (mucho mas lento que clk)

    localparam [3:0] IR_IDCODE = 4'b0001, IR_CFG_FRAME = 4'b0010, IR_BYPASS = 4'b1111;

    // Pines del filtro (ver fir_filter_top.v)
    localparam VALID_BIT = 8, RST_BIT = 9, YV_BIT = 18;

    // ---- DUT -----------------------------------------------------------------
    reg         tck = 1'b0, tms = 1'b1, tdi = 1'b0, trst_n = 1'b1;
    wire        tdo;
    reg         clk = 1'b0, rst_n = 1'b1;
    reg  [27:0] pad_in = 28'd0;
    wire [27:0] pad_out, pad_oe;
    wire        cfg_busy;

    chip_top #(
        .ROWS(ROWS), .COLS(COLS),
        .FRAME_BITS_PER_ROW(BITS_PER_ROW), .MAX_FRAMES_PER_COL(FRAMES_PER_COL)
    ) dut (
        .tck(tck), .tms(tms), .tdi(tdi), .trst_n(trst_n), .tdo(tdo),
        .clk(clk), .rst_n(rst_n),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe),
        .cfg_busy(cfg_busy)
    );

    always #(CLK_HALF) clk = ~clk;

    // ---- Driver JTAG ---------------------------------------------------------
    reg              tdo_cap;
    reg [DR_W-1:0]   dr_rd;

    // Un ciclo de TCK: TMS/TDI estables antes del flanco de subida, TDO se muestrea
    // justo antes de ese flanco (el TAP lo cambia en el flanco de bajada).
    task tck_cycle(input t, input d);
        begin
            tms = t;
            tdi = d;
            #(TCK_HALF);
            tdo_cap = tdo;
            tck = 1'b1;
            #(TCK_HALF);
            tck = 1'b0;
        end
    endtask

    // 5 x TMS=1 -> Test-Logic-Reset, luego TMS=0 -> Run-Test/Idle
    task jtag_reset;
        integer k;
        begin
            for (k = 0; k < 5; k = k + 1) tck_cycle(1'b1, 1'b0);
            tck_cycle(1'b0, 1'b0);
        end
    endtask

    // Desde RTI: Select-DR, Select-IR, Capture-IR, Shift-IR, 4 bits, Exit1, Update, RTI
    task jtag_ir(input [3:0] ir);
        integer k;
        begin
            tck_cycle(1'b1, 1'b0);
            tck_cycle(1'b1, 1'b0);
            tck_cycle(1'b0, 1'b0);
            tck_cycle(1'b0, 1'b0);
            for (k = 0; k < 4; k = k + 1) tck_cycle(k == 3, ir[k]);
            tck_cycle(1'b1, 1'b0);
            tck_cycle(1'b0, 1'b0);
        end
    endtask

    // Desde RTI: Select-DR, Capture-DR, Shift-DR, nbits, Exit1, Update, RTI
    // Deja en dr_rd los bits leidos por TDO
    task jtag_dr(input integer nbits, input [DR_W-1:0] wdata);
        integer k;
        begin
            dr_rd = {DR_W{1'b0}};
            tck_cycle(1'b1, 1'b0);
            tck_cycle(1'b0, 1'b0);
            tck_cycle(1'b0, 1'b0);
            for (k = 0; k < nbits; k = k + 1) begin
                tck_cycle(k == nbits - 1, wdata[k]);
                dr_rd[k] = tdo_cap;
            end
            tck_cycle(1'b1, 1'b0);
            tck_cycle(1'b0, 1'b0);
        end
    endtask

    // ---- Modelo de referencia del filtro y scoreboard ------------------------
    integer m_d1, m_d2, m_d3;
    integer exp_q [0:8191];
    integer wr_ptr, rd_ptr, errors, checked;
    reg signed [7:0] exp8, y_obs;

    // Envia una muestra (valid=1 un ciclo) y deja 'gap' ciclos con valid=0.
    // Debe llamarse alineado a un flanco de bajada de clk.
    task send_sample(input integer xv, input integer gap);
        integer sum;
        begin
            pad_in[7:0]       = xv[7:0];
            pad_in[VALID_BIT] = 1'b1;
            sum = xv + 3*m_d1 + 3*m_d2 + m_d3;
            exp_q[wr_ptr] = sum >>> 3;          // desplazamiento aritmetico
            wr_ptr = wr_ptr + 1;
            m_d3 = m_d2;  m_d2 = m_d1;  m_d1 = xv;
            @(negedge clk);
            if (gap > 0) begin
                pad_in[VALID_BIT] = 1'b0;
                repeat (gap) @(negedge clk);
            end
        end
    endtask

    // Reset sincrono del filtro (pin 9); limpia tambien el modelo
    task filter_reset;
        begin
            pad_in[VALID_BIT] = 1'b0;
            repeat (4) @(negedge clk);          // dejar drenar salidas en vuelo
            pad_in[RST_BIT] = 1'b1;
            repeat (3) @(negedge clk);
            pad_in[RST_BIT] = 1'b0;
            m_d1 = 0; m_d2 = 0; m_d3 = 0;
            @(negedge clk);
        end
    endtask

    // Monitor: cada vez que y_valid = 1 se compara con la siguiente salida esperada
    always @(negedge clk) begin
        if (pad_oe[YV_BIT] === 1'b1 && pad_out[YV_BIT] === 1'b1) begin
            y_obs = pad_out[17:10];
            if (rd_ptr >= wr_ptr) begin
                errors = errors + 1;
                $display("[%0t] ERROR: y_valid sin muestra pendiente (y=%0d)", $time, y_obs);
            end else begin
                exp8 = exp_q[rd_ptr];
                if (y_obs !== exp8) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR muestra %0d: y=%0d esperado=%0d", $time, rd_ptr, y_obs, exp8);
                end
                rd_ptr  = rd_ptr + 1;
                checked = checked + 1;
            end
        end
    end

    // ---- Programa principal --------------------------------------------------
    reg [DR_W-1:0] frames [0:MAX_FRAMES-1];
    reg [DR_W-1:0] tmp;
    reg [8*256-1:0] bs_file;
    integer i, nframes, seed, xv, k, g;
    reg done;

    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("tb_chip_top_fir.vcd");
            $dumpvars(0, tb_chip_top_fir);
        end
    end

    // Watchdog
    initial begin
        #400_000_000;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        errors = 0; checked = 0; wr_ptr = 0; rd_ptr = 0;
        m_d1 = 0; m_d2 = 0; m_d3 = 0;
        seed = 32'h1234_5678;

        if (!$value$plusargs("BITSTREAM=%s", bs_file)) bs_file = "mock_bitstream.hex";
        $readmemh(bs_file, frames);

        // Reset general: flanco de bajada REAL de trst_n / rst_n (los resets asincronos
        // del JTAG, p.ej. upd_toggle, solo se inicializan con ese flanco)
        #1;
        trst_n = 1'b0;
        rst_n  = 1'b0;
        #(5*CLK_HALF);
        trst_n = 1'b1;
        rst_n  = 1'b1;
        repeat (4) @(posedge clk);

        // 1) TAP e IDCODE (tras reset el IR es IDCODE)
        jtag_reset;
        jtag_dr(32, {DR_W{1'b0}});
        if (dr_rd[31:0] !== 32'h1FAB0001) begin
            errors = errors + 1;
            $display("ERROR: IDCODE = %h (esperado 1FAB0001)", dr_rd[31:0]);
        end else
            $display("IDCODE OK: %h", dr_rd[31:0]);

        // 2) Programar el fabric: cada linea del archivo = un frame
        jtag_ir(IR_CFG_FRAME);
        nframes = 0;
        done    = 1'b0;
        for (i = 0; i < MAX_FRAMES && !done; i = i + 1) begin
            tmp = frames[i];
            if ((^tmp) === 1'bx) done = 1'b1;
            else begin
                jtag_dr(DR_W, tmp);
                nframes = nframes + 1;
            end
        end
        jtag_ir(IR_BYPASS);
        $display("Frames enviados por JTAG: %0d  (t=%0t)", nframes, $time);

        // 3) Esperar fin de configuracion
        repeat (20) @(posedge clk);
        while (cfg_busy) @(posedge clk);
        repeat (5) @(posedge clk);

`ifdef MOCK_FABRIC
        // 4) Verificar que cada frame llego a la direccion correcta
        if (dut.fabric_i.configured !== 1'b1) begin
            errors = errors + 1;
            $display("ERROR: el fabric no quedo configurado (faltan frames)");
        end
        for (i = 0; i < nframes; i = i + 1) begin
            tmp = frames[i];
            if (dut.fabric_i.cfg_mem[tmp[DR_W-1:FRAME_W]] !== tmp[FRAME_W-1:0]) begin
                errors = errors + 1;
                $display("ERROR: frame %0d (addr %0d) no coincide en el fabric", i, tmp[DR_W-1:FRAME_W]);
            end
        end
        $display("Verificacion de frames en el modelo: terminada");
`endif

`ifdef DEBUG_CFG
        // Diagnostico: ConfigBits de las celdas IO tras programar (x = bit nunca escrito)
        $display("--- DEBUG_CFG: ConfigBits de las celdas IO (114 bits) ---");
        $display("Y1  %b", dut.fabric_i.Tile_X0Y1_W_IO.ConfigBits);
        $display("Y2  %b", dut.fabric_i.Tile_X0Y2_W_IO.ConfigBits);
        $display("Y3  %b", dut.fabric_i.Tile_X0Y3_W_IO.ConfigBits);
        $display("Y4  %b", dut.fabric_i.Tile_X0Y4_W_IO.ConfigBits);
        $display("Y5  %b", dut.fabric_i.Tile_X0Y5_W_IO.ConfigBits);
        $display("Y6  %b", dut.fabric_i.Tile_X0Y6_W_IO.ConfigBits);
        $display("Y7  %b", dut.fabric_i.Tile_X0Y7_W_IO.ConfigBits);
        $display("Y8  %b", dut.fabric_i.Tile_X0Y8_W_IO.ConfigBits);
        $display("Y9  %b", dut.fabric_i.Tile_X0Y9_W_IO.ConfigBits);
        $display("Y10 %b", dut.fabric_i.Tile_X0Y10_W_IO.ConfigBits);
        $display("Y11 %b", dut.fabric_i.Tile_X0Y11_W_IO.ConfigBits);
        $display("Y12 %b", dut.fabric_i.Tile_X0Y12_W_IO.ConfigBits);
        $display("Y13 %b", dut.fabric_i.Tile_X0Y13_W_IO.ConfigBits);
        $display("Y14 %b", dut.fabric_i.Tile_X0Y14_W_IO.ConfigBits);
        $display("Strobe X0Y1: %b", dut.fabric_i.Tile_X0Y1_W_IO.FrameStrobe);
        $display("FrameData X0Y1: %h", dut.fabric_i.Tile_X0Y1_W_IO.FrameData);
        $display("FrameData (JTAG) = %h", dut.FrameData);
`endif
        // 5) Estimulo del filtro
        if (pad_oe !== 28'h007FC00) begin
            errors = errors + 1;
            $display("ERROR: pad_oe = %h (esperado 007FC00: salidas en pines 18..10)", pad_oe);
        end

        @(negedge clk);
        filter_reset;

        // 5a) Impulso
        send_sample(100, 1);
        for (k = 0; k < 6; k = k + 1) send_sample(0, k % 2);

        // 5b) Escalones +80 / -90
        for (k = 0; k < 10; k = k + 1) send_sample( 80, 1);
        for (k = 0; k < 10; k = k + 1) send_sample(-90, 1);

        // 5c) Senal en frecuencia de Nyquist (+-120), muestras consecutivas
        for (k = 0; k < 16; k = k + 1) send_sample((k % 2) ? -120 : 120, 0);

        // 5d) Rampa
        for (k = 0; k < 32; k = k + 1) send_sample(-128 + 8*k, 2);

        // 5e) Extremos de rango (sin overflow)
        for (k = 0; k < 6; k = k + 1) send_sample( 127, 0);
        for (k = 0; k < 6; k = k + 1) send_sample(-128, 0);
        for (k = 0; k < 6; k = k + 1) send_sample( 127, 0);

        // 5f) Reset a mitad de la prueba: la linea de retardo debe quedar en cero
        filter_reset;
        for (k = 0; k < 4; k = k + 1) send_sample(50, 1);

        // 5g) Aleatorio con huecos aleatorios
        for (k = 0; k < 100; k = k + 1) begin
            xv = $random(seed);
            xv = ((xv & 255) ^ 128) - 128;       // a entero con signo de 8 bits
            g  = $random(seed);
            g  = g & 3;
            send_sample(xv, g);
        end

        // Drenar
        pad_in[VALID_BIT] = 1'b0;
        repeat (10) @(negedge clk);

        if (rd_ptr != wr_ptr) begin
            errors = errors + 1;
            $display("ERROR: se enviaron %0d muestras pero solo %0d salidas validas", wr_ptr, rd_ptr);
        end

        $display("----------------------------------------------------------");
        $display("Muestras enviadas: %0d  comparadas: %0d  errores: %0d", wr_ptr, checked, errors);
        if (errors == 0) $display("RESULTADO: PASS");
        else             $display("RESULTADO: FAIL");
        $display("----------------------------------------------------------");
        $finish;
    end

endmodule
`resetall
