module preprocessor
(
    input wire pclk,
    input wire rst_n,
    
    input[7:0] y_data,
    input      data_en,

    input wire href,
    input wire vsync,

    output reg      resize_en,
    output reg[7:0] y_resize

);

    localparam IMG_WIDTH = 640;
    localparam IMG_HEIGHT = 480;
    localparam SCALE_H = 640 / 96;
    localparam SCALE_V = 480 / 96;
    localparam OUT_SIZE = 96;

    reg [9:0] hcount;
    reg [8:0] vcount;

    reg [2:0] h_phase;
    reg [2:0] v_phase;

    //========================================================
    // Keep count of current pixel location
    //======================================================== 

    always @(posedge pclk or negedge rst_n) begin

        if(!rst_n) begin

            hcount <= 0;
            vcount <= 0;
            h_phase <= 0;
            v_phase <= 0;

        end else if(vsync) begin
                
            hcount <= 10'd0;
            vcount <= 9'd0;
            h_phase <= 0;
            v_phase <= 0;

        end else if(href && data_en) begin

            if(hcount == IMG_WIDTH - 1) begin

                hcount <= 10'd0;
                vcount <= vcount + 1'b1;

                h_phase <= 0;

                if (v_phase == SCALE_V - 1) begin
                    v_phase <= 0;
                end else begin
                    v_phase <= v_phase + 1'b1;
                end

            end else begin

                hcount <= hcount + 1'b1;

                if (h_phase == SCALE_H - 1) begin
                    h_phase <= 0;
                end else begin
                    h_phase <= h_phase + 1'b1;
                end

            end

        end

    end

    //========================================================
    // Check to see if incoming pixel maps -> 96x96 frame & normalize
    //======================================================== 

    always @(posedge pclk or negedge rst_n) begin

        if (!rst_n) begin

            resize_en <= 1'b0;
            y_resize <= 8'd0;

        end else begin

            if(data_en && href && h_phase == 0 && v_phase == 0) begin
    
                resize_en <= 1'b1;
                y_resize <= y_data - 8'd128;

            end else begin

                resize_en <= 1'b0;

            end

        end

    end

endmodule