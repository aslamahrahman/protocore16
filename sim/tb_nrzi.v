/*
 * NRZI unit encode/decode vectors (USB convention: 0=toggle, 1=hold).
 * SPDX-License-Identifier: Apache-2.0
 */
`timescale 1ns/1ps
`default_nettype none

module tb_nrzi;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg clear = 0, enc_en = 0, dec_en = 0, din = 0, level_in = 1;
    wire dout, level_out;

    nrzi_unit uut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .enc_en(enc_en), .dec_en(dec_en),
        .din(din), .level_in(level_in),
        .dout(dout), .level_out(level_out)
    );

    integer errors = 0, i;
    // USB SYNC = 0x80 → bits LSB-first 0,0,0,0,0,0,0,1
    reg [7:0] sync_bits = 8'h80;
    reg [7:0] levels;

    task automatic enc_bit(input bit b);
        begin
            @(posedge clk);
            enc_en <= 1; din <= b; clear <= 0;
            @(posedge clk); // unit consumes enc_en
            enc_en <= 0;
            @(posedge clk); // sample settled level_out
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;

        @(posedge clk); clear <= 1;
        @(posedge clk); clear <= 0;
        @(posedge clk);
        if (level_out !== 1'b1) begin
            $display("FAIL clear->J got %b", level_out);
            errors = errors + 1;
        end else
            $display("OK clear -> J");

        levels = 0;
        for (i = 0; i < 8; i = i + 1) begin
            enc_bit(sync_bits[i]);
            levels[i] = level_out;
            $display("enc bit%0d=%0d level=%0d", i, sync_bits[i], level_out);
        end
        // levels 0,1,0,1,0,1,0,0 → 8'b00101010
        if (levels !== 8'b00101010) begin
            $display("FAIL SYNC levels=%b expected 00101010", levels);
            errors = errors + 1;
        end else
            $display("OK SYNC NRZI levels");

        @(posedge clk); clear <= 1;
        @(posedge clk); clear <= 0;
        @(posedge clk);
        begin : dec
            reg [7:0] got;
            got = 0;
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge clk);
                level_in <= levels[i];
                dec_en <= 1;
                @(posedge clk);
                dec_en <= 0;
                @(posedge clk);
                got[i] = dout;
                $display("dec level%0d=%0d bit=%0d", i, levels[i], dout);
            end
            if (got !== sync_bits) begin
                $display("FAIL decode got %b expected %b", got, sync_bits);
                errors = errors + 1;
            end else
                $display("OK NRZI decode SYNC");
        end

        if (errors == 0) $display("PASS: tb_nrzi");
        else $display("FAIL: tb_nrzi %0d", errors);
        $finish;
    end
endmodule
