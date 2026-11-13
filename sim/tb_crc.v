`timescale 1ns/1ps
`default_nettype none

module tb_crc;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg clear = 0;
    reg [1:0] mode = 0;
    reg din_valid = 0;
    reg din_bit = 0;
    wire [31:0] crc_out;

    crc_unit uut (
        .clk(clk), .rst_n(rst_n), .clear(clear), .mode(mode),
        .din_valid(din_valid), .din_bit(din_bit), .crc_out(crc_out)
    );

    task feed_byte_lsb(input [7:0] b);
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge clk);
                din_valid <= 1;
                din_bit <= b[i];
            end
            @(posedge clk);
            din_valid <= 0;
            @(posedge clk); // allow last bit NBA to settle
        end
    endtask

    task feed_byte_msb(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                @(posedge clk);
                din_valid <= 1;
                din_bit <= b[i];
            end
            @(posedge clk);
            din_valid <= 0;
            @(posedge clk);
        end
    endtask

    integer errors = 0;
    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // CRC-16-CCITT over empty after clear should be 0xFFFF
        mode = 2'd1;
        @(posedge clk); clear <= 1;
        @(posedge clk); clear <= 0;
        @(posedge clk);
        if (crc_out[15:0] !== 16'hFFFF) begin
            $display("FAIL CCITT init %04x", crc_out[15:0]);
            errors = errors + 1;
        end else
            $display("OK CCITT init");

        // Feed '1' ASCII 0x31 MSB-first — known CCITT-FALSE vector "1" => 0x2672? 
        // For poly 0x1021 init 0xFFFF no xorout no reflect, "123456789" => 0x29B1
        // Just check it changes and is deterministic
        feed_byte_msb(8'h31);
        begin : c1
            reg [15:0] a;
            a = crc_out[15:0];
            $display("CCITT after '1' = %04x", a);
            // recompute same
            @(posedge clk); clear <= 1;
            @(posedge clk); clear <= 0;
            feed_byte_msb(8'h31);
            if (crc_out[15:0] !== a) begin
                $display("FAIL nondeterministic");
                errors = errors + 1;
            end else
                $display("OK deterministic");
        end

        // CRC-32 Ethernet: xorout on read path ⇒ clear reads as 0
        mode = 2'd3;
        @(posedge clk); clear <= 1;
        @(posedge clk); clear <= 0;
        @(posedge clk);
        if (crc_out !== 32'h0000_0000) begin
            $display("FAIL CRC32 init(xorout) %08x", crc_out);
            errors = errors + 1;
        end else
            $display("OK CRC32 init (xorout→0)");

        // IEEE check: ASCII "123456789" LSB-first → 0xCBF43926
        begin : eth_vec
            integer ci;
            reg [7:0] msg [0:8];
            msg[0]=8'h31; msg[1]=8'h32; msg[2]=8'h33; msg[3]=8'h34; msg[4]=8'h35;
            msg[5]=8'h36; msg[6]=8'h37; msg[7]=8'h38; msg[8]=8'h39;
            for (ci = 0; ci < 9; ci = ci + 1)
                feed_byte_lsb(msg[ci]);
            if (crc_out !== 32'hCBF43926) begin
                $display("FAIL CRC32 vector %08x expected CBF43926", crc_out);
                errors = errors + 1;
            end else
                $display("OK CRC32 Ethernet vector");
        end

        // CCITT-FALSE "123456789" MSB-first → 0x29B1
        mode = 2'd1;
        @(posedge clk); clear <= 1;
        @(posedge clk); clear <= 0;
        @(posedge clk);
        begin : ccitt_vec
            integer ci;
            reg [7:0] msg [0:8];
            msg[0]=8'h31; msg[1]=8'h32; msg[2]=8'h33; msg[3]=8'h34; msg[4]=8'h35;
            msg[5]=8'h36; msg[6]=8'h37; msg[7]=8'h38; msg[8]=8'h39;
            for (ci = 0; ci < 9; ci = ci + 1)
                feed_byte_msb(msg[ci]);
            if (crc_out[15:0] !== 16'h29B1) begin
                $display("FAIL CCITT vector %04x expected 29B1", crc_out[15:0]);
                errors = errors + 1;
            end else
                $display("OK CCITT vector 0x29B1");
        end

        // USB CRC5 init 0x1F
        mode = 2'd0;
        @(posedge clk); clear <= 1;
        @(posedge clk); clear <= 0;
        @(posedge clk);
        if (crc_out[4:0] !== 5'h1F) begin
            $display("FAIL CRC5 init %02x", crc_out[4:0]);
            errors = errors + 1;
        end else
            $display("OK CRC5 init");

        if (errors == 0) $display("PASS: tb_crc");
        else $display("FAIL: tb_crc %0d", errors);
        $finish;
    end
endmodule
