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
    // UART_MASTER_Top (Gowin UART Master IP) REGISTER INTERFACE
    //========================================================
    // Register map, confirmed from Gowin's own UART_MASTER_tb.v:
    //   addr 3'b000 = data register (THR) -- write byte here to send
    //   addr 3'b011 = Line Control Register -- format config
    //   addr 3'b101 = status register -- bit 6 = transmitter ready

    output reg        I_TX_EN,
    output reg [2:0]  I_WADDR,
    output reg [7:0]  I_WDATA,

    output reg        I_RX_EN,
    output reg [2:0]  I_RADDR,
    input      [7:0]  O_RDATA

);

    localparam FRAME_SIZE = 9216; // 96*96
    localparam ADDR_DATA  = 3'b000;
    localparam ADDR_LCR   = 3'b011;
    localparam ADDR_STAT  = 3'b101;

    //========================================================
    // FSM states
    //========================================================

    localparam FSM_LCR_WRITE  = 0; // one-time format setup after reset
    localparam FSM_LCR_CLEAR  = 1;
    localparam FSM_IDLE       = 2;
    localparam FSM_ADDR       = 3; // drive frame_addr, wait 1 cycle for frame_dout
    localparam FSM_POLL_START = 4; // begin status read
    localparam FSM_POLL_WAIT  = 5;
    localparam FSM_POLL_CHECK = 6;
    localparam FSM_WRITE      = 7; // assert I_TX_EN + data
    localparam FSM_WRITE_CLR  = 8; // deassert I_TX_EN
    localparam FSM_NEXT       = 9;
    localparam FSM_DONE       = 10;

    reg [3:0]  state;

    reg [13:0] pixel_index; // 0..9215, which byte of the frame we're on
    reg [1:0]  header_index; // 0..1, which header byte we're on
    reg        sending_header;
    reg        addr_valid;
    reg [7:0]  current_byte;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state          <= FSM_LCR_WRITE;
            pixel_index    <= 0;
            header_index   <= 0;
            sending_header <= 1'b1;
            addr_valid     <= 0;
            frame_addr     <= 0;
            frame_rd_en    <= 0;
            current_byte   <= 0;
            send_done      <= 0;

            I_TX_EN <= 0;
            I_WADDR <= 0;
            I_WDATA <= 0;
            I_RX_EN <= 0;
            I_RADDR <= 0;

        end else begin

            case (state)

                //====================================================
                // One-time UART format setup: 8 data bits, no parity,
                // 1 stop bit. Verify 8'h03 against the reference doc
                // if transmission looks malformed -- the testbench's
                // own value (0x2b) looked non-standard and wasn't
                // trusted here.
                //====================================================

                FSM_LCR_WRITE: begin
                    I_WADDR <= ADDR_LCR;
                    I_WDATA <= 8'h03;
                    I_TX_EN <= 1'b1;
                    state   <= FSM_LCR_CLEAR;
                end

                FSM_LCR_CLEAR: begin
                    I_TX_EN <= 1'b0;
                    state   <= FSM_IDLE;
                end

                FSM_IDLE: begin

                    send_done      <= 0;
                    pixel_index    <= 0;
                    header_index   <= 0;
                    sending_header <= 1'b1;

                    if (send_en) begin
                        state <= FSM_POLL_START;
                    end

                end

                //====================================================
                // Gather the next byte to send. Header bytes are
                // immediate; frame bytes need one cycle of BSRAM
                // read latency.
                //====================================================

                FSM_ADDR: begin

                    frame_addr  <= pixel_index;
                    frame_rd_en <= 1'b1;
                    addr_valid  <= 1'b1;

                    if (addr_valid) begin
                        current_byte <= frame_dout;
                        state        <= FSM_POLL_START;
                    end

                end

                //====================================================
                // Poll status register bit 6 (transmitter ready) --
                // 3-cycle sequence matching UART_MASTER_tb.v exactly.
                //====================================================

                FSM_POLL_START: begin
                    I_RADDR <= ADDR_STAT;
                    I_RX_EN <= 1'b1;
                    state   <= FSM_POLL_WAIT;
                end

                FSM_POLL_WAIT: begin
                    I_RX_EN <= 1'b0;
                    state   <= FSM_POLL_CHECK;
                end

                FSM_POLL_CHECK: begin
                    if (O_RDATA[6]) begin
                        state <= FSM_WRITE;
                    end else begin
                        state <= FSM_POLL_START; // not ready yet, poll again
                    end
                end

                //====================================================
                // Write the byte -- 2-cycle pulse sequence matching
                // UART_MASTER_tb.v.
                //====================================================

                FSM_WRITE: begin
                    I_WADDR <= ADDR_DATA;
                    I_WDATA <= sending_header
                               ? (header_index == 0 ? 8'hAA : 8'h55)
                               : current_byte;
                    I_TX_EN <= 1'b1;
                    state   <= FSM_WRITE_CLR;
                end

                FSM_WRITE_CLR: begin
                    I_TX_EN <= 1'b0;
                    state   <= FSM_NEXT;
                end

                //====================================================
                // Advance to next byte, or finish.
                //====================================================

                FSM_NEXT: begin

                    frame_rd_en <= 1'b0;
                    addr_valid  <= 1'b0;

                    if (sending_header) begin

                        if (header_index == 1) begin
                            sending_header <= 1'b0;
                            state          <= FSM_ADDR;
                        end else begin
                            header_index <= header_index + 1'b1;
                            state        <= FSM_POLL_START; // header bytes need no BSRAM read
                        end

                    end else begin

                        if (pixel_index == FRAME_SIZE - 1) begin
                            state <= FSM_DONE;
                        end else begin
                            pixel_index <= pixel_index + 1'b1;
                            state       <= FSM_ADDR;
                        end

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
