module cnn_top
(
    input rst_n,
    input pclk,
    input frame_ready, // pulses/goes high once a full 96x96 frame has been
                        // written into the resize BSRAM by the new UART
                        // byte-assembly logic. Repurposed from the old
                        // `vsync` (real-camera DVP signal) -- this pipeline
                        // no longer has a camera, so wire this to whatever
                        // "frame complete" signal that module produces.
                        // Was previously triggered on vsync's FALLING edge
                        // (end of the camera's blanking period); this
                        // triggers on frame_ready's RISING edge instead
                        // (start of a newly-completed frame). If your new
                        // module drives frame_ready as a clean single-cycle
                        // pulse, this still works correctly (a pulse has a
                        // rising edge too) -- the edge-detect is kept as a
                        // safety net in case it's a level instead.

    output reg conv_en,
    output reg pool_en,
    output reg gap_en,
    output reg fc_en,
    output reg uart_en, // vestigial -- see FSM_FC comment below. Always 0.

    input conv_done,
    input pool_done,
    input gap_done,
    input fc_done,
    input uart_done, // vestigial, ignored -- see FSM_FC comment below.

    output reg [1:0] conv_layer_sel, //tie to weight_rom.v to find out the layer

    output busy // high whenever a classification is in progress (anything
                // but FSM_IDLE) -- lets uart_frame.v hold off starting a
                // new frame capture while this one is still being read out
                // of resize_bsram (mac_array's CONV1 stage). Without this,
                // send_frames.py streams frames back-to-back with no gap,
                // so the next frame's incoming bytes could start
                // overwriting resize_bsram mid-CONV1, corrupting the
                // in-progress classification with a mix of old and new
                // pixel data -- same corruption pattern every cycle given
                // fixed relative timing, which could show up as a stable
                // but wrong classification instead of an obvious crash.

);

    reg frame_ready_prev;

    always @(posedge pclk or negedge rst_n) begin

        if(!rst_n) begin

            frame_ready_prev <= 1'b0;

        end else begin
            frame_ready_prev <= frame_ready;
        end

    end

    wire frame_start = ~frame_ready_prev & frame_ready; //rising edge

    //========================================================
    // FSM states
    //========================================================

    localparam FSM_IDLE  = 0;
    localparam FSM_CONV1 = 1;
    localparam FSM_CONV2 = 2;
    localparam FSM_CONV3 = 3;
    localparam FSM_GAP   = 4;
    localparam FSM_FC    = 5;

    reg [3:0] state;

    assign busy = (state != FSM_IDLE);

    //========================================================
    // Main FSM
    //========================================================

    always @(posedge pclk or negedge rst_n) begin

        if(!rst_n) begin

            state <= FSM_IDLE;

            conv_en <= 1'b0;
            pool_en <= 1'b0;
            gap_en  <= 1'b0;
            fc_en   <= 1'b0;
            uart_en <= 1'b0;

            conv_layer_sel <= 2'b00;

        end else begin

            case(state)

                FSM_IDLE: begin

                    if (frame_start) begin

                        state <= FSM_CONV1;

                    end

                end

                FSM_CONV1: begin

                    conv_layer_sel <= 2'b00; //CONV1 weights
                    conv_en        <= 1'b1;

                    if(conv_done) begin

                        conv_en <= 1'b0;
                        state <= FSM_CONV2;

                    end

                end

                FSM_CONV2: begin

                    conv_layer_sel <= 2'b01; //CONV2 weights
                    conv_en        <= 1'b1;

                    if(conv_done) begin

                        conv_en <= 1'b0;
                        state <= FSM_CONV3;

                    end

                end

                FSM_CONV3: begin

                    conv_layer_sel <= 2'b10; //CONV3 weights
                    conv_en        <= 1'b1;

                    if(conv_done) begin

                        conv_en <= 1'b0;
                        state <= FSM_GAP;

                    end

                end

                FSM_GAP: begin

                    gap_en <= 1'b1;

                    if(gap_done) begin

                        gap_en <= 1'b0;
                        state <= FSM_FC;

                    end

                end

                FSM_FC: begin

                    conv_layer_sel <= 2'b11; //FC weights
                    fc_en <= 1'b1;

                    if(fc_done) begin

                        // Used to go to FSM_UART and wait for uart_done here,
                        // but that assumed a UART TX module that no longer
                        // exists (uart.v is RX-only now, output is the LED
                        // decoder instead). Nothing would ever drive
                        // uart_done, so that state was a permanent deadlock
                        // after the very first classification. Go straight
                        // back to FSM_IDLE instead -- the LED decoder reads
                        // class_result combinationally, no handshake needed.
                        fc_en <= 1'b0;
                        state <= FSM_IDLE;

                    end

                end

            endcase

        end

    end



endmodule
