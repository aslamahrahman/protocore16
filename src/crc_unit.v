/*
 * ProtoCore16 — shared CRC assist (USB / Ethernet / CCITT)
 * Modes:
 *   0: CRC-5 USB (poly 0x05, init 0x1F, reflect)
 *   1: CRC-16-CCITT (poly 0x1021, init 0xFFFF)
 *   2: CRC-16-USB (poly 0x8005, init 0xFFFF, reflect, xorout 0xFFFF)
 *   3: CRC-32 Ethernet (poly 0x04C11DB7, init 0xFFFFFFFF, reflect, xorout 0xFFFFFFFF)
 *
 * Operates one bit per clock when run=1, or byte-fold helper via bit_count.
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module crc_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire [1:0]  mode,
    input  wire        din_valid,
    input  wire        din_bit,
    output reg  [31:0] crc_out
);
    reg [31:0] crc;

    always @(*) begin
        case (mode)
            2'd0: crc_out = {27'd0, crc[4:0]};
            2'd1: crc_out = {16'd0, crc[15:0]};
            // USB-16 / Eth-32: expose post-xorout residue (matches header docs)
            2'd2: crc_out = {16'd0, crc[15:0] ^ 16'hFFFF};
            default: crc_out = crc ^ 32'hFFFF_FFFF;
        endcase
    end

    function [31:0] step_crc5;
        input [31:0] c;
        input        b;
        reg          f;
        begin
            f = c[0] ^ b;
            step_crc5 = {27'd0, f, c[4:1]};
            if (f) step_crc5[4:0] = step_crc5[4:0] ^ 5'h14; // reflected poly handling via LSB-first
            // Classic USB CRC5 LSB-first: poly reflected 0x14 for 5-bit
        end
    endfunction

    // Cleaner bit-serial implementations
    wire [4:0]  c5  = crc[4:0];
    wire [15:0] c16 = crc[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc <= 32'hFFFF_FFFF;
        end else if (clear) begin
            case (mode)
                2'd0: crc <= 32'h0000_001F;
                2'd1: crc <= 32'h0000_FFFF;
                2'd2: crc <= 32'h0000_FFFF;
                default: crc <= 32'hFFFF_FFFF;
            endcase
        end else if (din_valid) begin
            case (mode)
                2'd0: begin
                    // USB CRC-5, LSB first, poly 0x05 reflected = 0x14
                    if (c5[0] ^ din_bit)
                        crc[4:0] <= {1'b0, c5[4:1]} ^ 5'h14;
                    else
                        crc[4:0] <= {1'b0, c5[4:1]};
                end
                2'd1: begin
                    // CRC-16-CCITT MSB first, poly 0x1021
                    if (c16[15] ^ din_bit)
                        crc[15:0] <= {c16[14:0], 1'b0} ^ 16'h1021;
                    else
                        crc[15:0] <= {c16[14:0], 1'b0};
                end
                2'd2: begin
                    // CRC-16-USB LSB first, poly reflected 0xA001
                    if (c16[0] ^ din_bit)
                        crc[15:0] <= {1'b0, c16[15:1]} ^ 16'hA001;
                    else
                        crc[15:0] <= {1'b0, c16[15:1]};
                end
                default: begin
                    // CRC-32 Ethernet LSB first, poly reflected 0xEDB88320
                    if (crc[0] ^ din_bit)
                        crc <= {1'b0, crc[31:1]} ^ 32'hEDB88320;
                    else
                        crc <= {1'b0, crc[31:1]};
                end
            endcase
        end
    end
endmodule
