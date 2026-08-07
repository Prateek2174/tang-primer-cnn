module top_uart_test
(
    input  wire clk,    //27MHz board oscillator
    input  wire rst_n,
    output wire uart_tx_pin
);

    localparam PERIOD = 27_000_000 / 10; // ~100ms at 27MHz

    reg [24:0] counter;
    reg        send_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 0;
            send_en <= 1'b0;
        end else if (counter == PERIOD - 1) begin
            counter <= 0;
            send_en <= 1'b1;
        end else begin
            counter <= counter + 1'b1;
            send_en <= 1'b0;
        end
    end

    //========================================================
    // UART_MASTER_Top register interface -- same protocol as
    // uart_frame_sender.v, simplified to just loop sending 0x55
    // on a timer instead of reading from the frame buffer.
    //========================================================

    localparam ADDR_DATA = 3'b000;
    localparam ADDR_LCR  = 3'b011;
    localparam ADDR_STAT = 3'b101;

    localparam FSM_LCR_WRITE  = 0;
    localparam FSM_LCR_CLEAR  = 1;
    localparam FSM_IDLE       = 2;
    localparam FSM_POLL_START = 3;
    localparam FSM_POLL_WAIT  = 4;
    localparam FSM_POLL_CHECK = 5;
    localparam FSM_WRITE      = 6;
    localparam FSM_WRITE_CLR  = 7;

    reg [3:0] state;

    reg       um_tx_en;
    reg [2:0] um_waddr;
    reg [7:0] um_wdata;
    reg       um_rx_en;
    reg [2:0] um_raddr;
    wire [7:0] um_rdata;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state    <= FSM_LCR_WRITE;
            um_tx_en <= 0;
            um_waddr <= 0;
            um_wdata <= 0;
            um_rx_en <= 0;
            um_raddr <= 0;

        end else begin

            case (state)

                FSM_LCR_WRITE: begin
                    um_waddr <= ADDR_LCR;
                    um_wdata <= 8'h03; // 8N1
                    um_tx_en <= 1'b1;
                    state    <= FSM_LCR_CLEAR;
                end

                FSM_LCR_CLEAR: begin
                    um_tx_en <= 1'b0;
                    state    <= FSM_IDLE;
                end

                FSM_IDLE: begin
                    if (send_en) begin
                        state <= FSM_POLL_START;
                    end
                end

                FSM_POLL_START: begin
                    um_raddr <= ADDR_STAT;
                    um_rx_en <= 1'b1;
                    state    <= FSM_POLL_WAIT;
                end

                FSM_POLL_WAIT: begin
                    um_rx_en <= 1'b0;
                    state    <= FSM_POLL_CHECK;
                end

                FSM_POLL_CHECK: begin
                    if (um_rdata[6])
                        state <= FSM_WRITE;
                    else
                        state <= FSM_POLL_START;
                end

                FSM_WRITE: begin
                    um_waddr <= ADDR_DATA;
                    um_wdata <= 8'h55; // 'U'
                    um_tx_en <= 1'b1;
                    state    <= FSM_WRITE_CLR;
                end

                FSM_WRITE_CLR: begin
                    um_tx_en <= 1'b0;
                    state    <= FSM_IDLE;
                end

            endcase

        end

    end

    UART_MASTER_Top uart_master_inst(
        .I_CLK    (clk),
        .I_RESETN (rst_n),

        .I_TX_EN  (um_tx_en),
        .I_WADDR  (um_waddr),
        .I_WDATA  (um_wdata),

        .I_RX_EN  (um_rx_en),
        .I_RADDR  (um_raddr),
        .O_RDATA  (um_rdata),

        .SIN      (1'b1),
        .RxRDYn   (),
        .SOUT     (uart_tx_pin),
        .TxRDYn   (),
        .DDIS     (),
        .INTR     (),
        .DCDn     (1'b1),
        .CTSn     (1'b1),
        .DSRn     (1'b1),
        .RIn      (1'b1),
        .DTRn     (),
        .RTSn     ()
    );

endmodule
