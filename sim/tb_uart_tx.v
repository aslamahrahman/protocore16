/*
 * ProtoCore16 — UART TX RTL smoke test
 * Loads uart_tx program via host IF, pushes 0x55, checks start/data/stop bits.
 */
`timescale 1ns/1ps
`default_nettype none

module tb_uart_tx;
    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk; // 50 MHz

    reg  [7:0] ui_in = 0;
    wire [7:0] uo_out;
    reg  [7:0] uio_in = 8'hFF;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    tt_um_protocore16 dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );

    task automatic host_write(input [5:0] addr, input [7:0] data);
        begin
            @(posedge clk); ui_in <= data;           // stb=0 latch
            @(posedge clk);
            @(posedge clk); ui_in <= {addr, 2'b11};  // we=1 stb=1
            @(posedge clk);
            @(posedge clk); ui_in <= 8'd0;
            @(posedge clk);
        end
    endtask

    task automatic host_read(input [5:0] addr, output [7:0] data);
        begin
            @(posedge clk); ui_in <= {addr, 2'b01}; // we=0 stb=1
            @(posedge clk);
            @(posedge clk); data = uo_out;
            ui_in <= 8'd0;
            @(posedge clk);
        end
    endtask

    task automatic load_prog_word(input [15:0] w);
        begin
            host_write(6'h04, w[7:0]);
            host_write(6'h04, w[15:8]);
        end
    endtask

    // uart_tx.hex words (assembled)
    reg [15:0] prog [0:15];
    integer i, bit_i, errors;
    reg [7:0] tmp;
    reg [7:0] captured;
    reg tx_bit;
    integer half;

    initial begin
        $dumpfile("tb_uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);
        errors = 0;

        // Program from assembler output for uart_tx.pca
        prog[0]  = 16'h5040; // pull block
        prog[1]  = 16'h8000; // set pins,0
        prog[2]  = 16'h3001; // out pins,1
        prog[3]  = 16'h3001;
        prog[4]  = 16'h3001;
        prog[5]  = 16'h3001;
        prog[6]  = 16'h3001;
        prog[7]  = 16'h3001;
        prog[8]  = 16'h3001;
        prog[9]  = 16'h3001;
        prog[10] = 16'h8001; // set pins,1 stop
        prog[11] = 16'h0000; // jmp start

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // SM0 select, load program
        host_write(6'h02, 8'h00); // SMSEL
        host_write(6'h03, 8'h00); // PROG_OFF
        for (i = 0; i < 12; i = i + 1)
            load_prog_word(prog[i]);

        // clkdiv_int = 3 => tick every 4 clocks (fast UART for sim)
        host_write(6'h09, 8'h00);
        host_write(6'h0A, 8'h03);
        // PINCTRL set_base=0 count=1
        host_write(6'h0B, 8'h01);
        // PINCTRL2 out_base=0 in_base=0
        host_write(6'h0C, 8'h00);
        // EXECCTRL autopull + shift_right
        host_write(6'h0D, 8'h30);
        // SHIFTCTRL pull_th=8
        host_write(6'h0F, 8'h88);

        // Idle high
        // enable after push
        host_write(6'h05, 8'h55); // TX FIFO 0x55 = 01010101
        host_write(6'h00, 8'h01); // enable SM0

        // Sample TX pin (uio[0]) once per bit time (4 clocks * instr timing varies)
        // Wait until OE drives and start bit observed
        captured = 8'h00;
        // spin until line goes low (start)
        begin : wait_start
            integer guard;
            guard = 0;
            tx_bit = 1;
            while (tx_bit !== 1'b0 && guard < 5000) begin
                @(posedge clk);
                if (uio_oe[0]) tx_bit = uio_out[0];
                guard = guard + 1;
            end
            if (tx_bit !== 1'b0) begin
                $display("FAIL: start bit not seen");
                errors = errors + 1;
            end else
                $display("OK: start bit low");
        end

        // For each data bit, wait ~1 bit period. Engine: clkdiv=3 => tick every 4 cycles.
        // Each OUT is 1 tick. Sample mid-tick.
        for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
            // advance one bit time: roughly 4 clocks per tick; OUT takes 1 tick
            repeat (4) @(posedge clk);
            tx_bit = uio_oe[0] ? uio_out[0] : 1'b1;
            captured[bit_i] = tx_bit;
            $display("data[%0d]=%0d", bit_i, tx_bit);
        end

        // stop bit
        repeat (4) @(posedge clk);
        tx_bit = uio_oe[0] ? uio_out[0] : 1'b1;
        if (tx_bit !== 1'b1) begin
            $display("FAIL: stop bit");
            errors = errors + 1;
        end else
            $display("OK: stop bit high");

        if (captured !== 8'h55) begin
            $display("FAIL: data captured %02x expected 55", captured);
            errors = errors + 1;
        end else
            $display("OK: data 0x55");

        if (errors == 0)
            $display("PASS: tb_uart_tx");
        else
            $display("FAIL: tb_uart_tx errors=%0d", errors);

        repeat (20) @(posedge clk);
        $finish;
    end
endmodule
