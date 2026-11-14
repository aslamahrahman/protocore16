/*
 * ProtoCore16 — SPI Mode-0 host slave (3-wire + CS)
 *
 * ui_in[0] = SCLK
 * ui_in[1] = MOSI
 * ui_in[2] = CS_N (active low)
 * uo_out[0] = MISO
 * uo_out[7:1] = {irq, status peek}
 *
 * Frame while CS low (MSB first):
 *   byte0: CMD  [7]=WE [6]=AUTOINC [5:0]=NBYTES-1
 *   byte1: ADDR
 *   byte2..: DATA (write from host / read to host)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module host_if (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] ui_in,
    output reg  [7:0] uo_out,
    output wire       irq,
    output reg        reg_we,
    output reg        reg_re,
    output reg  [7:0] reg_addr,
    output reg  [7:0] reg_wdata,
    input  wire [7:0] reg_rdata,
    input  wire       irq_in
);
    assign irq = irq_in;

    wire sclk = ui_in[0];
    wire mosi = ui_in[1];
    wire cs_n = ui_in[2];

    reg [2:0] sclk_r, mosi_r, csn_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_r <= 3'b0;
            mosi_r <= 3'b0;
            csn_r  <= 3'b111;
        end else begin
            sclk_r <= {sclk_r[1:0], sclk};
            mosi_r <= {mosi_r[1:0], mosi};
            csn_r  <= {csn_r[1:0], cs_n};
        end
    end

    wire sclk_rise = (sclk_r[2:1] == 2'b01);
    wire sclk_fall = (sclk_r[2:1] == 2'b10);
    wire cs_active = (csn_r[1] == 1'b0);

    localparam ST_CMD  = 2'd0;
    localparam ST_ADDR = 2'd1;
    localparam ST_DATA = 2'd2;

    reg [1:0] st;
    reg [2:0] bit_i;
    reg [7:0] sh_in, sh_out;
    reg       cmd_we, cmd_inc;
    reg [5:0] bytes_left;
    reg [7:0] addr_r;
    reg       miso_q;
    reg [7:0] rdata_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_CMD;
            bit_i <= 3'd0;
            sh_in <= 8'd0;
            sh_out <= 8'd0;
            cmd_we <= 1'b0;
            cmd_inc <= 1'b0;
            bytes_left <= 6'd0;
            addr_r <= 8'd0;
            reg_we <= 1'b0;
            reg_re <= 1'b0;
            reg_addr <= 8'd0;
            reg_wdata <= 8'd0;
            miso_q <= 1'b0;
            rdata_q <= 8'd0;
            uo_out <= 8'd0;
        end else begin
            reg_we <= 1'b0;
            reg_re <= 1'b0;

            if (reg_re)
                rdata_q <= reg_rdata;

            if (!cs_active) begin
                st <= ST_CMD;
                bit_i <= 3'd0;
                miso_q <= 1'b0;
            end else begin
                if (sclk_rise) begin
                    sh_in <= {sh_in[6:0], mosi_r[1]};
                    if (bit_i == 3'd7) begin
                        case (st)
                            ST_CMD: begin
                                cmd_we <= sh_in[6]; // will be completed with mosi as LSB — fix below
                            end
                            default: ;
                        endcase
                    end
                    bit_i <= bit_i + 3'd1;
                end

                // Complete byte after 8th rising sample: use combinational byte
                if (sclk_rise && bit_i == 3'd7) begin
                    begin : byte_done
                        reg [7:0] b;
                        b = {sh_in[6:0], mosi_r[1]};
                        case (st)
                            ST_CMD: begin
                                cmd_we <= b[7];
                                cmd_inc <= b[6];
                                bytes_left <= b[5:0];
                                st <= ST_ADDR;
                            end
                            ST_ADDR: begin
                                addr_r <= b;
                                reg_addr <= b;
                                st <= ST_DATA;
                                if (!cmd_we)
                                    reg_re <= 1'b1;
                            end
                            ST_DATA: begin
                                if (cmd_we) begin
                                    reg_addr <= addr_r;
                                    reg_wdata <= b;
                                    reg_we <= 1'b1;
                                    if (cmd_inc) addr_r <= addr_r + 8'd1;
                                end else begin
                                    if (cmd_inc) begin
                                        addr_r <= addr_r + 8'd1;
                                        reg_addr <= addr_r + 8'd1;
                                    end else begin
                                        reg_addr <= addr_r;
                                    end
                                    reg_re <= 1'b1;
                                end
                                if (bytes_left == 6'd0)
                                    st <= ST_CMD;
                                else
                                    bytes_left <= bytes_left - 6'd1;
                            end
                            default: st <= ST_CMD;
                        endcase
                    end
                end

                // MISO updates on falling edge
                if (sclk_fall) begin
                    if (bit_i == 3'd0 && st == ST_DATA && !cmd_we) begin
                        sh_out <= rdata_q;
                        miso_q <= rdata_q[7];
                    end else begin
                        miso_q <= sh_out[6];
                        sh_out <= {sh_out[6:0], 1'b0};
                    end
                end
            end

            uo_out <= {irq_in, 6'd0, miso_q};
        end
    end
endmodule
