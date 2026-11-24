/*
 * ProtoCore16 — FPGA cut for iCE40UP5K (1× PE)
 *
 * Same host SPI + register map as tt_um_protocore16 for SM0 / global regs.
 * PE1–3 are omitted so the design fits Muse Lab iCESugar (5280 LC).
 * Full 4-PE ASIC RTL remains in ../src/tt_um_protocore16.v (~2.6× UP5K).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_protocore16_fpga1 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    wire       reg_we, reg_re;
    wire [7:0] reg_addr, reg_wdata;
    reg  [7:0] reg_rdata;

    wire host_irq;
    host_if u_host (
        .clk(clk), .rst_n(rst_n),
        .ui_in(ui_in), .uo_out(uo_out), .irq(host_irq),
        .reg_we(reg_we), .reg_re(reg_re),
        .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .irq_in(|(irq_flags & irq_enable))
    );

    reg        sm_enable0;
    reg [7:0]  sm_sel;
    reg [7:0]  prog_off;
    reg [7:0]  irq_flags, irq_enable;
    reg [1:0]  crc_mode_r;
    reg        crc_clear_host;
    reg        imem_hi_phase;
    reg [7:0]  imem_lo_latch;

    reg [15:0] clkdiv0;
    reg [7:0]  pin0, pinb0, exec0, wrap0, sh0;

    reg        imem_we0;
    reg [4:0]  imem_waddr;
    reg [15:0] imem_wdata;

    reg        tx_wr0;
    reg [7:0]  tx_wdata;
    reg        rx_rd0;

    wire [7:0] tx_d0;
    wire       tx_e0, tx_f0;
    wire [2:0] tx_l0;
    wire [7:0] rx_q0;
    wire       rx_e0, rx_f0;
    wire [2:0] rx_l0;

    wire       tx_pull0, rx_push0;
    wire [7:0] rx_d0;

    fifo4x8 u_tx0 (
        .clk(clk), .rst_n(rst_n), .wr_en(tx_wr0), .wr_data(tx_wdata),
        .rd_en(tx_pull0), .rd_data(tx_d0), .empty(tx_e0), .full(tx_f0), .level(tx_l0)
    );
    fifo4x8 u_rx0 (
        .clk(clk), .rst_n(rst_n), .wr_en(rx_push0), .wr_data(rx_d0),
        .rd_en(rx_rd0), .rd_data(rx_q0), .empty(rx_e0), .full(rx_f0), .level(rx_l0)
    );

    wire [7:0] go0, ge0, is0, ic0;
    wire [4:0] pc0;
    wire       bz0;

    wire       crc_clear_sm;
    wire       crc_dv;
    wire       crc_db;
    wire [1:0] cm0;
    wire       nz_c, nz_e, nz_d, nz_di, nz_li;
    wire [31:0] crc_out;
    wire       nrzi_dout, nrzi_level_out;

    wire crc_clear = crc_clear_host | crc_clear_sm;
    wire crc_din_valid = crc_dv;
    wire crc_din_bit = crc_db;
    wire [1:0] crc_mode = crc_dv ? cm0 : crc_mode_r;

    crc_unit u_crc (
        .clk(clk), .rst_n(rst_n), .clear(crc_clear), .mode(crc_mode),
        .din_valid(crc_din_valid), .din_bit(crc_din_bit), .crc_out(crc_out)
    );
    nrzi_unit u_nrzi (
        .clk(clk), .rst_n(rst_n), .clear(nz_c),
        .enc_en(nz_e), .dec_en(nz_d),
        .din(nz_di), .level_in(nz_li),
        .dout(nrzi_dout), .level_out(nrzi_level_out)
    );

    /* verilator lint_off PINCONNECTEMPTY */
    pe_engine #(.SM_ID(0)) u_pe0 (
        .clk(clk), .rst_n(rst_n), .enable(sm_enable0),
        .imem_we(imem_we0), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(clkdiv0), .side_base(pin0[7:5]), .side_count({1'b0, pinb0[1:0]}), .side_en(exec0[7]),
        .out_base(pinb0[7:5]), .set_base(pin0[4:2]), .set_count({1'b0, pin0[1:0]}),
        .in_base(pinb0[4:2]), .jmp_pin(exec0[2:0]),
        .autopush(exec0[6]), .autopull(exec0[5]),
        .push_thresh({1'b0, sh0[7:4]}), .pull_thresh({1'b0, sh0[3:0]}), .shift_right(exec0[4]),
        .wrap_top({1'b0, wrap0[7:4]}), .wrap_bottom({1'b0, wrap0[3:0]}),
        .gpio_in(uio_in), .gpio_out(go0), .gpio_oe(ge0),
        .tx_pull_en(tx_pull0), .tx_data(tx_d0), .tx_empty(tx_e0),
        .rx_push_en(rx_push0), .rx_data(rx_d0), .rx_full(rx_f0),
        .irq_in(irq_flags), .irq_set(is0), .irq_clr(ic0),
        .crc_clear(crc_clear_sm), .crc_mode(cm0), .crc_din_valid(crc_dv), .crc_din_bit(crc_db),
        .crc_value(crc_out),
        .nrzi_clear(nz_c), .nrzi_enc_en(nz_e), .nrzi_dec_en(nz_d),
        .nrzi_din(nz_di), .nrzi_level_in(nz_li), .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out),
        .pc_out(pc0), .busy(bz0), .x_out(), .y_out()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    assign uio_out = go0;
    assign uio_oe  = ge0;

    wire [1:0] sel = sm_sel[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_enable0 <= 1'b0;
            sm_sel <= 8'd0;
            prog_off <= 8'd0;
            irq_enable <= 8'd0;
            crc_mode_r <= 2'd0;
            crc_clear_host <= 1'b0;
            imem_hi_phase <= 1'b0;
            imem_lo_latch <= 8'd0;
            imem_we0 <= 1'b0;
            imem_waddr <= 5'd0;
            imem_wdata <= 16'd0;
            tx_wr0 <= 1'b0;
            rx_rd0 <= 1'b0;
            tx_wdata <= 8'd0;
            clkdiv0 <= 16'd0;
            pin0 <= 8'd0;
            pinb0 <= 8'd0;
            exec0 <= 8'h10;
            wrap0 <= 8'hF0;
            sh0 <= 8'h88;
            irq_flags <= 8'd0;
            reg_rdata <= 8'd0;
        end else begin
            imem_we0 <= 1'b0;
            tx_wr0 <= 1'b0;
            rx_rd0 <= 1'b0;
            crc_clear_host <= 1'b0;

            irq_flags <= (irq_flags | is0) & ~ic0;

            case (reg_addr)
                8'h00: reg_rdata <= {7'd0, sm_enable0};
                8'h01: reg_rdata <= {tx_e0, 3'b111, 3'b000, bz0}; // SM1-3 appear idle/empty
                8'h02: reg_rdata <= sm_sel;
                8'h03: reg_rdata <= prog_off;
                8'h06: reg_rdata <= (sel == 2'd0) ? rx_q0 : 8'h00;
                8'h07: reg_rdata <= irq_flags;
                8'h08: reg_rdata <= irq_enable;
                8'h09: reg_rdata <= (sel == 2'd0) ? clkdiv0[7:0] : 8'h00;
                8'h0A: reg_rdata <= (sel == 2'd0) ? clkdiv0[15:8] : 8'h00;
                8'h0B: reg_rdata <= (sel == 2'd0) ? pin0 : 8'h00;
                8'h0C: reg_rdata <= (sel == 2'd0) ? pinb0 : 8'h00;
                8'h0D: reg_rdata <= (sel == 2'd0) ? exec0 : 8'h00;
                8'h0E: reg_rdata <= (sel == 2'd0) ? wrap0 : 8'h00;
                8'h0F: reg_rdata <= (sel == 2'd0) ? sh0 : 8'h00;
                8'h10: reg_rdata <= {6'd0, crc_mode_r};
                8'h11: reg_rdata <= crc_out[7:0];
                8'h12: reg_rdata <= crc_out[15:8];
                8'h13: reg_rdata <= (sel == 2'd0) ? {3'd0, pc0} : 8'h00;
                8'h14: reg_rdata <= (sel == 2'd0) ? {1'b0, rx_l0, 1'b0, tx_l0} : 8'h00;
                8'h15: reg_rdata <= crc_out[23:16];
                8'h16: reg_rdata <= crc_out[31:24];
                default: reg_rdata <= 8'hA5;
            endcase

            if (reg_re && reg_addr == 8'h06 && sel == 2'd0)
                rx_rd0 <= 1'b1;

            if (reg_we) begin
                case (reg_addr)
                    8'h00: sm_enable0 <= reg_wdata[0];
                    8'h02: sm_sel <= reg_wdata;
                    8'h03: begin prog_off <= reg_wdata; imem_hi_phase <= 1'b0; end
                    8'h04: begin
                        if (!imem_hi_phase) begin
                            imem_lo_latch <= reg_wdata;
                            imem_hi_phase <= 1'b1;
                        end else if (sel == 2'd0) begin
                            imem_waddr <= prog_off[4:0];
                            imem_wdata <= {reg_wdata, imem_lo_latch};
                            imem_we0 <= 1'b1;
                            imem_hi_phase <= 1'b0;
                            prog_off <= prog_off + 8'd1;
                        end else begin
                            imem_hi_phase <= 1'b0;
                            prog_off <= prog_off + 8'd1;
                        end
                    end
                    8'h05: if (sel == 2'd0) begin
                        tx_wdata <= reg_wdata;
                        tx_wr0 <= 1'b1;
                    end
                    8'h07: irq_flags <= ((irq_flags | is0) & ~ic0) & ~reg_wdata;
                    8'h08: irq_enable <= reg_wdata;
                    8'h09: if (sel == 2'd0) clkdiv0[7:0] <= reg_wdata;
                    8'h0A: if (sel == 2'd0) clkdiv0[15:8] <= reg_wdata;
                    8'h0B: if (sel == 2'd0) pin0 <= reg_wdata;
                    8'h0C: if (sel == 2'd0) pinb0 <= reg_wdata;
                    8'h0D: if (sel == 2'd0) exec0 <= reg_wdata;
                    8'h0E: if (sel == 2'd0) wrap0 <= reg_wdata;
                    8'h0F: if (sel == 2'd0) sh0 <= reg_wdata;
                    8'h10: begin
                        crc_mode_r <= reg_wdata[1:0];
                        if (reg_wdata[7]) crc_clear_host <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    wire _unused = &{ena, host_irq, rx_e0, tx_f0, 1'b0};
endmodule
