/*
 * ProtoCore16 — NRZI encode/decode assist (USB / similar)
 * Encode: out_level toggles on din=0, holds on din=1 (USB convention)
 * Decode: dout=0 if level changed, dout=1 if same
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module nrzi_unit (
    input  wire clk,
    input  wire rst_n,
    input  wire clear,
    input  wire enc_en,
    input  wire dec_en,
    input  wire din,
    input  wire level_in,   // for decode: sampled line
    output reg  dout,
    output reg  level_out
);
    reg prev_level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level_out  <= 1'b1;
            prev_level <= 1'b1;
            dout       <= 1'b1;
        end else if (clear) begin
            level_out  <= 1'b1;
            prev_level <= 1'b1;
            dout       <= 1'b1;
        end else begin
            if (enc_en) begin
                if (!din)
                    level_out <= ~level_out;
                dout <= din;
            end
            if (dec_en) begin
                dout       <= (level_in == prev_level);
                prev_level <= level_in;
            end
        end
    end
endmodule
