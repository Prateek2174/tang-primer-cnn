module i2c_bitbang_cam #(
    parameter CLK_FREQ  = 50000000,
    parameter I2C_FREQ  = 100000,
    parameter CMD_COUNT = 257
)(
    input  wire clk,
    input  wire rst_n,

    input  wire cam_clk,

    output reg  cam_done,

    output reg  busy,
    output reg  done,
    output reg  error,

    output reg  sda_1,
    output reg  scl_1,
    input  wire sda_in, // senses the real physical SDA line for ACK detection --
                         // sda_1 alone is output-only from this module's own
                         // perspective, so the caller must tap the same net
                         // (e.g. sda_in(cam_sda), sda_1(cam_sda) in top.v)

    output reg  cam_pwdn,
    output reg  cam_rst_n,
    output wire cam_xvclk
);

    localparam WAIT_5MS = CLK_FREQ / 1000 * 5;
    localparam HALF_PERIOD = CLK_FREQ / (I2C_FREQ * 2);
    localparam WAIT_1MS    = CLK_FREQ / 1000;
    localparam WAIT_20MS   = CLK_FREQ / 50;
    localparam WAIT_10MS   = CLK_FREQ / 100;

    // ROM output: one 32-bit command word at the current address
    wire [31:0] cmd_phase;

    OV5640LUT camROM (
        .addr(cmd_index),
        .data(cmd_phase)
    );

    //========================================================
    // FSM states
    //========================================================
    localparam ST_POWER_START  = 4'd0;
    localparam ST_DELAY_5MS    = 4'd1;
    localparam ST_DELAY_1MS    = 4'd2;
    localparam ST_DELAY_20MS   = 4'd3;
    localparam ST_HOLD_LOW     = 4'd4;
    localparam ST_WAIT_TRIGGER = 4'd5;
    localparam ST_RELEASE      = 4'd6;
    localparam ST_WAIT_5MS     = 4'd7;
    localparam ST_LOAD_CMD     = 4'd8;
    localparam ST_START_COND   = 4'd9;
    localparam ST_SEND_BYTE    = 4'd10;
    localparam ST_ACK_BIT      = 4'd11;
    localparam ST_STOP_COND    = 4'd12;
    localparam ST_NEXT_CMD     = 4'd13;
    localparam ST_DONE         = 4'd14;

    reg [3:0]  state;
    reg [4:0]  bit_index;
    reg [1:0]  byte_index;
    reg [8:0]  cmd_index;
    reg [15:0] clk_cnt;
    reg [7:0]  curr_byte;
    reg [3:0]  retry_count; // caps retries so a persistently-NACK'd command
                             // can't hang the whole init sequence forever
    reg        ack_fail;
    reg [31:0] wait_cnt;
    reg        xclk_en;

    assign cam_xvclk = xclk_en ? cam_clk : 1'b0;

    //========================================================
    // Main FSM
    //========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_POWER_START;
            wait_cnt   <= 32'd0;
            clk_cnt    <= 16'd0;
            bit_index  <= 5'd7;
            byte_index <= 2'd0;
            cmd_index  <= 9'd0;
            curr_byte  <= 8'd0;
            ack_fail   <= 1'b0;
            retry_count <= 4'd0;

            busy       <= 1'b1;
            done       <= 1'b0;
            error      <= 1'b0;
            cam_done   <= 1'b0;

            sda_1      <= 1'b1;
            scl_1      <= 1'b1;
            cam_pwdn   <= 1'b1;
            cam_rst_n  <= 1'b0;
            xclk_en    <= 1'b0;
        end
        else begin
            case (state)

                //============================================
                // Power-up sequence
                //============================================
                ST_POWER_START: begin
                    cam_pwdn  <= 1'b1;
                    cam_rst_n <= 1'b0;
                    wait_cnt  <= 32'd0;
                    state     <= ST_DELAY_5MS;
                end

                ST_DELAY_5MS: begin
                    if (wait_cnt >= WAIT_5MS - 1) begin
                        cam_pwdn <= 1'b0;
                        xclk_en  <= 1'b1;
                        wait_cnt <= 32'd0;
                        state    <= ST_DELAY_1MS;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                ST_DELAY_1MS: begin
                    if (wait_cnt >= WAIT_1MS - 1) begin
                        cam_rst_n <= 1'b1;
                        wait_cnt  <= 32'd0;
                        state     <= ST_DELAY_20MS;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                ST_DELAY_20MS: begin
                    if (wait_cnt >= WAIT_20MS - 1) begin
                        wait_cnt <= 32'd0;
                        state    <= ST_HOLD_LOW;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                //============================================
                // Hold both lines low after reset
                //============================================
                ST_HOLD_LOW: begin
                    busy     <= 1'b1;
                    done     <= 1'b0;
                    error    <= 1'b0;
                    sda_1    <= 1'b0;
                    scl_1    <= 1'b0;
                    wait_cnt <= 32'd0;
                    state    <= ST_WAIT_TRIGGER;
                end

                ST_WAIT_TRIGGER: begin
                    sda_1  <= 1'b0;
                    scl_1  <= 1'b0;
                    state  <= ST_RELEASE;
                end

                //============================================
                // Release both lines, then wait 5 ms
                //============================================
                ST_RELEASE: begin
                    sda_1    <= 1'bz;
                    scl_1    <= 1'bz;
                    wait_cnt <= 32'd0;
                    state    <= ST_WAIT_5MS;
                end

                ST_WAIT_5MS: begin
                    sda_1 <= 1'bz;
                    scl_1 <= 1'bz;
                    if (wait_cnt >= WAIT_5MS - 1) begin
                        cmd_index  <= 9'd0;
                        byte_index <= 2'd0;
                        ack_fail   <= 1'b0;
                        wait_cnt   <= 32'd0;
                        state      <= ST_LOAD_CMD;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                //============================================
                // Load next command
                //============================================
                ST_LOAD_CMD: begin
                    if (cmd_index == 9'd2 && wait_cnt <= WAIT_10MS - 1) begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                    else if (cmd_phase[31:24] == 8'hff) begin
                        state <= ST_DONE;
                    end
                    else begin
                        wait_cnt   <= 32'd0;
                        byte_index <= 2'd0;
                        bit_index  <= 5'd7;
                        clk_cnt    <= 16'd0;
                        ack_fail   <= 1'b0;
                        curr_byte  <= cmd_phase[31:24]; // device address
                        state      <= ST_START_COND;
                    end
                end

                //============================================
                // START: SDA falls while SCL high
                //============================================
                ST_START_COND: begin
                    sda_1 <= 1'b0;
                    scl_1 <= 1'bz;

                    if (clk_cnt >= HALF_PERIOD) begin
                        clk_cnt   <= 16'd0;
                        bit_index <= 5'd7;
                        state     <= ST_SEND_BYTE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //============================================
                // Send 8 bits, MSB first
                //============================================
                ST_SEND_BYTE: begin
                    if (clk_cnt == 0)
                        scl_1 <= 1'b0;

                    if (clk_cnt == 1)
                        sda_1 <= curr_byte[bit_index];

                    if (clk_cnt == HALF_PERIOD)
                        scl_1 <= 1'bz;

                    if (clk_cnt >= (HALF_PERIOD * 2 - 1)) begin
                        clk_cnt <= 16'd0;
                        if (bit_index == 0) begin
                            sda_1 <= 1'bz;
                            state <= ST_ACK_BIT;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //============================================
                // ACK bit
                //============================================
                ST_ACK_BIT: begin
                    if (clk_cnt == 0) begin
                        scl_1 <= 1'b0;
                        sda_1 <= 1'bz;
                    end

                    if (clk_cnt == HALF_PERIOD)
                        scl_1 <= 1'bz;

                    // Sample SDA a couple cycles into SCL's high phase -- gives
                    // the slave time to have pulled it low for a real ACK.
                    // sda_in reading high here means the line was never pulled
                    // low, i.e. a NACK.
                    if (clk_cnt == HALF_PERIOD + 2)
                        ack_fail <= sda_in;

                    if (clk_cnt >= (HALF_PERIOD * 2 - 1)) begin
                        clk_cnt <= 16'd0;

                        if (byte_index == 0) begin
                            byte_index <= 2'd1;
                            bit_index  <= 5'd7;
                            curr_byte  <= cmd_phase[23:16]; // reg addr [15:8]
                            state      <= ST_SEND_BYTE;
                        end
                        else if (byte_index == 1) begin
                            byte_index <= 2'd2;
                            bit_index  <= 5'd7;
                            curr_byte  <= cmd_phase[15:8];  // reg addr [7:0]
                            state      <= ST_SEND_BYTE;
                        end
                        else if (byte_index == 2) begin
                            byte_index <= 2'd3;
                            bit_index  <= 5'd7;
                            curr_byte  <= cmd_phase[7:0];   // data
                            state      <= ST_SEND_BYTE;
                        end
                        else begin
                            state <= ST_STOP_COND;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //============================================
                // STOP: SDA rises while SCL high
                //============================================
                ST_STOP_COND: begin
                    if (clk_cnt == 0) begin
                        scl_1 <= 1'b0;
                        sda_1 <= 1'b0;
                    end
                    if (clk_cnt == HALF_PERIOD)
                        scl_1 <= 1'bz;
                    if (clk_cnt == HALF_PERIOD * 2)
                        sda_1 <= 1'bz;

                    if (clk_cnt >= (HALF_PERIOD * 3 - 1)) begin
                        clk_cnt <= 16'd0;
                        state   <= ST_NEXT_CMD;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                //============================================
                // Retry on NACK, else advance
                //============================================
                ST_NEXT_CMD: begin
                    if (ack_fail && retry_count < 4'd3) begin
                        // real retry: reload/retransmit the SAME command
                        // (cmd_index unchanged) instead of skipping past it
                        error       <= 1'b1;
                        retry_count <= retry_count + 1'b1;
                        state       <= ST_LOAD_CMD;
                    end else begin
                        retry_count <= 4'd0;
                        if (cmd_index == CMD_COUNT - 1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            cmd_index <= cmd_index + 1'b1;
                            state     <= ST_LOAD_CMD;
                        end
                    end
                end

                ST_DONE: begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    sda_1    <= 1'bz;
                    scl_1    <= 1'bz;
                    cam_done <= 1'b1;
                    state    <= ST_DONE;
                end

                default: begin
                    state <= ST_POWER_START;
                end
            endcase
        end
    end

endmodule