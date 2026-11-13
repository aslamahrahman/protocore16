/*
 * Behavioral stand-in for a 32×16 single-port IMEM macro (IHP SRAM / DFFRAM).
 * Enable with -DPROTOCORE16_USE_IHP_SRAM and instantiate from pe_engine.
 * Not a drop-in foundry model — replace with PDK macro for harden.
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module ihp_sram32x16_bb (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        we,
    input  wire [4:0]  addr,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata
);
    reg [15:0] mem [0:31];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) mem[i] <= 16'h9000;
            rdata <= 16'h9000;
        end else begin
            if (we) mem[addr] <= wdata;
            rdata <= mem[addr]; // 1-cycle read latency like many SRAM macros
        end
    end
endmodule
