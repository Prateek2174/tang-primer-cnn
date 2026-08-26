module preprocessor
(
    input wire pclk,
    input wire rst_n,
    
    input[7:0] y_data,
    input      data_en,

    input wire href,
    input wire vsync,

    output reg       resize_en,
    output reg [7:0] y_resize,
    output reg [13:0] resize_wr_addr //write address into the 96x96 frame buffer

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

    //current position within the 96x96 output grid -- increments once
    //per KEPT pixel, not once per incoming pixel (unlike hcount/vcount)
    reg [6:0] out_x; //0-95
    reg [6:0] out_y; //0-95

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
            resize_wr_addr <= 14'd0;
            out_x <= 0;
            out_y <= 0;

        end else if (vsync) begin

            resize_en <= 1'b0;
            resize_wr_addr <= 14'd0;
            out_x <= 0;
            out_y <= 0;

        end else begin

            if(data_en && href && h_phase == 0 && v_phase == 0 && hcount < (OUT_SIZE * SCALE_H)) begin

                resize_en <= 1'b1;
                y_resize <= y_data - 8'd128;
                resize_wr_addr <= out_y * OUT_SIZE + out_x;

                if (out_x == OUT_SIZE - 1) begin
                    out_x <= 0;
                    out_y <= out_y + 1'b1;
                end else begin
                    out_x <= out_x + 1'b1;
                end

            end else begin

                resize_en <= 1'b0;

            end

        end

    end

endmodule