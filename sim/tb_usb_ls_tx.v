/*
 * PE + NRZI: encode USB SYNC (0x80 LSB-first) onto set_base pin.
 * SPDX-License-Identifier: Apache-2.0
 */
`timescale 1ns/1ps
`default_nettype none

module tb_usb_ls_tx;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg enable = 0, imem_we = 0;
    reg [4:0] imem_waddr = 0;
    reg [15:0] imem_wdata = 0;
    wire [7:0] gpio_out, gpio_oe;
    wire tx_pull_en;
    reg [7:0] fifo = 8'h80; // SYNC
    reg fifo_valid = 0;
    wire [4:0] pc;

    wire crc_clear, crc_dv, crc_db;
    wire [1:0] crc_mode;
    wire [7:0] irq_set, irq_clr, rx_data;
    wire rx_push_en, busy;
    wire nz_c, nz_e, nz_d, nz_di, nz_li;
    wire nrzi_dout, nrzi_level_out;

    nrzi_unit u_nrzi (
        .clk(clk), .rst_n(rst_n), .clear(nz_c),
        .enc_en(nz_e), .dec_en(nz_d),
        .din(nz_di), .level_in(nz_li),
        .dout(nrzi_dout), .level_out(nrzi_level_out)
    );

    pe_engine #(.SM_ID(0)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(16'h0000),
        .side_base(3'd0), .side_count(3'd0), .side_en(1'b0),
        .out_base(3'd0), .set_base(3'd0), .set_count(3'd1),
        .in_base(3'd0), .jmp_pin(3'd0),
        .autopush(1'b0), .autopull(1'b0),
        .push_thresh(5'd8), .pull_thresh(5'd8), .shift_right(1'b1),
        .wrap_top(5'd31), .wrap_bottom(5'd0),
        .gpio_in(8'hFF), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .tx_pull_en(tx_pull_en), .tx_data(fifo), .tx_empty(~fifo_valid),
        .rx_push_en(rx_push_en), .rx_data(rx_data), .rx_full(1'b0),
        .irq_in(8'd0), .irq_set(irq_set), .irq_clr(irq_clr),
        .crc_clear(crc_clear), .crc_mode(crc_mode), .crc_din_valid(crc_dv),
        .crc_din_bit(crc_db), .crc_value(32'd0),
        .nrzi_clear(nz_c), .nrzi_enc_en(nz_e), .nrzi_dec_en(nz_d),
        .nrzi_din(nz_di), .nrzi_level_in(nz_li),
        .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out),
        .pc_out(pc), .busy(busy), .x_out(), .y_out()
    );

    always @(posedge clk or negedge rst_n)
        if (!rst_n) fifo_valid <= 0;
        else if (tx_pull_en && fifo_valid) fifo_valid <= 0;

    task load_word(input [4:0] a, input [15:0] w);
        begin @(posedge clk); imem_we<=1; imem_waddr<=a; imem_wdata<=w; @(posedge clk); imem_we<=0; end
    endtask

    integer errors=0, seen, guard;
    reg [7:0] levels;
    reg saw_enc;

    initial begin
        $dumpfile("tb_usb_ls_tx.vcd");
        $dumpvars(0, tb_usb_ls_tx);
        rst_n=0; repeat(4) @(posedge clk); rst_n=1;

        // nrzi enc,clear; pull block; set x,7; nrzi enc; jmp x-- ; waitg
        load_word(0, 16'hD060);
        load_word(1, 16'h5040);
        load_word(2, 16'h8027);
        load_word(3, 16'hD040);
        load_word(4, 16'h0043);
        load_word(5, 16'hE0FF);

        fifo = 8'h80; fifo_valid = 1;
        @(posedge clk); enable = 1;

        levels = 0;
        seen = 0;
        guard = 0;
        saw_enc = 0;
        // Sample gpio on cycles where nrzi_enc_en pulses (post-NBA via nz_e wire)
        while (seen < 8 && guard < 20000) begin
            @(posedge clk);
            #1;
            if (nz_e && gpio_oe[0]) begin
                levels[seen] = gpio_out[0];
                $display("usb enc%0d level=%0d din=%0d", seen, gpio_out[0], nz_di);
                seen = seen + 1;
            end
            guard = guard + 1;
        end

        if (seen != 8) begin
            $display("FAIL: captured %0d levels", seen);
            errors = errors + 1;
        end
        // SYNC 00000001 → levels 0,1,0,1,0,1,0,0 → levels[7:0]=8'b00101010
        if (levels !== 8'b00101010) begin
            $display("FAIL USB SYNC levels=%b expected 00101010", levels);
            errors = errors + 1;
        end else
            $display("OK USB SYNC NRZI on wire");

        if (errors==0) $display("PASS: tb_usb_ls_tx");
        else $display("FAIL: tb_usb_ls_tx %0d", errors);
        $finish;
    end
endmodule
