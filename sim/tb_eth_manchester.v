/*
 * PE Manchester half-bit TX smoke: shift pre-packed half-bits MSB-first onto TX_P.
 * SPDX-License-Identifier: Apache-2.0
 */
`timescale 1ns/1ps
`default_nettype none

module tb_eth_manchester;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg enable = 0, imem_we = 0;
    reg [4:0] imem_waddr = 0;
    reg [15:0] imem_wdata = 0;
    wire [7:0] gpio_out, gpio_oe;
    wire tx_pull_en;
    // Pre-encoded Manchester for data bits 1,0,1,0 → half-bits 10 01 10 01 = 0x99
    reg [7:0] fifo = 8'h99;
    reg fifo_valid = 0;
    wire [4:0] pc;

    wire crc_clear, crc_dv, crc_db, nz_c, nz_e, nz_d, nz_di, nz_li;
    wire [1:0] crc_mode;
    wire [7:0] irq_set, irq_clr, rx_data;
    wire rx_push_en, busy;

    pe_engine #(.SM_ID(0)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(16'h0000),
        .side_base(3'd1), .side_count(3'd0), .side_en(1'b0),
        .out_base(3'd0), .set_base(3'd0), .set_count(3'd1),
        .in_base(3'd0), .jmp_pin(3'd0),
        .autopush(1'b0), .autopull(1'b0),
        .push_thresh(5'd8), .pull_thresh(5'd8), .shift_right(1'b0),
        .wrap_top(5'd31), .wrap_bottom(5'd0),
        .gpio_in(8'h00), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .tx_pull_en(tx_pull_en), .tx_data(fifo), .tx_empty(~fifo_valid),
        .rx_push_en(rx_push_en), .rx_data(rx_data), .rx_full(1'b0),
        .irq_in(8'd0), .irq_set(irq_set), .irq_clr(irq_clr),
        .crc_clear(crc_clear), .crc_mode(crc_mode), .crc_din_valid(crc_dv),
        .crc_din_bit(crc_db), .crc_value(32'd0),
        .nrzi_clear(nz_c), .nrzi_enc_en(nz_e), .nrzi_dec_en(nz_d),
        .nrzi_din(nz_di), .nrzi_level_in(nz_li),
        .nrzi_dout(1'b1), .nrzi_level_out(1'b1),
        .pc_out(pc), .busy(busy), .x_out(), .y_out()
    );

    always @(posedge clk or negedge rst_n)
        if (!rst_n) fifo_valid <= 0;
        else if (tx_pull_en && fifo_valid) fifo_valid <= 0;

    task load_word(input [4:0] a, input [15:0] w);
        begin @(posedge clk); imem_we<=1; imem_waddr<=a; imem_wdata<=w; @(posedge clk); imem_we<=0; end
    endtask

    integer errors=0, seen, guard;
    reg [7:0] halfbits;
    reg [4:0] prev_pc;

    initial begin
        $dumpfile("tb_eth_manchester.vcd");
        $dumpvars(0, tb_eth_manchester);
        rst_n=0; repeat(4) @(posedge clk); rst_n=1;

        // pull; set x,7; out pins,1; jmp x--; waitg
        // X-- runs 7 taken jumps after first OUT, plus final OUT when X hits 0 → 8 OUTs
        load_word(0, 16'h5040);
        load_word(1, 16'h8027);
        load_word(2, 16'h3001);
        load_word(3, 16'h0042);
        load_word(4, 16'hE0FF);

        fifo = 8'h99; fifo_valid = 1;
        @(posedge clk); enable = 1;

        halfbits = 0;
        seen = 0;
        guard = 0;
        begin : cap
            reg prev_out;
            reg have_prev;
            prev_out = 0;
            have_prev = 0;
            while (seen < 8 && guard < 20000) begin
                @(posedge clk);
                #1;
                if (gpio_oe[0]) begin
                    // Count every OUT tick: OUT is the only instr driving pin here,
                    // and each is separated by a JMP (pin holds). Sample on each
                    // cycle where PC just left the OUT (pc==3 after OUT exec).
                    if (pc == 5'd3) begin
                        halfbits = {halfbits[6:0], gpio_out[0]};
                        seen = seen + 1;
                        $display("half%0d=%0d acc=%02x", seen, gpio_out[0], halfbits);
                        @(posedge clk); // skip JMP body
                    end
                end
                guard = guard + 1;
            end
        end

        if (seen != 8) begin
            $display("FAIL: only %0d half-bits", seen);
            errors = errors + 1;
        end
        if (halfbits !== 8'h99) begin
            $display("FAIL halfbits=%02x expected 99", halfbits);
            errors = errors + 1;
        end else
            $display("OK Manchester half-bit stream 0x99");

        if (errors==0) $display("PASS: tb_eth_manchester");
        else $display("FAIL: tb_eth_manchester %0d", errors);
        $finish;
    end
endmodule
