/*
 * ProtoCore16 — Muse Lab iCESugar (iCE40UP5K-SG48) board top
 *
 * Instantiates tt_um_protocore16_fpga1 (1× PE cut — full 4-PE ASIC RTL
 * does not fit UP5K) and maps clk/rst, host SPI (ui/uo), GPIO (uio) →
 * PMOD / DIP / RGB.
 *
 * Target: classic iCESugar v1.5 (UP5K), NOT nano (LP1K) or pro (ECP5).
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module icesugar_protocore16_top (
    input  wire       clk_12m,     // iCELink MCO → FPGA pin 35
    input  wire       rst_btn_n,   // DIP SW0 (PMOD4_0) pin 21; closed = reset
    // Host SPI Mode-0 on PMOD2 (Raspberry Pi Pico master; FT232H optional)
    input  wire       spi_sclk,    // PMOD2 A0 → ui[0]
    input  wire       spi_mosi,    // PMOD2 A1 → ui[1]
    input  wire       spi_cs_n,    // PMOD2 A2 → ui[2]
    output wire       spi_miso,    // PMOD2 A3 ← uo[0]
    output wire       spi_irq,     // PMOD2 B0 ← uo[1]
    // Protocol GPIO on PMOD3 (bidirectional)
    inout  wire [7:0] gpio,        // uio[7:0]
    // On-board RGB (SB_RGBA_DRV hard IP)
    output wire       led_r,
    output wire       led_g,
    output wire       led_b
);
    // -------- soft POR + DIP hold (FPGA pull-up: missing DIP floats high = run) --------
    wire rst_btn_n_i;
    SB_IO #(
        .PIN_TYPE(6'b0000_01),
        .PULLUP(1'b1)
    ) io_rst (
        .PACKAGE_PIN(rst_btn_n),
        .D_IN_0(rst_btn_n_i)
    );

    reg [15:0] por_cnt = 16'd0;
    wire       por_done = &por_cnt;
    always @(posedge clk_12m) begin
        if (!por_done)
            por_cnt <= por_cnt + 16'd1;
    end
    wire rst_n = por_done & rst_btn_n_i;

    // -------- SPI inputs with pull-ups (CS idle high) --------
    wire sclk_i, mosi_i, csn_i;
    SB_IO #(
        .PIN_TYPE(6'b0000_01),
        .PULLUP(1'b1)
    ) io_sclk (
        .PACKAGE_PIN(spi_sclk),
        .D_IN_0(sclk_i)
    );
    SB_IO #(
        .PIN_TYPE(6'b0000_01),
        .PULLUP(1'b1)
    ) io_mosi (
        .PACKAGE_PIN(spi_mosi),
        .D_IN_0(mosi_i)
    );
    SB_IO #(
        .PIN_TYPE(6'b0000_01),
        .PULLUP(1'b1)
    ) io_csn (
        .PACKAGE_PIN(spi_cs_n),
        .D_IN_0(csn_i)
    );

    // -------- bidirectional GPIO with OE --------
    wire [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_gpio
            SB_IO #(
                .PIN_TYPE(6'b1010_01),
                .PULLUP(1'b1)
            ) io_gpio (
                .PACKAGE_PIN(gpio[gi]),
                .OUTPUT_ENABLE(uio_oe[gi]),
                .D_OUT_0(uio_out[gi]),
                .D_IN_0(uio_in[gi])
            );
        end
    endgenerate

    // -------- ProtoCore16 (1-PE FPGA cut; same SPI map as TT top) --------
    wire [7:0] ui_in  = {5'b0, csn_i, mosi_i, sclk_i};
    wire [7:0] uo_out;

    tt_um_protocore16_fpga1 u_core (
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(1'b1),
        .clk(clk_12m),
        .rst_n(rst_n)
    );

    assign spi_miso = uo_out[0];
    assign spi_irq  = uo_out[1];

    // -------- RGB smoke: green tracks UART TX (uio[0]) when driven --------
    // Idle UART TX is high → LED off. Start/data lows flash the LED.
    wire tx_drive = uio_oe[0];
    wire tx_level = uio_out[0];
    wire led_pwm_g = tx_drive & ~tx_level;
    wire led_pwm_r = 1'b0;
    wire led_pwm_b = ~rst_n; // blue while held in reset

    SB_RGBA_DRV #(
        .CURRENT_MODE("0b1"),
        .RGB0_CURRENT("0b000001"),
        .RGB1_CURRENT("0b000001"),
        .RGB2_CURRENT("0b000001")
    ) u_rgb (
        .CURREN(1'b1),
        .RGBLEDEN(1'b1),
        .RGB0PWM(led_pwm_b), // pin 39 = Blue
        .RGB1PWM(led_pwm_r), // pin 40 = Red
        .RGB2PWM(led_pwm_g), // pin 41 = Green
        .RGB0(led_b),
        .RGB1(led_r),
        .RGB2(led_g)
    );
endmodule
