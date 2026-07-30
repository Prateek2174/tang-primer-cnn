module uart
#(
    parameter CLK_FREQ  = 27,    //clock frequency in MHz
    parameter BAUD_RATE = 115200 //serial baud rate
)
(
    input       clk,
    input       rst_n,
    input [7:0] tx_data,
    input       tx_data_valid, 

    output      tx_data_ready, //data is ready to send
    output      tx_pin,        //serial data output 
    output      tx_busy
);

    localparam                       integer CYCLE_PER_BIT = CLK_FREQ * 1000000 / BAUD_RATE;
    localparam                       integer COUNT_WIDTH   = (CYCLE_PER_BIT <= 1) ? 1 : $clog2(CYCLE_PER_BIT);
    localparam [COUNT_WIDTH - 1 : 0]         CYCLE_MAX     = CYCLE_PER_BIT - 1;


    //========================================================
    // FSM states
    //======================================================== 

    localparam [2:0] FSM_IDLE      = 3'd1;
    localparam [2:0] FSM_START     = 3'd2;
    localparam [2:0] FSM_SEND_BYTE = 3'd3;
    localparam [2:0] FSM_STOP      = 3'd4;
    
    reg [COUNT_WIDTH - 1 : 0] cycle_cnt; //baud counter

    reg [2:0] state;
    reg [2:0] next_state;    //used for a future condition
    reg [2:0] bit_index;     //bit counter/index
    reg [7:0] tx_data_latch; //latch the transfer data
    reg       tx_reg;

    wire bit_tick = (cycle_cnt == CYCLE_MAX);
    wire accept = (state == FSM_IDLE) && tx_data_valid;

    assign tx_data_ready = (state == FSM_IDLE);
    assign tx_busy       = (state != FSM_IDLE);

    assign tx_pin = tx_reg;

    //========================================================
    // On reset the state goes back to IDLE otherwise next_state
    //======================================================== 

    always @(posedge clk or negedge rst_n) begin

        if(rst_n == 1'b0) begin

            state <= FSM_IDLE;

        end else begin

            state <= next_state;

        end

    end

    //========================================================
    // Main FSM
    //======================================================== 

    always @(*) begin

        case(state)

            FSM_IDLE: begin

                if(tx_data_valid == 1'b1) begin
                    
                    next_state = FSM_START;

                end else begin

                    next_state = FSM_IDLE;

                end
 
            end

            FSM_START: begin

                if(bit_tick) begin

                    next_state = FSM_SEND_BYTE;

                end else begin

                    next_state = FSM_START;

                end
            
            end

            FSM_SEND_BYTE: begin

                if (bit_tick  && bit_index == 3'd7) begin

                    next_state = FSM_STOP;

                end else begin

                    next_state = FSM_SEND_BYTE;

                end

            end

            FSM_STOP: begin

                if(bit_tick) begin

                    next_state = FSM_IDLE;

                end else begin

                    next_state = FSM_STOP;

                end

            end

            default: begin

                next_state = FSM_IDLE;

            end
        
        endcase

    end

    //========================================================
    // Latch the byte to be transferred like a Shift/Capture register
    //========================================================

    always @(posedge clk or negedge rst_n) begin

        if(rst_n == 1'b0) begin

            tx_data_latch <= 8'd0;

        end else if(accept) begin

            tx_data_latch <= tx_data;

        end
            
    end

    //========================================================
    // Counting bit_index during a byte transfer
    //========================================================

    always @(posedge clk or negedge rst_n) begin  

        if(!rst_n) begin

            bit_index <= 3'd0;

        end else if (state == FSM_SEND_BYTE) begin

            if(cycle_cnt == CYCLE_PER_BIT - 1) begin

                bit_index <= bit_index + 3'd1;

            end else begin

                bit_index <= bit_index;

            end

        end else begin

            bit_index <= 3'd0;

        end

    end

    //========================================================
    // Increment/Reset cycle_cnt [which is the baud rate counter]
    //======================================================== 

    always @(posedge clk or negedge rst_n) begin

        if(!rst_n) begin

            cycle_cnt <= 1'd0;

        end else if (state == FSM_IDLE) begin

            cycle_cnt <= 1'd0;
        
        end else if (bit_tick) begin

            cycle_cnt <= 1'd0;

        end else begin

            cycle_cnt <= cycle_cnt + 1'b1;

        end

    end

    //========================================================
    // Setting tx_reg
    //======================================================== 

    always @(posedge clk or negedge rst_n) begin
    
        if(rst_n == 1'b0) begin
    
            tx_reg <= 1'b1;
        
        end else begin

            case(state)

                FSM_IDLE, FSM_STOP: begin

                    tx_reg <= 1'b1;

                end

                FSM_START: begin

                    tx_reg <= 1'b0;

                end

                FSM_SEND_BYTE: begin

                    tx_reg <= tx_data_latch[bit_index];

                end

                default: begin

                    tx_reg <= 1'b1;

                end
            
            endcase

        end

    end

endmodule