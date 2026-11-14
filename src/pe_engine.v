/*
 * ProtoCore16 — Protocol Engine (PIO-inspired)
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module pe_engine #(
    parameter integer SM_ID = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    input  wire        imem_we,
    input  wire [4:0]  imem_waddr,
    input  wire [15:0] imem_wdata,

    input  wire [15:0] clkdiv,
    input  wire [2:0]  side_base,
    input  wire [2:0]  side_count,
    input  wire        side_en,
    input  wire [2:0]  out_base,
    input  wire [2:0]  set_base,
    input  wire [2:0]  set_count,
    input  wire [2:0]  in_base,
    input  wire [2:0]  jmp_pin,
    input  wire        autopush,
    input  wire        autopull,
    input  wire [4:0]  push_thresh,
    input  wire [4:0]  pull_thresh,
    input  wire        shift_right,
    input  wire [4:0]  wrap_top,
    input  wire [4:0]  wrap_bottom,

    input  wire [7:0]  gpio_in,
    output reg  [7:0]  gpio_out,
    output reg  [7:0]  gpio_oe,

    output reg         tx_pull_en,
    input  wire [7:0]  tx_data,
    input  wire        tx_empty,
    output reg         rx_push_en,
    output reg  [7:0]  rx_data,
    input  wire        rx_full,

    input  wire [7:0]  irq_in,
    output reg  [7:0]  irq_set,
    output reg  [7:0]  irq_clr,

    output reg         crc_clear,
    output reg  [1:0]  crc_mode,
    output reg         crc_din_valid,
    output reg         crc_din_bit,
    input  wire [31:0] crc_value,

    output reg         nrzi_clear,
    output reg         nrzi_enc_en,
    output reg         nrzi_dec_en,
    output reg         nrzi_din,
    output reg         nrzi_level_in,
    input  wire        nrzi_dout,
    input  wire        nrzi_level_out,

    output wire [4:0]  pc_out,
    output wire        busy,
    output wire [15:0] x_out,
    output wire [15:0] y_out
);
    wire [3:0] sm_id_bits = SM_ID[3:0];

`ifdef PROTOCORE16_USE_IHP_SRAM
    // Optional denser IMEM: behavioral 32×16 stub (swap for PDK macro at harden).
    // Read data is registered (+1 cycle); keep disabled for default sim/bring-up.
    wire [15:0] imem_rdata;
    ihp_sram32x16_bb u_imem (
        .clk(clk), .rst_n(rst_n),
        .we(imem_we), .addr(imem_we ? imem_waddr : pc),
        .wdata(imem_wdata), .rdata(imem_rdata)
    );
`else
    reg [15:0] imem [0:31];
    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            for (ii = 0; ii < 32; ii = ii + 1) imem[ii] <= 16'h9000;
        else if (imem_we)
            imem[imem_waddr] <= imem_wdata;
    end
`endif

    reg [4:0]  pc;
    reg [15:0] x, y;
    reg [31:0] osr, isr;
    reg [5:0]  osr_sc, isr_sc;
    reg [7:0]  delay_left;
    reg [7:0]  div_cnt;
    reg        tick;
    reg        stalled;

    assign pc_out = pc;
    assign busy   = enable & (stalled | (delay_left != 8'd0) | ~tick);
    assign x_out  = x;
    assign y_out  = y;

`ifdef PROTOCORE16_USE_IHP_SRAM
    wire [15:0] instr  = imem_rdata;
`else
    wire [15:0] instr  = imem[pc];
`endif
    wire [3:0]  opcode = instr[15:12];
    wire [3:0]  dlyfld = instr[11:8];
    wire [7:0]  pay    = instr[7:0];

    wire [2:0] scnt = (side_count > 3'd4) ? 3'd4 : side_count;
    wire [3:0] delay_bits = side_en ? (dlyfld & (4'hF >> scnt)) : dlyfld;
    wire [3:0] side_bits  = side_en ? (dlyfld >> (4 - scnt)) : 4'd0;

    // Integer-only divider: tick period = clkdiv[15:8] + 1 system clocks.
    // clkdiv[7:0] is a reserved frac slot (host map / RP2040-like); ignored here —
    // no fractional divider. (& 0) keeps the low byte "read" for lint without effect.
    wire [7:0] div_i = clkdiv[15:8] ^ (clkdiv[7:0] & 8'h00);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 8'd0;
            tick <= 1'b0;
        end else if (!enable) begin
            tick <= 1'b0;
        end else if (div_cnt == div_i) begin
            div_cnt <= 8'd0;
            tick <= 1'b1;
        end else begin
            div_cnt <= div_cnt + 8'd1;
            tick <= 1'b0;
        end
    end

    wire [5:0] push_th = (push_thresh == 5'd0) ? 6'd32 : {1'b0, push_thresh};
    wire [5:0] pull_th = (pull_thresh == 5'd0) ? 6'd32 : {1'b0, pull_thresh};

    wire wait_ok =
        (pay[6:5] == 2'b00) ? (gpio_in[pay[2:0]] == pay[7]) :
        (pay[6:5] == 2'b01) ? (irq_in[pay[2:0]] == pay[7]) :
        (pay[6:5] == 2'b10) ? (gpio_in[jmp_pin] == pay[7]) :
                              (((pay[0] ? rx_full : tx_empty) == pay[7]));

    // scratch for instruction exec (blocking within timestep)
    reg [7:0]  gout, goe, mask;
    reg [4:0]  nbits;
    reg [31:0] tmp;
    reg        adv, do_jmp;
    reg [4:0]  jmp_pc;
    reg [3:0]  si;
    reg [2:0]  sb;
    reg        apply_side;

    function [7:0] make_mask;
        input [2:0] base;
        input [2:0] cnt;
        integer k;
        integer base_i, end_i;
        begin
            make_mask = 8'h00;
            // Explicit widen before integer math (Verilator WIDTHEXPAND).
            base_i = {29'd0, base};
            end_i  = {29'd0, base} + {29'd0, cnt};
            for (k = 0; k < 8; k = k + 1)
                if (k >= base_i && k < end_i)
                    make_mask[k] = 1'b1;
        end
    endfunction

    task automatic sideset_apply;
        input [3:0] sbits;
        input [2:0] sc;
        begin
            if (sc != 3'd0) begin
                mask = make_mask(side_base, sc);
                gout = (gout & ~mask) | (({4'b0, sbits} << side_base) & mask);
                goe  = goe | mask;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 5'd0;
            x <= 16'd0; y <= 16'd0;
            osr <= 32'd0; isr <= 32'd0;
            osr_sc <= 6'd32; isr_sc <= 6'd0;
            delay_left <= 8'd0;
            stalled <= 1'b0;
            gpio_out <= 8'd0; gpio_oe <= 8'd0;
            tx_pull_en <= 1'b0; rx_push_en <= 1'b0; rx_data <= 8'd0;
            irq_set <= 8'd0; irq_clr <= 8'd0;
            crc_clear <= 1'b0; crc_mode <= 2'd0;
            crc_din_valid <= 1'b0; crc_din_bit <= 1'b0;
            nrzi_clear <= 1'b0; nrzi_enc_en <= 1'b0; nrzi_dec_en <= 1'b0;
            nrzi_din <= 1'b0; nrzi_level_in <= 1'b1;
        end else begin
            tx_pull_en <= 1'b0;
            rx_push_en <= 1'b0;
            irq_set <= 8'd0;
            irq_clr <= 8'd0;
            crc_clear <= 1'b0;
            crc_din_valid <= 1'b0;
            nrzi_clear <= 1'b0;
            nrzi_enc_en <= 1'b0;
            nrzi_dec_en <= 1'b0;

            if (enable && tick) begin
                if (delay_left != 8'd0) begin
                    delay_left <= delay_left - 8'd1;
                end else begin
                    gout = gpio_out;
                    goe  = gpio_oe;
                    adv = 1'b0;
                    do_jmp = 1'b0;
                    jmp_pc = pc;
                    apply_side = side_en && (scnt != 3'd0);

                    case (opcode)
                        4'h0: begin // JMP
                            case (pay[7:5])
                                3'd0: do_jmp = 1'b1;
                                3'd1: do_jmp = (x == 16'd0);
                                3'd2: begin do_jmp = (x != 16'd0); x <= x - 16'd1; end
                                3'd3: begin do_jmp = (y != 16'd0); y <= y - 16'd1; end
                                3'd4: do_jmp = (y == 16'd0);
                                3'd5: do_jmp = (x != y);
                                3'd6: do_jmp = gpio_in[jmp_pin];
                                default: do_jmp = !tx_empty;
                            endcase
                            if (do_jmp) jmp_pc = pay[4:0];
                            else adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'h1: begin // WAIT
                            if (wait_ok) begin
                                adv = 1'b1;
                                stalled <= 1'b0;
                                delay_left <= {4'd0, delay_bits};
                            end else stalled <= 1'b1;
                        end

                        4'h2: begin // IN pins (1..8 bits from in_base, same pin repeated for simplify if count>1 use pin0)
                            nbits = (pay[4:0] == 5'd0) ? 5'd8 : pay[4:0];
                            if (nbits > 5'd8) nbits = 5'd8;
                            tmp = isr;
                            if (pay[7:5] == 3'd0) begin
                                for (si = 0; si < 4'd8; si = si + 4'd1) begin
                                    if ({1'b0, si} < nbits) begin
                                        if (shift_right)
                                            tmp = {gpio_in[in_base], tmp[31:1]};
                                        else
                                            tmp = {tmp[30:0], gpio_in[in_base]};
                                    end
                                end
                                isr <= tmp;
                            end else if (pay[7:5] == 3'd3) begin
                                isr <= shift_right ? (isr >> nbits) : (isr << nbits);
                            end
                            if (isr_sc + {1'b0, nbits} > 6'd32) isr_sc <= 6'd32;
                            else isr_sc <= isr_sc + {1'b0, nbits};
                            if (autopush && (isr_sc + {1'b0, nbits} >= push_th) && !rx_full) begin
                                rx_push_en <= 1'b1;
                                rx_data <= shift_right ? tmp[7:0] : tmp[31:24];
                                isr_sc <= 6'd0;
                            end
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'h3: begin // OUT
                            nbits = (pay[4:0] == 5'd0) ? 5'd8 : pay[4:0];
                            if (nbits > 5'd8) nbits = 5'd8;
                            case (pay[7:5])
                                3'd0: begin
                                    mask = make_mask(out_base, nbits[2:0]);
                                    if (shift_right)
                                        // LSB-first: low bits of OSR land on out_base..
                                        gout = (gout & ~mask) | ((osr[7:0] << out_base) & mask);
                                    else
                                        // MSB-first: top bits of OSR; for 1-bit this is OSR[31]
                                        gout = (gout & ~mask) |
                                               (((osr[31:24] >> (8 - nbits[2:0])) << out_base) & mask);
                                    goe = goe | mask;
                                end
                                3'd1: x <= osr[15:0];
                                3'd2: y <= osr[15:0];
                                3'd3: ;
                                3'd4: begin
                                    mask = make_mask(out_base, nbits[2:0]);
                                    if (shift_right)
                                        goe = (goe & ~mask) | ((osr[7:0] << out_base) & mask);
                                    else
                                        goe = (goe & ~mask) | ((osr[31:24] << out_base) & mask);
                                end
                                3'd5: begin do_jmp = 1'b1; jmp_pc = osr[4:0]; end
                                default: ;
                            endcase
                            osr <= shift_right ? (osr >> nbits) : (osr << nbits);
                            if (osr_sc + {1'b0, nbits} > 6'd32) osr_sc <= 6'd32;
                            else osr_sc <= osr_sc + {1'b0, nbits};
                            if (autopull && (osr_sc + {1'b0, nbits} >= pull_th) && !tx_empty) begin
                                tx_pull_en <= 1'b1;
                                osr <= shift_right ? {24'd0, tx_data} : {tx_data, 24'd0};
                                osr_sc <= 6'd0;
                            end
                            if (!do_jmp) adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'h4: begin // PUSH
                            if (rx_full && pay[6]) stalled <= 1'b1;
                            else begin
                                if (!rx_full) begin
                                    rx_push_en <= 1'b1;
                                    rx_data <= shift_right ? isr[7:0] : isr[31:24];
                                end
                                isr <= 32'd0; isr_sc <= 6'd0;
                                stalled <= 1'b0; adv = 1'b1;
                                delay_left <= {4'd0, delay_bits};
                            end
                        end

                        4'h5: begin // PULL
                            if (tx_empty && pay[6]) stalled <= 1'b1;
                            else begin
                                if (!tx_empty) begin
                                    tx_pull_en <= 1'b1;
                                    osr <= shift_right ? {24'd0, tx_data} : {tx_data, 24'd0};
                                end else
                                    osr <= shift_right ? {16'd0, x} : {x, 16'd0};
                                osr_sc <= 6'd0;
                                stalled <= 1'b0; adv = 1'b1;
                                delay_left <= {4'd0, delay_bits};
                            end
                        end

                        4'h6: begin // MOV
                            case (pay[2:0])
                                3'd0: tmp = {16'd0, x};
                                3'd1: tmp = {16'd0, y};
                                3'd2: tmp = {24'd0, gpio_in};
                                3'd3: tmp = 32'd0;
                                3'd4: tmp = isr;
                                3'd5: tmp = osr;
                                3'd6: tmp = crc_value;
                                // status: [3:0]=SM_ID, [4]=enable, [5]=rx_full, [6]=tx_empty
                                default: tmp = {25'd0, tx_empty, rx_full, enable, sm_id_bits};
                            endcase
                            if (pay[4:3] == 2'd1) tmp = ~tmp;
                            if (pay[4:3] == 2'd2)
                                tmp[7:0] = {tmp[0],tmp[1],tmp[2],tmp[3],tmp[4],tmp[5],tmp[6],tmp[7]};
                            case (pay[7:5])
                                3'd0: begin gout = tmp[7:0]; goe = 8'hFF; end
                                3'd1: x <= tmp[15:0];
                                3'd2: y <= tmp[15:0];
                                3'd4: begin isr <= tmp; isr_sc <= 6'd0; end
                                3'd5: begin osr <= tmp; osr_sc <= 6'd0; end
                                3'd7: begin do_jmp = 1'b1; jmp_pc = tmp[4:0]; end
                                default: ;
                            endcase
                            if (!do_jmp) adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'h7: begin // IRQ
                            if (pay[7]) irq_clr[pay[2:0]] <= 1'b1;
                            else irq_set[pay[2:0]] <= 1'b1;
                            if (pay[6] && irq_in[pay[2:0]]) stalled <= 1'b1;
                            else begin
                                stalled <= 1'b0; adv = 1'b1;
                                delay_left <= {4'd0, delay_bits};
                            end
                        end

                        4'h8: begin // SET
                            sb = (set_count == 3'd0) ? 3'd1 : set_count;
                            mask = make_mask(set_base, sb);
                            case (pay[7:5])
                                3'd0: begin
                                    gout = (gout & ~mask) | (({3'b0, pay[4:0]} << set_base) & mask);
                                    goe  = goe | mask;
                                end
                                3'd1: x <= {11'd0, pay[4:0]};
                                3'd2: y <= {11'd0, pay[4:0]};
                                3'd3: goe = (goe & ~mask) | (({3'b0, pay[4:0]} << set_base) & mask);
                                default: ;
                            endcase
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'h9: begin // DELAY/NOP
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'hA: begin // CRC
                            if (pay[5]) crc_clear <= 1'b1;
                            crc_mode <= pay[7:6];
                            crc_din_valid <= 1'b1;
                            crc_din_bit <= osr[0];
                            osr <= {1'b0, osr[31:1]};
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'hB: begin // SIDE immediate (always applies; ignores side_en)
                            sb = (scnt == 3'd0) ? 3'd1 : scnt;
                            mask = make_mask(side_base, sb);
                            gout = (gout & ~mask) | ((pay << side_base) & mask);
                            goe  = goe | mask;
                            apply_side = 1'b0; // already applied
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'hC: begin // ADDI/SUBI
                            if (pay[7]) begin
                                if (pay[6]) y <= y - {10'd0, pay[5:0]};
                                else y <= y + {10'd0, pay[5:0]};
                            end else begin
                                if (pay[6]) x <= x - {10'd0, pay[5:0]};
                                else x <= x + {10'd0, pay[5:0]};
                            end
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'hD: begin // NRZI
                            // Drive post-encode level on the same tick (USB: toggle on 0, hold on 1).
                            // clear alone (or clear+enc) forces J idle and does not consume OSR.
                            if (pay[5]) begin
                                nrzi_clear <= 1'b1;
                                gout[set_base] = 1'b1;
                                goe[set_base] = 1'b1;
                            end
                            if (pay[6] && !pay[5]) begin
                                nrzi_enc_en <= 1'b1;
                                nrzi_din <= osr[0];
                                gout[set_base] = osr[0] ? nrzi_level_out : ~nrzi_level_out;
                                goe[set_base] = 1'b1;
                                osr <= {1'b0, osr[31:1]};
                            end
                            if (pay[7]) begin
                                nrzi_dec_en <= 1'b1;
                                nrzi_level_in <= gpio_in[in_base];
                                isr <= {nrzi_dout, isr[31:1]};
                            end
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end

                        4'hE: begin
                            adv = 1'b1;
                            delay_left <= pay;
                            stalled <= 1'b0;
                            apply_side = 1'b0;
                        end

                        default: begin
                            adv = 1'b1;
                            delay_left <= {4'd0, delay_bits};
                            stalled <= 1'b0;
                        end
                    endcase

                    if ((adv || do_jmp) && apply_side)
                        sideset_apply(side_bits, scnt);

                    if (adv || do_jmp || (opcode == 4'hB) || (opcode == 4'h3) || (opcode == 4'h8) || (opcode == 4'hD) || (opcode == 4'h6)) begin
                        gpio_out <= gout;
                        gpio_oe  <= goe;
                    end

                    if (do_jmp) pc <= jmp_pc;
                    else if (adv) begin
                        if (pc == wrap_top) pc <= wrap_bottom;
                        else pc <= pc + 5'd1;
                    end
                end
            end
        end
    end
endmodule
