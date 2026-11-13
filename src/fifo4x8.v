/*
 * ProtoCore16 — 4-deep × 8-bit sync FIFO
 * Copyright (c) 2026 ProtoCore16 contributors
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module fifo4x8 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       wr_en,
    input  wire [7:0] wr_data,
    input  wire       rd_en,
    output wire [7:0] rd_data,
    output wire       empty,
    output wire       full,
    output wire [2:0] level
);
    reg [7:0] mem [0:3];
    reg [1:0] wr_ptr, rd_ptr;
    reg [2:0] count;

    assign empty = (count == 3'd0);
    assign full  = (count == 3'd4);
    assign level = count;
    assign rd_data = mem[rd_ptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 2'd0;
            rd_ptr <= 2'd0;
            count  <= 3'd0;
            mem[0] <= 8'd0;
            mem[1] <= 8'd0;
            mem[2] <= 8'd0;
            mem[3] <= 8'd0;
        end else begin
            case ({wr_en & ~full, rd_en & ~empty})
                2'b10: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr <= wr_ptr + 2'd1;
                    count  <= count + 3'd1;
                end
                2'b01: begin
                    rd_ptr <= rd_ptr + 2'd1;
                    count  <= count - 3'd1;
                end
                2'b11: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr <= wr_ptr + 2'd1;
                    rd_ptr <= rd_ptr + 2'd1;
                end
                default: ;
            endcase
        end
    end
endmodule
