/*
 * Full-chip SPI host BFM: load UART TX firmware via host_if, push 0x55, check uio TX.
 * SPDX-License-Identifier: Apache-2.0
 */
`timescale 1ns/1ps
`default_nettype none

module tb_host_spi;
    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk; // 50 MHz

    reg  [7:0] ui_in = 8'h04; // CS_N high
    wire [7:0] uo_out;
    reg  [7:0] uio_in = 8'hFF;
    wire [7:0] uio_out, uio_oe;
    reg ena = 1;

    tt_um_protocore16 dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    // ui: [0]=SCLK [1]=MOSI [2]=CS_N
    task automatic spi_idle_clks(input integer n);
        integer k;
        begin for (k = 0; k < n; k = k + 1) @(posedge clk); end
    endtask

    task automatic spi_cs(input bit active);
        begin
            ui_in[2] = ~active;
            spi_idle_clks(4);
        end
    endtask

    task automatic spi_byte(input [7:0] mosi, output [7:0] miso);
        integer bi;
        begin
            miso = 8'd0;
            for (bi = 7; bi >= 0; bi = bi - 1) begin
                ui_in[1] = mosi[bi];
                ui_in[0] = 1'b0;
                spi_idle_clks(4);
                ui_in[0] = 1'b1; // sample on rise (Mode 0)
                spi_idle_clks(2);
                miso[bi] = uo_out[0];
                spi_idle_clks(2);
                ui_in[0] = 1'b0;
                spi_idle_clks(4);
            end
        end
    endtask

    task automatic spi_write8(input [7:0] addr, input [7:0] data);
        reg [7:0] dummy;
        begin
            spi_cs(1);
            spi_byte(8'h80, dummy); // WE=1, AUTOINC=0, len-1=0
            spi_byte(addr, dummy);
            spi_byte(data, dummy);
            spi_cs(0);
            spi_idle_clks(4);
        end
    endtask

    task automatic spi_read8(input [7:0] addr, output [7:0] data);
        reg [7:0] dummy;
        begin
            spi_cs(1);
            spi_byte(8'h00, dummy); // WE=0
            spi_byte(addr, dummy);
            // Idle clocks so host_if can latch reg_rdata into rdata_q
            spi_idle_clks(8);
            spi_byte(8'h00, data);
            spi_cs(0);
            spi_idle_clks(4);
        end
    endtask

    task automatic load_uart_tx;
        integer i;
        // Assembled uart_tx.pca words
        reg [15:0] prog [0:11];
        begin
            prog[0]  = 16'h5040;
            prog[1]  = 16'h8000;
            prog[2]  = 16'h3001;
            prog[3]  = 16'h3001;
            prog[4]  = 16'h3001;
            prog[5]  = 16'h3001;
            prog[6]  = 16'h3001;
            prog[7]  = 16'h3001;
            prog[8]  = 16'h3001;
            prog[9]  = 16'h3001;
            prog[10] = 16'h8001;
            prog[11] = 16'h0000;

            spi_write8(8'h02, 8'h00); // SMSEL=0
            spi_write8(8'h03, 8'h00); // PROG_OFF=0
            for (i = 0; i < 12; i = i + 1) begin
                spi_write8(8'h04, prog[i][7:0]);
                spi_write8(8'h04, prog[i][15:8]);
            end
        end
    endtask

    integer errors, bi, guard;
    reg [7:0] captured, rd;
    reg bitv;

    initial begin
        $dumpfile("tb_host_spi.vcd");
        $dumpvars(0, tb_host_spi);
        errors = 0;
        rst_n = 0;
        ui_in = 8'h04;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // Sanity: write/read SMSEL round-trip (exercises read idle clocks)
        spi_write8(8'h02, 8'h03);
        spi_read8(8'h02, rd);
        if (rd !== 8'h03) begin
            $display("FAIL host SMSEL r/w got %02x", rd);
            errors = errors + 1;
        end else
            $display("OK host SPI write/read SMSEL");

        load_uart_tx();
        $display("OK program loaded via SPI");

        // Configure PE0 like tb_pe_uart: clkdiv int=3, set_base=0 set_count=1,
        // out_base=0, autopull=1, shift_right=1, pull_th=8
        spi_write8(8'h02, 8'h00);       // SMSEL
        spi_write8(8'h09, 8'h00);       // CLKDIV_LO
        spi_write8(8'h0A, 8'h03);       // CLKDIV_HI = 3
        spi_write8(8'h0B, 8'h01);       // PINCTRL: set_base=0, set_count=1
        spi_write8(8'h0C, 8'h00);       // PINCTRL2: out_base=0
        spi_write8(8'h0D, 8'h30);       // EXECCTRL: autopull=1, shift_right=1
        spi_write8(8'h0F, 8'h88);       // SHIFTCTRL push/pull thresh nibble=8
        spi_write8(8'h05, 8'h55);       // TXFIFO push
        spi_write8(8'h00, 8'h01);       // CTRL enable SM0

        // Wait for start bit on uio[0]
        guard = 0;
        while (!(uio_oe[0] && uio_out[0] == 1'b0) && guard < 50000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (guard >= 50000) begin
            $display("FAIL: no UART start via host path");
            errors = errors + 1;
        end else
            $display("OK start via host path guard=%0d", guard);

        captured = 0;
        for (bi = 0; bi < 8; bi = bi + 1) begin
            repeat (4) @(posedge clk); // clkdiv int=3 => 4 clocks/tick
            bitv = uio_oe[0] ? uio_out[0] : 1'b1;
            captured[bi] = bitv;
        end
        repeat (4) @(posedge clk);
        bitv = uio_oe[0] ? uio_out[0] : 1'b1;
        if (bitv !== 1'b1) begin
            $display("FAIL stop=%b", bitv);
            errors = errors + 1;
        end
        if (captured !== 8'h55) begin
            $display("FAIL data=%02x", captured);
            errors = errors + 1;
        end else
            $display("OK UART 0x55 via SPI host load");

        if (errors == 0) $display("PASS: tb_host_spi");
        else $display("FAIL: tb_host_spi errors=%0d", errors);
        $finish;
    end
endmodule
