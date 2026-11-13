/*
 * SPI master Mode-0 bit smoke: shift 0xA5, check MOSI pattern and SCLK sideset.
 */
`timescale 1ns/1ps
`default_nettype none

module tb_spi_master;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg enable = 0, imem_we = 0;
    reg [4:0] imem_waddr = 0;
    reg [15:0] imem_wdata = 0;
    wire [7:0] gpio_out, gpio_oe;
    wire tx_pull_en;
    reg [7:0] fifo = 8'hA5;
    reg fifo_valid = 0;
    wire [4:0] pc;

    wire crc_clear, crc_dv, crc_db, nz_c, nz_e, nz_d, nz_di, nz_li;
    wire [1:0] crc_mode;
    wire [7:0] irq_set, irq_clr, rx_data;
    wire rx_push_en, busy;

    pe_engine #(.SM_ID(0)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(16'h0100),
        .side_base(3'd1), .side_count(3'd1), .side_en(1'b1),
        .out_base(3'd0), .set_base(3'd0), .set_count(3'd1),
        .in_base(3'd2), .jmp_pin(3'd1),
        .autopush(1'b1), .autopull(1'b0),
        .push_thresh(5'd8), .pull_thresh(5'd8), .shift_right(1'b0), // MSB first
        .wrap_top(5'd31), .wrap_bottom(5'd0),
        .gpio_in({5'd0, gpio_out[0], 1'b0, 1'b0}), // loop MOSI->MISO for check via IN
        .gpio_out(gpio_out), .gpio_oe(gpio_oe),
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

    integer errors=0, i, seen_clk;
    reg [7:0] mosi_bits;

    initial begin
        $dumpfile("tb_spi_master.vcd");
        $dumpvars(0, tb_spi_master);
        rst_n=0; repeat(4) @(posedge clk); rst_n=1;

        // Assembled spi_master.pca
        load_word(0, 16'h5040);
        load_word(1, 16'h8027);
        load_word(2, 16'h3001);
        load_word(3, 16'hB001);
        load_word(4, 16'h2001);
        load_word(5, 16'hB000);
        load_word(6, 16'h0042);
        load_word(7, 16'h4040);
        load_word(8, 16'h0000);

        fifo = 8'hA5; fifo_valid = 1;
        @(posedge clk); enable = 1;

        // Collect 8 MOSI bits sampled when SCLK (gpio[1]) rises
        mosi_bits = 0;
        seen_clk = 0;
        begin : cap
            reg prev_clk;
            integer guard;
            prev_clk = 0; guard = 0;
            while (seen_clk < 8 && guard < 20000) begin
                @(posedge clk);
                if (gpio_oe[1] && gpio_out[1] && !prev_clk) begin
                    mosi_bits = {mosi_bits[6:0], gpio_out[0]};
                    seen_clk = seen_clk + 1;
                    $display("sclk edge %0d mosi=%b acc=%02x", seen_clk, gpio_out[0], mosi_bits);
                end
                prev_clk = gpio_oe[1] ? gpio_out[1] : 0;
                guard = guard + 1;
            end
        end

        if (seen_clk != 8) begin
            $display("FAIL: only %0d clock edges", seen_clk);
            errors = errors + 1;
        end
        // MSB first 0xA5 = 10100101
        if (mosi_bits !== 8'hA5) begin
            $display("FAIL MOSI=%02x expected A5", mosi_bits);
            errors = errors + 1;
        end else
            $display("OK MOSI 0xA5");

        if (errors==0) $display("PASS: tb_spi_master");
        else $display("FAIL: tb_spi_master %0d", errors);
        $finish;
    end
endmodule
