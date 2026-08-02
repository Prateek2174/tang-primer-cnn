module uart_frame_sender
(
    input  rst_n,
    input  clk,

    input  send_en,   // pulse/level to start sending one frame
    output reg send_done,

    //========================================================
    // 96x96 FRAME BUFFER READ INTERFACE
    //========================================================

    output reg [13:0] frame_addr,
    output reg        frame_rd_en,
    input  [7:0]       frame_dout,

    //========================================================
    // UART TX INTERFACE
    //========================================================

    output reg [7:0]  tx_data,
    output reg        tx_data_valid,
    input             tx_data_ready

);

    localparam FRAME_SIZE = 9216; // 96*96

    //========================================================
    // FSM states
    //========================================================

    localparam FSM_IDLE   = 0;
    localparam FSM_HEADER = 1; // send 2-byte sync header 0xAA 0x55
    localparam FSM_ADDR   = 2; // drive read address, wait 1 cycle for dout
    localparam FSM_SEND   = 3; // hand byte to uart, wait for tx_data_ready
    localparam FSM_NEXT   = 4; // advance address or finish
    localparam FSM_DONE   = 5;

    reg [3:0] state;

    reg [13:0] pixel_index; // 0..9215, which byte of the frame we're on
    reg [1:0]  header_index; // 0..1, which header byte we're on
    reg        addr_valid;   // tracks whether frame_dout corresponds to
                              // the address we just drove (1-cycle latency)

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state         <= FSM_IDLE;
            pixel_index   <= 0;
            header_index  <= 0;
            frame_addr    <= 0;
            frame_rd_en   <= 0;
            addr_valid    <= 0;
            tx_data       <= 0;
            tx_data_valid <= 0;
            send_done     <= 0;

        end else begin

            case (state)

                FSM_IDLE: begin

                    send_done   <= 0;
                    pixel_index <= 0;
                    header_index <= 0;

                    if (send_en) begin
                        state <= FSM_HEADER;
                    end

                end

                FSM_HEADER: begin

                    tx_data <= (header_index == 0) ? 8'hAA : 8'h55;

                    if (tx_data_ready) begin

                        tx_data_valid <= 1'b1;

                        if (header_index == 1) begin
                            state <= FSM_ADDR;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end

                    end else begin

                        tx_data_valid <= 1'b0;

                    end

                end

                FSM_ADDR: begin

                    //same 1-cycle BSRAM latency pattern as mac_array's
                    //gather loop -- drive the address this cycle, the
                    //corresponding dout is only valid next cycle.

                    frame_addr  <= pixel_index;
                    frame_rd_en <= 1'b1;
                    addr_valid  <= 1'b1;

                    if (addr_valid) begin
                        state <= FSM_SEND;
                    end

                end

                FSM_SEND: begin

                    frame_rd_en <= 1'b0;

                    if (tx_data_ready) begin

                        tx_data       <= frame_dout;
                        tx_data_valid <= 1'b1;
                        state         <= FSM_NEXT;

                    end else begin

                        tx_data_valid <= 1'b0;

                    end

                end

                FSM_NEXT: begin

                    tx_data_valid <= 1'b0;
                    addr_valid    <= 1'b0;

                    if (pixel_index == FRAME_SIZE - 1) begin
                        state <= FSM_DONE;
                    end else begin
                        pixel_index <= pixel_index + 1'b1;
                        state       <= FSM_ADDR;
                    end

                end

                FSM_DONE: begin

                    send_done <= 1'b1;
                    state     <= FSM_IDLE;

                end

            endcase

        end

    end

endmodule
