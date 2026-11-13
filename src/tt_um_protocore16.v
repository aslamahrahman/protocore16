/*
 * ProtoCore16 — Tiny Tapeout top
 * 4× programmable protocol engines + CRC/NRZI assists
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_protocore16 (
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

    // ---------------- registers ----------------
    reg [3:0]  sm_enable;
    reg [7:0]  sm_sel;         // which SM TX/RX/prog target
    reg [7:0]  prog_off;       // instruction offset 0..31
    reg [7:0]  irq_flags, irq_enable;
    reg [1:0]  crc_mode_r;
    reg        crc_clear_host;
    reg        imem_hi_phase;
    reg [7:0]  imem_lo_latch;

    reg [15:0] clkdiv0, clkdiv1, clkdiv2, clkdiv3;
    reg [7:0]  pin0, pin1, pin2, pin3;     // side_base[7:5], set_base[4:2], set_count[1:0]
    reg [7:0]  pinb0, pinb1, pinb2, pinb3; // out_base[7:5], in_base[4:2], side_count[1:0]
    reg [7:0]  exec0, exec1, exec2, exec3; // side_en, autopush, autopull, shift_right, jmp_pin[2:0]
    reg [7:0]  wrap0, wrap1, wrap2, wrap3; // wrap_top[7:4], wrap_bottom[3:0] (nibble — max 15; hi programs use wrap 0)
    reg [7:0]  sh0, sh1, sh2, sh3;         // push_th[7:4], pull_th[3:0]

    reg        imem_we0, imem_we1, imem_we2, imem_we3;
    reg [4:0]  imem_waddr;
    reg [15:0] imem_wdata;

    // FIFOs
    reg        tx_wr0, tx_wr1, tx_wr2, tx_wr3;
    reg [7:0]  tx_wdata;
    reg        rx_rd0, rx_rd1, rx_rd2, rx_rd3;

    wire [7:0] tx_d0, tx_d1, tx_d2, tx_d3;
    wire       tx_e0, tx_e1, tx_e2, tx_e3;
    wire       tx_f0, tx_f1, tx_f2, tx_f3;
    wire [2:0] tx_l0, tx_l1, tx_l2, tx_l3;

    wire [7:0] rx_q0, rx_q1, rx_q2, rx_q3;
    wire       rx_e0, rx_e1, rx_e2, rx_e3;
    wire       rx_f0, rx_f1, rx_f2, rx_f3;
    wire [2:0] rx_l0, rx_l1, rx_l2, rx_l3;

    wire       tx_pull0, tx_pull1, tx_pull2, tx_pull3;
    wire       rx_push0, rx_push1, rx_push2, rx_push3;
    wire [7:0] rx_d0, rx_d1, rx_d2, rx_d3;

    fifo4x8 u_tx0 (.clk(clk), .rst_n(rst_n), .wr_en(tx_wr0), .wr_data(tx_wdata),
                   .rd_en(tx_pull0), .rd_data(tx_d0), .empty(tx_e0), .full(tx_f0), .level(tx_l0));
    fifo4x8 u_tx1 (.clk(clk), .rst_n(rst_n), .wr_en(tx_wr1), .wr_data(tx_wdata),
                   .rd_en(tx_pull1), .rd_data(tx_d1), .empty(tx_e1), .full(tx_f1), .level(tx_l1));
    fifo4x8 u_tx2 (.clk(clk), .rst_n(rst_n), .wr_en(tx_wr2), .wr_data(tx_wdata),
                   .rd_en(tx_pull2), .rd_data(tx_d2), .empty(tx_e2), .full(tx_f2), .level(tx_l2));
    fifo4x8 u_tx3 (.clk(clk), .rst_n(rst_n), .wr_en(tx_wr3), .wr_data(tx_wdata),
                   .rd_en(tx_pull3), .rd_data(tx_d3), .empty(tx_e3), .full(tx_f3), .level(tx_l3));

    fifo4x8 u_rx0 (.clk(clk), .rst_n(rst_n), .wr_en(rx_push0), .wr_data(rx_d0),
                   .rd_en(rx_rd0), .rd_data(rx_q0), .empty(rx_e0), .full(rx_f0), .level(rx_l0));
    fifo4x8 u_rx1 (.clk(clk), .rst_n(rst_n), .wr_en(rx_push1), .wr_data(rx_d1),
                   .rd_en(rx_rd1), .rd_data(rx_q1), .empty(rx_e1), .full(rx_f1), .level(rx_l1));
    fifo4x8 u_rx2 (.clk(clk), .rst_n(rst_n), .wr_en(rx_push2), .wr_data(rx_d2),
                   .rd_en(rx_rd2), .rd_data(rx_q2), .empty(rx_e2), .full(rx_f2), .level(rx_l2));
    fifo4x8 u_rx3 (.clk(clk), .rst_n(rst_n), .wr_en(rx_push3), .wr_data(rx_d3),
                   .rd_en(rx_rd3), .rd_data(rx_q3), .empty(rx_e3), .full(rx_f3), .level(rx_l3));

    // GPIO / IRQ / assists from SMs
    wire [7:0] go0, go1, go2, go3;
    wire [7:0] ge0, ge1, ge2, ge3;
    wire [7:0] is0, is1, is2, is3;
    wire [7:0] ic0, ic1, ic2, ic3;
    wire [4:0] pc0, pc1, pc2, pc3;
    wire       bz0, bz1, bz2, bz3;

    wire [3:0] crc_clear_sm, crc_dv;
    wire [3:0] crc_db;
    wire [1:0] cm0, cm1, cm2, cm3;
    wire [3:0] nz_c, nz_e, nz_d, nz_di, nz_li;
    wire [31:0] crc_out;
    wire nrzi_dout, nrzi_level_out;

    wire crc_clear = crc_clear_host | (|crc_clear_sm);
    wire crc_din_valid = |crc_dv;
    wire crc_din_bit = crc_dv[0] ? crc_db[0] : crc_dv[1] ? crc_db[1] : crc_dv[2] ? crc_db[2] : crc_db[3];
    wire [1:0] crc_mode = crc_dv[0] ? cm0 : crc_dv[1] ? cm1 : crc_dv[2] ? cm2 : crc_dv[3] ? cm3 : crc_mode_r;

    wire nrzi_clear = |nz_c;
    wire nrzi_enc_en = |nz_e;
    wire nrzi_dec_en = |nz_d;
    wire nrzi_din = nz_e[0] ? nz_di[0] : nz_e[1] ? nz_di[1] : nz_e[2] ? nz_di[2] : nz_di[3];
    wire nrzi_level_in = nz_d[0] ? nz_li[0] : nz_d[1] ? nz_li[1] : nz_d[2] ? nz_li[2] : nz_li[3];

    crc_unit u_crc (
        .clk(clk), .rst_n(rst_n), .clear(crc_clear), .mode(crc_mode),
        .din_valid(crc_din_valid), .din_bit(crc_din_bit), .crc_out(crc_out)
    );
    nrzi_unit u_nrzi (
        .clk(clk), .rst_n(rst_n), .clear(nrzi_clear),
        .enc_en(nrzi_enc_en), .dec_en(nrzi_dec_en),
        .din(nrzi_din), .level_in(nrzi_level_in),
        .dout(nrzi_dout), .level_out(nrzi_level_out)
    );

    // helpers to unpack config
    `define UNPACK_SM(idx, pin, pinb, exec, wrap, sh, clkd, en, iwe) \
        pe_engine #(.SM_ID(idx)) u_pe``idx ( \
            .clk(clk), .rst_n(rst_n), .enable(en), \
            .imem_we(iwe), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata), \
            .clkdiv(clkd), \
            .side_base(pin[7:5]), .side_count({1'b0, pinb[1:0]}), .side_en(exec[7]), \
            .out_base(pinb[7:5]), .set_base(pin[4:2]), .set_count({1'b0, pin[1:0]}), \
            .in_base(pinb[4:2]), .jmp_pin(exec[2:0]), \
            .autopush(exec[6]), .autopull(exec[5]), \
            .push_thresh({1'b0, sh[7:4]}), .pull_thresh({1'b0, sh[3:0]}), \
            .shift_right(exec[4]), \
            .wrap_top({1'b0, wrap[7:4]}), .wrap_bottom({1'b0, wrap[3:0]}), \
            .gpio_in(uio_in), .gpio_out(go``idx), .gpio_oe(ge``idx), \
            .tx_pull_en(tx_pull``idx), .tx_data(tx_d``idx), .tx_empty(tx_e``idx), \
            .rx_push_en(rx_push``idx), .rx_data(rx_d``idx), .rx_full(rx_f``idx), \
            .irq_in(irq_flags), .irq_set(is``idx), .irq_clr(ic``idx), \
            .crc_clear(crc_clear_sm[idx]), .crc_mode(cm``idx), \
            .crc_din_valid(crc_dv[idx]), .crc_din_bit(crc_db[idx]), .crc_value(crc_out), \
            .nrzi_clear(nz_c[idx]), .nrzi_enc_en(nz_e[idx]), .nrzi_dec_en(nz_d[idx]), \
            .nrzi_din(nz_di[idx]), .nrzi_level_in(nz_li[idx]), \
            .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out), \
            .pc_out(pc``idx), .busy(bz``idx), .x_out(), .y_out() \
        );

    // Manual instances (macros with `` can be fragile) — expand:
    pe_engine #(.SM_ID(0)) u_pe0 (
        .clk(clk), .rst_n(rst_n), .enable(sm_enable[0]),
        .imem_we(imem_we0), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(clkdiv0), .side_base(pin0[7:5]), .side_count({1'b0,pinb0[1:0]}), .side_en(exec0[7]),
        .out_base(pinb0[7:5]), .set_base(pin0[4:2]), .set_count({1'b0,pin0[1:0]}),
        .in_base(pinb0[4:2]), .jmp_pin(exec0[2:0]),
        .autopush(exec0[6]), .autopull(exec0[5]),
        .push_thresh({1'b0,sh0[7:4]}), .pull_thresh({1'b0,sh0[3:0]}), .shift_right(exec0[4]),
        .wrap_top({1'b0,wrap0[7:4]}), .wrap_bottom({1'b0,wrap0[3:0]}),
        .gpio_in(uio_in), .gpio_out(go0), .gpio_oe(ge0),
        .tx_pull_en(tx_pull0), .tx_data(tx_d0), .tx_empty(tx_e0),
        .rx_push_en(rx_push0), .rx_data(rx_d0), .rx_full(rx_f0),
        .irq_in(irq_flags), .irq_set(is0), .irq_clr(ic0),
        .crc_clear(crc_clear_sm[0]), .crc_mode(cm0), .crc_din_valid(crc_dv[0]), .crc_din_bit(crc_db[0]), .crc_value(crc_out),
        .nrzi_clear(nz_c[0]), .nrzi_enc_en(nz_e[0]), .nrzi_dec_en(nz_d[0]),
        .nrzi_din(nz_di[0]), .nrzi_level_in(nz_li[0]), .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out),
        .pc_out(pc0), .busy(bz0), .x_out(), .y_out()
    );
    pe_engine #(.SM_ID(1)) u_pe1 (
        .clk(clk), .rst_n(rst_n), .enable(sm_enable[1]),
        .imem_we(imem_we1), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(clkdiv1), .side_base(pin1[7:5]), .side_count({1'b0,pinb1[1:0]}), .side_en(exec1[7]),
        .out_base(pinb1[7:5]), .set_base(pin1[4:2]), .set_count({1'b0,pin1[1:0]}),
        .in_base(pinb1[4:2]), .jmp_pin(exec1[2:0]),
        .autopush(exec1[6]), .autopull(exec1[5]),
        .push_thresh({1'b0,sh1[7:4]}), .pull_thresh({1'b0,sh1[3:0]}), .shift_right(exec1[4]),
        .wrap_top({1'b0,wrap1[7:4]}), .wrap_bottom({1'b0,wrap1[3:0]}),
        .gpio_in(uio_in), .gpio_out(go1), .gpio_oe(ge1),
        .tx_pull_en(tx_pull1), .tx_data(tx_d1), .tx_empty(tx_e1),
        .rx_push_en(rx_push1), .rx_data(rx_d1), .rx_full(rx_f1),
        .irq_in(irq_flags), .irq_set(is1), .irq_clr(ic1),
        .crc_clear(crc_clear_sm[1]), .crc_mode(cm1), .crc_din_valid(crc_dv[1]), .crc_din_bit(crc_db[1]), .crc_value(crc_out),
        .nrzi_clear(nz_c[1]), .nrzi_enc_en(nz_e[1]), .nrzi_dec_en(nz_d[1]),
        .nrzi_din(nz_di[1]), .nrzi_level_in(nz_li[1]), .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out),
        .pc_out(pc1), .busy(bz1), .x_out(), .y_out()
    );
    pe_engine #(.SM_ID(2)) u_pe2 (
        .clk(clk), .rst_n(rst_n), .enable(sm_enable[2]),
        .imem_we(imem_we2), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(clkdiv2), .side_base(pin2[7:5]), .side_count({1'b0,pinb2[1:0]}), .side_en(exec2[7]),
        .out_base(pinb2[7:5]), .set_base(pin2[4:2]), .set_count({1'b0,pin2[1:0]}),
        .in_base(pinb2[4:2]), .jmp_pin(exec2[2:0]),
        .autopush(exec2[6]), .autopull(exec2[5]),
        .push_thresh({1'b0,sh2[7:4]}), .pull_thresh({1'b0,sh2[3:0]}), .shift_right(exec2[4]),
        .wrap_top({1'b0,wrap2[7:4]}), .wrap_bottom({1'b0,wrap2[3:0]}),
        .gpio_in(uio_in), .gpio_out(go2), .gpio_oe(ge2),
        .tx_pull_en(tx_pull2), .tx_data(tx_d2), .tx_empty(tx_e2),
        .rx_push_en(rx_push2), .rx_data(rx_d2), .rx_full(rx_f2),
        .irq_in(irq_flags), .irq_set(is2), .irq_clr(ic2),
        .crc_clear(crc_clear_sm[2]), .crc_mode(cm2), .crc_din_valid(crc_dv[2]), .crc_din_bit(crc_db[2]), .crc_value(crc_out),
        .nrzi_clear(nz_c[2]), .nrzi_enc_en(nz_e[2]), .nrzi_dec_en(nz_d[2]),
        .nrzi_din(nz_di[2]), .nrzi_level_in(nz_li[2]), .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out),
        .pc_out(pc2), .busy(bz2), .x_out(), .y_out()
    );
    pe_engine #(.SM_ID(3)) u_pe3 (
        .clk(clk), .rst_n(rst_n), .enable(sm_enable[3]),
        .imem_we(imem_we3), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .clkdiv(clkdiv3), .side_base(pin3[7:5]), .side_count({1'b0,pinb3[1:0]}), .side_en(exec3[7]),
        .out_base(pinb3[7:5]), .set_base(pin3[4:2]), .set_count({1'b0,pin3[1:0]}),
        .in_base(pinb3[4:2]), .jmp_pin(exec3[2:0]),
        .autopush(exec3[6]), .autopull(exec3[5]),
        .push_thresh({1'b0,sh3[7:4]}), .pull_thresh({1'b0,sh3[3:0]}), .shift_right(exec3[4]),
        .wrap_top({1'b0,wrap3[7:4]}), .wrap_bottom({1'b0,wrap3[3:0]}),
        .gpio_in(uio_in), .gpio_out(go3), .gpio_oe(ge3),
        .tx_pull_en(tx_pull3), .tx_data(tx_d3), .tx_empty(tx_e3),
        .rx_push_en(rx_push3), .rx_data(rx_d3), .rx_full(rx_f3),
        .irq_in(irq_flags), .irq_set(is3), .irq_clr(ic3),
        .crc_clear(crc_clear_sm[3]), .crc_mode(cm3), .crc_din_valid(crc_dv[3]), .crc_din_bit(crc_db[3]), .crc_value(crc_out),
        .nrzi_clear(nz_c[3]), .nrzi_enc_en(nz_e[3]), .nrzi_dec_en(nz_d[3]),
        .nrzi_din(nz_di[3]), .nrzi_level_in(nz_li[3]), .nrzi_dout(nrzi_dout), .nrzi_level_out(nrzi_level_out),
        .pc_out(pc3), .busy(bz3), .x_out(), .y_out()
    );

    // GPIO merge
    reg [7:0] gout, goe;
    integer gi;
    always @(*) begin
        goe = ge0 | ge1 | ge2 | ge3;
        gout = 8'd0;
        for (gi = 0; gi < 8; gi = gi + 1) begin
            if (ge0[gi]) gout[gi] = go0[gi];
            else if (ge1[gi]) gout[gi] = go1[gi];
            else if (ge2[gi]) gout[gi] = go2[gi];
            else if (ge3[gi]) gout[gi] = go3[gi];
        end
    end
    assign uio_out = gout;
    assign uio_oe  = goe;

    // Register map
    // 0x00 CTRL: [3:0] SM enable
    // 0x01 STATUS: [3:0] busy, [7:4] tx_empty
    // 0x02 SMSEL
    // 0x03 PROG_OFF
    // 0x04 PROG_DATA (write LO then HI auto-packs; autoinc PROG_OFF after HI)
    // 0x05 TXFIFO
    // 0x06 RXFIFO
    // 0x07 IRQ_FLAGS (W1C)
    // 0x08 IRQ_ENABLE
    // 0x09 CLKDIV_LO
    // 0x0A CLKDIV_HI
    // 0x0B PINCTRL
    // 0x0C PINCTRL2
    // 0x0D EXECCTRL
    // 0x0E WRAPCFG
    // 0x0F SHIFTCTRL
    // 0x10 CRC_CTRL [1:0] mode [7]=clear pulse
    // 0x11 CRC_BYTE0
    // 0x12 CRC_BYTE1
    // 0x13 PC_VIEW (selected SM)
    // 0x14 RX_LEVEL / TX_LEVEL pack

    wire [1:0] sel = sm_sel[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_enable <= 4'd0;
            sm_sel <= 8'd0;
            prog_off <= 8'd0;
            irq_enable <= 8'd0;
            crc_mode_r <= 2'd0;
            crc_clear_host <= 1'b0;
            imem_hi_phase <= 1'b0;
            imem_lo_latch <= 8'd0;
            imem_we0 <= 1'b0; imem_we1 <= 1'b0; imem_we2 <= 1'b0; imem_we3 <= 1'b0;
            imem_waddr <= 5'd0; imem_wdata <= 16'd0;
            tx_wr0 <= 1'b0; tx_wr1 <= 1'b0; tx_wr2 <= 1'b0; tx_wr3 <= 1'b0;
            rx_rd0 <= 1'b0; rx_rd1 <= 1'b0; rx_rd2 <= 1'b0; rx_rd3 <= 1'b0;
            tx_wdata <= 8'd0;
            clkdiv0 <= 16'd0; clkdiv1 <= 16'd0; clkdiv2 <= 16'd0; clkdiv3 <= 16'd0;
            pin0 <= 8'd0; pin1 <= 8'd0; pin2 <= 8'd0; pin3 <= 8'd0;
            pinb0 <= 8'd0; pinb1 <= 8'd0; pinb2 <= 8'd0; pinb3 <= 8'd0;
            exec0 <= 8'h10; exec1 <= 8'h10; exec2 <= 8'h10; exec3 <= 8'h10; // shift_right=1
            wrap0 <= 8'hF0; wrap1 <= 8'hF0; wrap2 <= 8'hF0; wrap3 <= 8'hF0;
            sh0 <= 8'h88; sh1 <= 8'h88; sh2 <= 8'h88; sh3 <= 8'h88;
            irq_flags <= 8'd0;
            reg_rdata <= 8'd0;
        end else begin
            imem_we0 <= 1'b0; imem_we1 <= 1'b0; imem_we2 <= 1'b0; imem_we3 <= 1'b0;
            tx_wr0 <= 1'b0; tx_wr1 <= 1'b0; tx_wr2 <= 1'b0; tx_wr3 <= 1'b0;
            rx_rd0 <= 1'b0; rx_rd1 <= 1'b0; rx_rd2 <= 1'b0; rx_rd3 <= 1'b0;
            crc_clear_host <= 1'b0;

            // SM IRQ set/clear merge (before optional host W1C)
            irq_flags <= (irq_flags | is0 | is1 | is2 | is3) & ~(ic0 | ic1 | ic2 | ic3);

            // default read data
            case (reg_addr)
                8'h00: reg_rdata <= {4'd0, sm_enable};
                8'h01: reg_rdata <= {tx_e3, tx_e2, tx_e1, tx_e0, bz3, bz2, bz1, bz0};
                8'h02: reg_rdata <= sm_sel;
                8'h03: reg_rdata <= prog_off;
                8'h06: begin
                    case (sel)
                        2'd0: reg_rdata <= rx_q0;
                        2'd1: reg_rdata <= rx_q1;
                        2'd2: reg_rdata <= rx_q2;
                        default: reg_rdata <= rx_q3;
                    endcase
                end
                8'h07: reg_rdata <= irq_flags;
                8'h08: reg_rdata <= irq_enable;
                8'h09: begin
                    case (sel)
                        2'd0: reg_rdata <= clkdiv0[7:0];
                        2'd1: reg_rdata <= clkdiv1[7:0];
                        2'd2: reg_rdata <= clkdiv2[7:0];
                        default: reg_rdata <= clkdiv3[7:0];
                    endcase
                end
                8'h0A: begin
                    case (sel)
                        2'd0: reg_rdata <= clkdiv0[15:8];
                        2'd1: reg_rdata <= clkdiv1[15:8];
                        2'd2: reg_rdata <= clkdiv2[15:8];
                        default: reg_rdata <= clkdiv3[15:8];
                    endcase
                end
                8'h0B: begin
                    case (sel) 2'd0: reg_rdata <= pin0; 2'd1: reg_rdata <= pin1;
                               2'd2: reg_rdata <= pin2; default: reg_rdata <= pin3; endcase
                end
                8'h0C: begin
                    case (sel) 2'd0: reg_rdata <= pinb0; 2'd1: reg_rdata <= pinb1;
                               2'd2: reg_rdata <= pinb2; default: reg_rdata <= pinb3; endcase
                end
                8'h0D: begin
                    case (sel) 2'd0: reg_rdata <= exec0; 2'd1: reg_rdata <= exec1;
                               2'd2: reg_rdata <= exec2; default: reg_rdata <= exec3; endcase
                end
                8'h0E: begin
                    case (sel) 2'd0: reg_rdata <= wrap0; 2'd1: reg_rdata <= wrap1;
                               2'd2: reg_rdata <= wrap2; default: reg_rdata <= wrap3; endcase
                end
                8'h0F: begin
                    case (sel) 2'd0: reg_rdata <= sh0; 2'd1: reg_rdata <= sh1;
                               2'd2: reg_rdata <= sh2; default: reg_rdata <= sh3; endcase
                end
                8'h10: reg_rdata <= {6'd0, crc_mode_r};
                8'h11: reg_rdata <= crc_out[7:0];
                8'h12: reg_rdata <= crc_out[15:8];
                8'h13: begin
                    case (sel) 2'd0: reg_rdata <= {3'd0, pc0}; 2'd1: reg_rdata <= {3'd0, pc1};
                               2'd2: reg_rdata <= {3'd0, pc2}; default: reg_rdata <= {3'd0, pc3}; endcase
                end
                8'h14: begin
                    case (sel)
                        2'd0: reg_rdata <= {1'b0, rx_l0, 1'b0, tx_l0};
                        2'd1: reg_rdata <= {1'b0, rx_l1, 1'b0, tx_l1};
                        2'd2: reg_rdata <= {1'b0, rx_l2, 1'b0, tx_l2};
                        default: reg_rdata <= {1'b0, rx_l3, 1'b0, tx_l3};
                    endcase
                end
                8'h15: reg_rdata <= crc_out[23:16];
                8'h16: reg_rdata <= crc_out[31:24];
                default: reg_rdata <= 8'hA5;
            endcase

            if (reg_re && reg_addr == 8'h06) begin
                case (sel)
                    2'd0: rx_rd0 <= 1'b1;
                    2'd1: rx_rd1 <= 1'b1;
                    2'd2: rx_rd2 <= 1'b1;
                    default: rx_rd3 <= 1'b1;
                endcase
            end

            if (reg_we) begin
                case (reg_addr)
                    8'h00: sm_enable <= reg_wdata[3:0];
                    8'h02: sm_sel <= reg_wdata;
                    8'h03: begin prog_off <= reg_wdata; imem_hi_phase <= 1'b0; end
                    8'h04: begin
                        if (!imem_hi_phase) begin
                            imem_lo_latch <= reg_wdata;
                            imem_hi_phase <= 1'b1;
                        end else begin
                            imem_waddr <= prog_off[4:0];
                            imem_wdata <= {reg_wdata, imem_lo_latch};
                            case (sel)
                                2'd0: imem_we0 <= 1'b1;
                                2'd1: imem_we1 <= 1'b1;
                                2'd2: imem_we2 <= 1'b1;
                                default: imem_we3 <= 1'b1;
                            endcase
                            imem_hi_phase <= 1'b0;
                            prog_off <= prog_off + 8'd1;
                        end
                    end
                    8'h05: begin
                        tx_wdata <= reg_wdata;
                        case (sel)
                            2'd0: tx_wr0 <= 1'b1;
                            2'd1: tx_wr1 <= 1'b1;
                            2'd2: tx_wr2 <= 1'b1;
                            default: tx_wr3 <= 1'b1;
                        endcase
                    end
                    8'h07: irq_flags <= ((irq_flags | is0 | is1 | is2 | is3) & ~(ic0 | ic1 | ic2 | ic3)) & ~reg_wdata;
                    8'h08: irq_enable <= reg_wdata;
                    8'h09: case (sel)
                        2'd0: clkdiv0[7:0] <= reg_wdata;
                        2'd1: clkdiv1[7:0] <= reg_wdata;
                        2'd2: clkdiv2[7:0] <= reg_wdata;
                        default: clkdiv3[7:0] <= reg_wdata;
                    endcase
                    8'h0A: case (sel)
                        2'd0: clkdiv0[15:8] <= reg_wdata;
                        2'd1: clkdiv1[15:8] <= reg_wdata;
                        2'd2: clkdiv2[15:8] <= reg_wdata;
                        default: clkdiv3[15:8] <= reg_wdata;
                    endcase
                    8'h0B: case (sel)
                        2'd0: pin0 <= reg_wdata; 2'd1: pin1 <= reg_wdata;
                        2'd2: pin2 <= reg_wdata; default: pin3 <= reg_wdata;
                    endcase
                    8'h0C: case (sel)
                        2'd0: pinb0 <= reg_wdata; 2'd1: pinb1 <= reg_wdata;
                        2'd2: pinb2 <= reg_wdata; default: pinb3 <= reg_wdata;
                    endcase
                    8'h0D: case (sel)
                        2'd0: exec0 <= reg_wdata; 2'd1: exec1 <= reg_wdata;
                        2'd2: exec2 <= reg_wdata; default: exec3 <= reg_wdata;
                    endcase
                    8'h0E: case (sel)
                        2'd0: wrap0 <= reg_wdata; 2'd1: wrap1 <= reg_wdata;
                        2'd2: wrap2 <= reg_wdata; default: wrap3 <= reg_wdata;
                    endcase
                    8'h0F: case (sel)
                        2'd0: sh0 <= reg_wdata; 2'd1: sh1 <= reg_wdata;
                        2'd2: sh2 <= reg_wdata; default: sh3 <= reg_wdata;
                    endcase
                    8'h10: begin
                        crc_mode_r <= reg_wdata[1:0];
                        if (reg_wdata[7]) crc_clear_host <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // IRQ W1C fix: do not race with SM sets — apply W1C in same block via flag
    // (simplified: write to 0x07 clears bits)

    wire _unused = &{ena, host_irq, rx_e0, rx_e1, rx_e2, rx_e3, tx_f0, tx_f1, tx_f2, tx_f3, 1'b0};
endmodule
