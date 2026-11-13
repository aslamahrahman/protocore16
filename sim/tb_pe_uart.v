/*
 * Direct PE engine UART TX test (bypasses host SPI)
 */
`timescale 1ns/1ps
`default_nettype none

module tb_pe_uart;
    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk; // 50 MHz

    reg        enable = 0;
    reg        imem_we = 0;
    reg [4:0]  imem_waddr = 0;
    reg [15:0] imem_wdata = 0;

    reg [7:0]  gpio_in = 8'hFF;
    wire [7:0] gpio_out, gpio_oe;

    wire       tx_pull_en;
    wire       rx_push_en;
    wire [7:0] rx_data;
    wire [7:0] irq_set, irq_clr;
    wire [4:0] pc;
    wire       busy;

    // CRC/NRZI stubs
    wire crc_clear, crc_dv, crc_db;
    wire [1:0] crc_mode;
    wire nz_c, nz_e, nz_d, nz_di, nz_li;

    // simple 1-deep TX FIFO model
    reg [7:0] fifo = 0;
    reg fifo_valid = 0;
    wire [7:0] tx_data = fifo;
    wire tx_empty = ~fifo_valid;

    pe_engine #(.SM_ID(0)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(16'h0300), // int=3 => tick every 4 cycles
        .side_base(3'd0), .side_count(3'd0), .side_en(1'b0),
        .out_base(3'd0), .set_base(3'd0), .set_count(3'd1),
        .in_base(3'd0), .jmp_pin(3'd0),
        .autopush(1'b0), .autopull(1'b1),
        .push_thresh(5'd8), .pull_thresh(5'd8), .shift_right(1'b1),
        .wrap_top(5'd31), .wrap_bottom(5'd0),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .tx_pull_en(tx_pull_en), .tx_data(tx_data), .tx_empty(tx_empty),
        .rx_push_en(rx_push_en), .rx_data(rx_data), .rx_full(1'b0),
        .irq_in(8'd0), .irq_set(irq_set), .irq_clr(irq_clr),
        .crc_clear(crc_clear), .crc_mode(crc_mode), .crc_din_valid(crc_dv),
        .crc_din_bit(crc_db), .crc_value(32'd0),
        .nrzi_clear(nz_c), .nrzi_enc_en(nz_e), .nrzi_dec_en(nz_d),
        .nrzi_din(nz_di), .nrzi_level_in(nz_li),
        .nrzi_dout(1'b1), .nrzi_level_out(1'b1),
        .pc_out(pc), .busy(busy), .x_out(), .y_out()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fifo_valid <= 0;
        else if (tx_pull_en && fifo_valid)
            fifo_valid <= 0;
    end

    task load_word(input [4:0] a, input [15:0] w);
        begin
            @(posedge clk);
            imem_we <= 1; imem_waddr <= a; imem_wdata <= w;
            @(posedge clk);
            imem_we <= 0;
        end
    endtask

    integer errors, bi, guard;
    reg [7:0] captured;
    reg bitv;

    initial begin
        $dumpfile("tb_pe_uart.vcd");
        $dumpvars(0, tb_pe_uart);
        errors = 0;
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // uart_tx program
        load_word(0, 16'h5040);
        load_word(1, 16'h8000);
        load_word(2, 16'h3001);
        load_word(3, 16'h3001);
        load_word(4, 16'h3001);
        load_word(5, 16'h3001);
        load_word(6, 16'h3001);
        load_word(7, 16'h3001);
        load_word(8, 16'h3001);
        load_word(9, 16'h3001);
        load_word(10, 16'h8001);
        load_word(11, 16'h0000);

        // preload FIFO with 0x55
        fifo = 8'h55;
        fifo_valid = 1;

        @(posedge clk);
        enable = 1;

        // wait start bit
        guard = 0;
        bitv = 1;
        while (!(gpio_oe[0] && gpio_out[0] == 1'b0) && guard < 10000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (guard >= 10000) begin
            $display("FAIL: no start bit, pc=%0d oe=%b out=%b", pc, gpio_oe, gpio_out);
            errors = errors + 1;
        end else
            $display("OK start at cycle guard=%0d pc=%0d", guard, pc);

        // sample 8 data bits — each OUT is one div tick (4 clocks)
        captured = 0;
        for (bi = 0; bi < 8; bi = bi + 1) begin
            // move to middle of next bit window: 4 clocks per tick
            repeat (4) @(posedge clk);
            bitv = gpio_oe[0] ? gpio_out[0] : 1'b1;
            captured[bi] = bitv;
            $display("bit%0d=%0d pc=%0d", bi, bitv, pc);
        end

        repeat (4) @(posedge clk);
        bitv = gpio_oe[0] ? gpio_out[0] : 1'b1;
        if (bitv !== 1'b1) begin
            $display("FAIL stop=%b", bitv);
            errors = errors + 1;
        end else
            $display("OK stop");

        if (captured !== 8'h55) begin
            $display("FAIL data=%02x", captured);
            errors = errors + 1;
        end else
            $display("OK data 0x55");

        if (errors == 0) $display("PASS: tb_pe_uart");
        else $display("FAIL: tb_pe_uart errors=%0d", errors);
        $finish;
    end
endmodule
