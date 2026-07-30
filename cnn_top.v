module cnn_top
(
    input rst_n,
    input pclk, 
    input vsync,

    output reg conv_en,
    output reg pool_en,
    output reg gap_en,
    output reg fc_en,
    output reg uart_en,

    input conv_done,
    input pool_done,
    input gap_done,
    input fc_done,
    input uart_done,

    output reg [1:0] conv_layer_sel //tie to weight_rom.v to find out the layer

);

    //during vsync high the frame gets resized so it would only be ready to
    //go through this process after the resizing is complete so the vsync
    //falling edge

    reg vsync_prev;

    always @(posedge pclk or negedge rst_n) begin
        
        if(!rst_n) begin

            vsync_prev <= 1'b0;

        end else begin
            vsync_prev <= vsync;
        end

    end

    wire vsync_fall = vsync_prev & ~vsync; //falling edge

    //========================================================
    // FSM states
    //========================================================    
      
    localparam FSM_IDLE  = 0;
    localparam FSM_CONV1 = 1;
    localparam FSM_CONV2 = 2;
    localparam FSM_CONV3 = 3;
    localparam FSM_GAP   = 4;
    localparam FSM_FC    = 5;
    localparam FSM_UART  = 6;

    reg [3:0] state;

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

                    if (vsync_fall) begin
                        
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

                        fc_en <= 1'b0;
                        state <= FSM_UART;

                    end

                end

                FSM_UART: begin

                    uart_en <= 1'b1;

                    if(uart_done) begin

                        uart_en <= 1'b0;
                        state <= FSM_IDLE;

                    end

                end

            endcase

        end

    end



endmodule