//`include "ov5640_register.vh"

module i2c_bitbang_cam #(
    parameter CLK_FREQ = 50000000,     // System clock frequency
    parameter I2C_FREQ = 100000,       // Target I2C frequency (~100 kHz)
    parameter CMD_COUNT = 263,    // Number of phase 1 commands
    parameter WAIT_5MS = 250000   // 5 ms at 50 MHz

)(
    input  wire clk,
    input  wire rst_n,

    input cam_clk,

    output reg cam_done,

    output reg  busy,
    output reg  done,
    output reg error,
    
    // 0 = drive low
    // 1 = release line
    //output reg led_1,
    output reg  sda_1, //inout
    output reg  scl_1,

    output reg cam_pwdn,
    output reg cam_rst_n,
    output cam_xvclk
);

    // Half-period for SCL in clocks
    localparam HALF_PERIOD = CLK_FREQ / (I2C_FREQ * 2);
    localparam WAIT_1MS    = CLK_FREQ / 1000;
    localparam WAIT_20MS   = CLK_FREQ / 50;
    localparam WAIT_10MS   = CLK_FREQ / 100;

    // Command storage {dev_addr, reg_addr, data}
    reg [31:0] cmd_phase [0:CMD_COUNT-1];

    initial begin

        cmd_phase[0]   <= {8'h78 , 24'h310311};
        cmd_phase[1]   <= {8'h78 , 24'h300882};
        cmd_phase[2]   <= {8'h78 , 24'h300842};
        cmd_phase[3]   <= {8'h78 , 24'h310303};
        cmd_phase[4]   <= {8'h78 , 24'h3017ff};
        cmd_phase[5]   <= {8'h78 , 24'h3018ff};
        cmd_phase[6]   <= {8'h78 , 24'h303418}; 
        cmd_phase[7]   <= {8'h78 , 24'h303713}; //div 16 14
        cmd_phase[8]   <= {8'h78 , 24'h310801};
        cmd_phase[9]   <= {8'h78 , 24'h363036};
        cmd_phase[10]  <= {8'h78 , 24'h36310e};
        cmd_phase[11]  <= {8'h78 , 24'h3632e2};
        cmd_phase[12]  <= {8'h78 , 24'h363312};
        cmd_phase[13]  <= {8'h78 , 24'h3621e0};
        cmd_phase[14]  <= {8'h78 , 24'h3704a0};
        cmd_phase[15]  <= {8'h78 , 24'h37035a};
        cmd_phase[16]  <= {8'h78 , 24'h371578};
        cmd_phase[17]  <= {8'h78 , 24'h371701};
        cmd_phase[18]  <= {8'h78 , 24'h370b60};
        cmd_phase[19]  <= {8'h78 , 24'h37051a};
        cmd_phase[20]  <= {8'h78 , 24'h390502};
        cmd_phase[21]  <= {8'h78 , 24'h390610};
        cmd_phase[22]  <= {8'h78 , 24'h39010a};
        cmd_phase[23]  <= {8'h78 , 24'h373112};
        cmd_phase[24]  <= {8'h78 , 24'h360008};
        cmd_phase[25]  <= {8'h78 , 24'h360133};
        cmd_phase[26]  <= {8'h78 , 24'h302d60};
        cmd_phase[27]  <= {8'h78 , 24'h362052};
        cmd_phase[28]  <= {8'h78 , 24'h371b20};
        cmd_phase[29]  <= {8'h78 , 24'h471c50};
        cmd_phase[30]  <= {8'h78 , 24'h3a1343};
        cmd_phase[31]  <= {8'h78 , 24'h3a1800};
        cmd_phase[32]  <= {8'h78 , 24'h3a19f8};
        cmd_phase[33]  <= {8'h78 , 24'h363513};
        cmd_phase[34]  <= {8'h78 , 24'h363603};
        cmd_phase[35]  <= {8'h78 , 24'h363440};
        cmd_phase[36]  <= {8'h78 , 24'h362201};
        cmd_phase[37]  <= {8'h78 , 24'h3c0134};
        cmd_phase[38]  <= {8'h78 , 24'h3c0428};
        cmd_phase[39]  <= {8'h78 , 24'h3c0598};
        cmd_phase[40]  <= {8'h78 , 24'h3c0600};
        cmd_phase[41]  <= {8'h78 , 24'h3c0708};
        cmd_phase[42]  <= {8'h78 , 24'h3c0800};
        cmd_phase[43]  <= {8'h78 , 24'h3c091c};
        cmd_phase[44]  <= {8'h78 , 24'h3c0a9c};
        cmd_phase[45]  <= {8'h78 , 24'h3c0b40};
        cmd_phase[46]  <= {8'h78 , 24'h381000};
        cmd_phase[47]  <= {8'h78 , 24'h381110};
        cmd_phase[48]  <= {8'h78 , 24'h381200};
        cmd_phase[49]  <= {8'h78 , 24'h370864};
        cmd_phase[50]  <= {8'h78 , 24'h400102};
        cmd_phase[51]  <= {8'h78 , 24'h40051a};
        cmd_phase[52]  <= {8'h78 , 24'h300000};
        cmd_phase[53]  <= {8'h78 , 24'h3004ff};
        cmd_phase[54]  <= {8'h78 , 24'h300e58};
        cmd_phase[55]  <= {8'h78 , 24'h302e00};
        cmd_phase[56]  <= {8'h78 , 24'h430030};
        cmd_phase[57]  <= {8'h78 , 24'h501f00};
        cmd_phase[58]  <= {8'h78 , 24'h440e00};
        cmd_phase[59]  <= {8'h78 , 24'h5000a7};
        cmd_phase[60]  <= {8'h78 , 24'h3a0f30};
        cmd_phase[61]  <= {8'h78 , 24'h3a1028};
        cmd_phase[62]  <= {8'h78 , 24'h3a1b30};
        cmd_phase[63]  <= {8'h78 , 24'h3a1e26};
        cmd_phase[64]  <= {8'h78 , 24'h3a1160};
        cmd_phase[65]  <= {8'h78 , 24'h3a1f14};
        cmd_phase[66]  <= {8'h78 , 24'h580023};
        cmd_phase[67]  <= {8'h78 , 24'h580114};
        cmd_phase[68]  <= {8'h78 , 24'h58020f};
        cmd_phase[69]  <= {8'h78 , 24'h58030f};
        cmd_phase[70]  <= {8'h78 , 24'h580412};
        cmd_phase[71]  <= {8'h78 , 24'h580526};
        cmd_phase[72]  <= {8'h78 , 24'h58060c};
        cmd_phase[73]  <= {8'h78 , 24'h580708};
        cmd_phase[74]  <= {8'h78 , 24'h580805};
        cmd_phase[75]  <= {8'h78 , 24'h580905};
        cmd_phase[76]  <= {8'h78 , 24'h580a08};
        cmd_phase[77]  <= {8'h78 , 24'h580b0d};
        cmd_phase[78]  <= {8'h78 , 24'h580c08};
        cmd_phase[79]  <= {8'h78 , 24'h580d03};
        cmd_phase[80]  <= {8'h78 , 24'h580e00};
        cmd_phase[81]  <= {8'h78 , 24'h580f00};
        cmd_phase[82]  <= {8'h78 , 24'h581003};
        cmd_phase[83]  <= {8'h78 , 24'h581109};
        cmd_phase[84]  <= {8'h78 , 24'h581207};
        cmd_phase[85]  <= {8'h78 , 24'h581303};
        cmd_phase[86]  <= {8'h78 , 24'h581400};
        cmd_phase[87]  <= {8'h78 , 24'h581501};
        cmd_phase[88]  <= {8'h78 , 24'h581603};
        cmd_phase[89]  <= {8'h78 , 24'h581708};
        cmd_phase[90]  <= {8'h78 , 24'h58180d};
        cmd_phase[91]  <= {8'h78 , 24'h581908};
        cmd_phase[92]  <= {8'h78 , 24'h581a05};
        cmd_phase[93]  <= {8'h78 , 24'h581b06};
        cmd_phase[94]  <= {8'h78 , 24'h581c08};
        cmd_phase[95]  <= {8'h78 , 24'h581d0e};
        cmd_phase[96]  <= {8'h78 , 24'h581e29};
        cmd_phase[97]  <= {8'h78 , 24'h581f17};
        cmd_phase[98]  <= {8'h78 , 24'h582011};
        cmd_phase[99]  <= {8'h78 , 24'h582111};
        cmd_phase[100] <= {8'h78 , 24'h582215};
        cmd_phase[101] <= {8'h78 , 24'h582328};
        cmd_phase[102] <= {8'h78 , 24'h582446};
        cmd_phase[103] <= {8'h78 , 24'h582526};
        cmd_phase[104] <= {8'h78 , 24'h582608};
        cmd_phase[105] <= {8'h78 , 24'h582726};
        cmd_phase[106] <= {8'h78 , 24'h582864};
        cmd_phase[107] <= {8'h78 , 24'h582926};
        cmd_phase[108] <= {8'h78 , 24'h582a24};
        cmd_phase[109] <= {8'h78 , 24'h582b22};
        cmd_phase[110] <= {8'h78 , 24'h582c24};
        cmd_phase[111] <= {8'h78 , 24'h582d24};
        cmd_phase[112] <= {8'h78 , 24'h582e06};
        cmd_phase[113] <= {8'h78 , 24'h582f22};
        cmd_phase[114] <= {8'h78 , 24'h583040};
        cmd_phase[115] <= {8'h78 , 24'h583142};
        cmd_phase[116] <= {8'h78 , 24'h583224};
        cmd_phase[117] <= {8'h78 , 24'h583326};
        cmd_phase[118] <= {8'h78 , 24'h583424};
        cmd_phase[119] <= {8'h78 , 24'h583522};
        cmd_phase[120] <= {8'h78 , 24'h583622};
        cmd_phase[121] <= {8'h78 , 24'h583726};
        cmd_phase[122] <= {8'h78 , 24'h583844};
        cmd_phase[123] <= {8'h78 , 24'h583924};
        cmd_phase[124] <= {8'h78 , 24'h583a26};
        cmd_phase[125] <= {8'h78 , 24'h583b28};
        cmd_phase[126] <= {8'h78 , 24'h583c42};
        cmd_phase[127] <= {8'h78 , 24'h583dce};
        cmd_phase[128] <= {8'h78 , 24'h5180ff};
        cmd_phase[129] <= {8'h78 , 24'h5181f2};
        cmd_phase[130] <= {8'h78 , 24'h518200};
        cmd_phase[131] <= {8'h78 , 24'h518314};
        cmd_phase[132] <= {8'h78 , 24'h518425};
        cmd_phase[133] <= {8'h78 , 24'h518524};
        cmd_phase[134] <= {8'h78 , 24'h518609};
        cmd_phase[135] <= {8'h78 , 24'h518709};
        cmd_phase[136] <= {8'h78 , 24'h518809};
        cmd_phase[137] <= {8'h78 , 24'h518975};
        cmd_phase[138] <= {8'h78 , 24'h518a54};
        cmd_phase[139] <= {8'h78 , 24'h518be0};
        cmd_phase[140] <= {8'h78 , 24'h518cb2};
        cmd_phase[141] <= {8'h78 , 24'h518d42};
        cmd_phase[142] <= {8'h78 , 24'h518e3d};
        cmd_phase[143] <= {8'h78 , 24'h518f56};
        cmd_phase[144] <= {8'h78 , 24'h519046};
        cmd_phase[145] <= {8'h78 , 24'h5191f8};
        cmd_phase[146] <= {8'h78 , 24'h519204};
        cmd_phase[147] <= {8'h78 , 24'h519370};
        cmd_phase[148] <= {8'h78 , 24'h5194f0};
        cmd_phase[149] <= {8'h78 , 24'h5195f0};
        cmd_phase[150] <= {8'h78 , 24'h519603};
        cmd_phase[151] <= {8'h78 , 24'h519701};
        cmd_phase[152] <= {8'h78 , 24'h519804};
        cmd_phase[153] <= {8'h78 , 24'h519912};
        cmd_phase[154] <= {8'h78 , 24'h519a04};
        cmd_phase[155] <= {8'h78 , 24'h519b00};
        cmd_phase[156] <= {8'h78 , 24'h519c06};
        cmd_phase[157] <= {8'h78 , 24'h519d82};
        cmd_phase[158] <= {8'h78 , 24'h519e38};
        cmd_phase[159] <= {8'h78 , 24'h548001};
        cmd_phase[160] <= {8'h78 , 24'h548108};
        cmd_phase[161] <= {8'h78 , 24'h548214};
        cmd_phase[162] <= {8'h78 , 24'h548328};
        cmd_phase[163] <= {8'h78 , 24'h548451};
        cmd_phase[164] <= {8'h78 , 24'h548565};
        cmd_phase[165] <= {8'h78 , 24'h548671};
        cmd_phase[166] <= {8'h78 , 24'h54877d};
        cmd_phase[167] <= {8'h78 , 24'h548887};
        cmd_phase[168] <= {8'h78 , 24'h548991};
        cmd_phase[169] <= {8'h78 , 24'h548a9a};
        cmd_phase[170] <= {8'h78 , 24'h548baa};
        cmd_phase[171] <= {8'h78 , 24'h548cb8};
        cmd_phase[172] <= {8'h78 , 24'h548dcd};
        cmd_phase[173] <= {8'h78 , 24'h548edd};
        cmd_phase[174] <= {8'h78 , 24'h548fea};
        cmd_phase[175] <= {8'h78 , 24'h54901d};
        cmd_phase[176] <= {8'h78 , 24'h53811e};
        cmd_phase[177] <= {8'h78 , 24'h53825b};
        cmd_phase[178] <= {8'h78 , 24'h538308};
        cmd_phase[179] <= {8'h78 , 24'h53840a};
        cmd_phase[180] <= {8'h78 , 24'h53857e};
        cmd_phase[181] <= {8'h78 , 24'h538688};
        cmd_phase[182] <= {8'h78 , 24'h53877c};
        cmd_phase[183] <= {8'h78 , 24'h53886c};
        cmd_phase[184] <= {8'h78 , 24'h538910};
        cmd_phase[185] <= {8'h78 , 24'h538a01};
        cmd_phase[186] <= {8'h78 , 24'h538b98};
        cmd_phase[187] <= {8'h78 , 24'h558006};
        cmd_phase[188] <= {8'h78 , 24'h558340};
        cmd_phase[189] <= {8'h78 , 24'h558410};
        cmd_phase[190] <= {8'h78 , 24'h558910};
        cmd_phase[191] <= {8'h78 , 24'h558a00};
        cmd_phase[192] <= {8'h78 , 24'h558bf8};
        cmd_phase[193] <= {8'h78 , 24'h501d40};
        cmd_phase[194] <= {8'h78 , 24'h530008};
        cmd_phase[195] <= {8'h78 , 24'h530130};
        cmd_phase[196] <= {8'h78 , 24'h530210};
        cmd_phase[197] <= {8'h78 , 24'h530300};
        cmd_phase[198] <= {8'h78 , 24'h530408};
        cmd_phase[199] <= {8'h78 , 24'h530530};
        cmd_phase[200] <= {8'h78 , 24'h530608};
        cmd_phase[201] <= {8'h78 , 24'h530716};
        cmd_phase[202] <= {8'h78 , 24'h530908};
        cmd_phase[203] <= {8'h78 , 24'h530a30};
        cmd_phase[204] <= {8'h78 , 24'h530b04};
        cmd_phase[205] <= {8'h78 , 24'h530c06};
        cmd_phase[206] <= {8'h78 , 24'h502500};
        cmd_phase[207] <= {8'h78 , 24'h300802};
        cmd_phase[208] <= {8'h78 , 24'h303511};
        cmd_phase[209] <= {8'h78 , 24'h30366c}; //multi 98 60 6c 6b 6d
        cmd_phase[210] <= {8'h78 , 24'h3c0708};
        cmd_phase[211] <= {8'h78 , 24'h382045}; //flip 47
        cmd_phase[212] <= {8'h78 , 24'h382103}; //mirror 01
        cmd_phase[213] <= {8'h78 , 24'h381431};
        cmd_phase[214] <= {8'h78 , 24'h381531};
        cmd_phase[215] <= {8'h78 , 24'h380000};
        cmd_phase[216] <= {8'h78 , 24'h380100};
        cmd_phase[217] <= {8'h78 , 24'h380200};
        cmd_phase[218] <= {8'h78 , 24'h380304};
        cmd_phase[219] <= {8'h78 , 24'h38040a};
        cmd_phase[220] <= {8'h78 , 24'h38053f};
        cmd_phase[221] <= {8'h78 , 24'h380607};
        cmd_phase[222] <= {8'h78 , 24'h38079b};
        cmd_phase[223] <= {8'h78 , 24'h380802};
        cmd_phase[224] <= {8'h78 , 24'h380980};
        cmd_phase[225] <= {8'h78 , 24'h380a01};
        cmd_phase[226] <= {8'h78 , 24'h380be0};
        cmd_phase[227] <= {8'h78 , 24'h380c07}; //hts 07 07
        cmd_phase[228] <= {8'h78 , 24'h380d68}; //hts 68 90
        cmd_phase[229] <= {8'h78 , 24'h380e03}; //vts 03 04
        cmd_phase[230] <= {8'h78 , 24'h380fd8}; //vts d8 40
        cmd_phase[231] <= {8'h78 , 24'h381306};
        cmd_phase[232] <= {8'h78 , 24'h361800};
        cmd_phase[233] <= {8'h78 , 24'h361229};
        cmd_phase[234] <= {8'h78 , 24'h370952};
        cmd_phase[235] <= {8'h78 , 24'h370c03};
        cmd_phase[236] <= {8'h78 , 24'h3a0217};
        cmd_phase[237] <= {8'h78 , 24'h3a0310};
        cmd_phase[238] <= {8'h78 , 24'h3a1417};
        cmd_phase[239] <= {8'h78 , 24'h3a1510};
        cmd_phase[240] <= {8'h78 , 24'h400402};
        cmd_phase[241] <= {8'h78 , 24'h30021c};
        cmd_phase[242] <= {8'h78 , 24'h3006c3};
        cmd_phase[243] <= {8'h78 , 24'h471303};
        cmd_phase[244] <= {8'h78 , 24'h440704};
        cmd_phase[245] <= {8'h78 , 24'h460b35};
        cmd_phase[246] <= {8'h78 , 24'h460c22};
        cmd_phase[247] <= {8'h78 , 24'h483722};
        cmd_phase[248] <= {8'h78 , 24'h382402};
        cmd_phase[249] <= {8'h78 , 24'h5001a3};
        cmd_phase[250] <= {8'h78 , 24'h350300};
        cmd_phase[251] <= {8'h78 , 24'h301602};
        cmd_phase[252] <= {8'h78 , 24'h3b070a};
        cmd_phase[253] <= {8'h78 , 24'h3b0083};
        cmd_phase[254] <= {8'h78 , 24'h3b0000};

//light values
        cmd_phase[255] <= {8'h78 , 24'h340601};
        cmd_phase[256] <= {8'h78 , 24'h340004};
        cmd_phase[257] <= {8'h78 , 24'h340100};
        cmd_phase[258] <= {8'h78 , 24'h340204};
        cmd_phase[259] <= {8'h78 , 24'h340300};
        cmd_phase[260] <= {8'h78 , 24'h340404};
        cmd_phase[261] <= {8'h78 , 24'h340500};

//end
        cmd_phase[262] <= {8'hff , 24'hffffff};

    end

//========================================================
// FSM states
//========================================================    
    localparam ST_POWER_START  = 0; //Powerup sequence
    localparam ST_DELAY_5MS    = 1;
    localparam ST_DELAY_1MS    = 2;
    localparam ST_DELAY_20MS   = 3;

    localparam ST_HOLD_LOW     = 4; //I2C configuration
    localparam ST_WAIT_TRIGGER = 5;
    localparam ST_RELEASE      = 6;
    localparam ST_WAIT_5MS     = 7;
    localparam ST_LOAD_CMD     = 8;
    localparam ST_START_COND   = 9;
    localparam ST_SEND_BYTE    = 10;
    localparam ST_ACK_BIT      = 11;
    localparam ST_STOP_COND    = 12;
    localparam ST_NEXT_CMD     = 13;
    localparam ST_DONE         = 14;

    reg [3:0] state;
    reg [4:0] bit_index;
    reg [1:0] byte_index;
    reg [8:0] cmd_index;
    reg [15:0] clk_cnt;
    reg [7:0] curr_byte;
    reg [7:0] cmd_count;
    reg       ack_fail;
    reg [31:0] wait_cnt;
    reg xclk_en;

    assign cam_xvclk = xclk_en ? cam_clk : 1'b0;

    //========================================================
    // Main FSM
    //========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_POWER_START;
            wait_cnt      <= 32'd0;
            clk_cnt       <= 16'd0;
            bit_index     <= 5'd7;
            byte_index    <= 2'd0;
            cmd_index     <= 9'd0;
            curr_byte     <= 8'd0;
            ack_fail      <= 1'b0;

            busy          <= 1'b1;
            done          <= 1'b0;
            error         <= 1'b0;
            cam_done <= 1'b0;
            //led_1 <= 1'b0;
        end 
        else begin
            case (state)

                //============================================
                // Hold both lines low after reset
                //============================================
                ST_POWER_START:begin

                    cam_pwdn  <= 1'b1;
                    cam_rst_n <= 1'b0;
                    wait_cnt  <= 32'd0;
                    state <= ST_DELAY_5MS;

                end

                ST_DELAY_5MS: begin
                    if(wait_cnt >= WAIT_5MS-1) begin

                        cam_pwdn <= 1'b0;
                        xclk_en <= 1'b1;
                        wait_cnt <= 32'd0;
                        state <= ST_DELAY_1MS;

                    end else begin      

                        wait_cnt <= wait_cnt + 1'b1; 
                      
                    end
                end

                ST_DELAY_1MS: begin
                    if(wait_cnt >= WAIT_1MS-1) begin
                        
                        cam_rst_n <= 1'b1;
                        wait_cnt <= 32'd0;
                        state <= ST_DELAY_20MS;

                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                    
                end

                ST_DELAY_20MS: begin
                    if(wait_cnt >= WAIT_20MS-1) begin
                        
                        wait_cnt <= 32'd0;
                        state <= ST_HOLD_LOW;
                        
                    end else begin

                        wait_cnt <= wait_cnt + 1'b1;
                        
                    end

                end

                ST_HOLD_LOW: begin
                    busy    <= 1'b1;
                    done    <= 1'b0;
                    error   <= 1'b0;
                    sda_1   <= 1'b0;
                    scl_1   <= 1'b0;
                    wait_cnt<= 32'd0;
                    state   <= ST_WAIT_TRIGGER;
                    //led_1 <= 1'b0;
                end

                //============================================
                // Wait for trigger
                //============================================
                ST_WAIT_TRIGGER: begin
                    sda_1 <= 1'b0;
                    scl_1 <= 1'b0;
                    state <= ST_RELEASE;
                end

                //============================================
                // Release both lines, then wait 90 ms
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
                        wait_cnt      <= 32'd0;
                        state      <= ST_LOAD_CMD;
                        //led_1 <= 1'b1;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                //============================================
                // Load next command
                //============================================
                ST_LOAD_CMD: begin

                    if (cmd_index == 2 && wait_cnt <= WAIT_10MS-1) begin

                        wait_cnt <= wait_cnt + 1'b1; 

                    end else if (cmd_phase[cmd_index][31:24] == 8'hff) begin

                        state <= ST_DONE;
                
                    end else begin

                        wait_cnt <= 32'd0;
                        byte_index <= 2'd0;
                        bit_index  <= 5'd7;
                        clk_cnt    <= 16'd0;
                        ack_fail   <= 1'b0;
                        curr_byte  <= cmd_phase[cmd_index][31:24]; // dev addr
                        state      <= ST_START_COND;
                    end
                    
                end

                //============================================
                // START: SDA falls while SCL released/high
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
                    if (clk_cnt == 0) begin
                        scl_1 <= 1'b0;
                    end

                    if (clk_cnt == 1) begin
                        sda_1 <= curr_byte[bit_index];
                    end

                    if (clk_cnt == HALF_PERIOD) begin
                        scl_1 <= 1'bz;
                    end

                    if (clk_cnt >= (HALF_PERIOD * 2 - 1)) begin
                        clk_cnt <= 16'd0;
                        if (bit_index == 0) begin
                            sda_1  <= 1'bz;
                            state  <= ST_ACK_BIT;
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

                    if (clk_cnt == HALF_PERIOD) begin
                        scl_1 <= 1'bz;
                    end

                    if (clk_cnt >= (HALF_PERIOD * 2 - 1)) begin
                        clk_cnt <= 16'd0;

                        if (byte_index == 0) begin
                            byte_index <= 2'd1;
                            bit_index  <= 5'd7;
                            curr_byte  <= cmd_phase[cmd_index][23:16];  // reg addr [7:0]
                            state      <= ST_SEND_BYTE;
                        end else if (byte_index == 1) begin
                            byte_index <= 2'd2;
                            bit_index  <= 5'd7;
                            curr_byte  <= cmd_phase[cmd_index][15:8];   // reg addr [15:8]
                            state      <= ST_SEND_BYTE;
                        end else if (byte_index == 2) begin
                            byte_index <= 2'd3;
                            bit_index  <= 5'd7;
                            curr_byte  <= cmd_phase[cmd_index][7:0];   // data
                            state      <= ST_SEND_BYTE;
                        end else begin
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
                    if (clk_cnt == HALF_PERIOD) begin
                        scl_1 <= 1'bz;
                    end
                    if (clk_cnt == HALF_PERIOD * 2) begin
                        sda_1 <= 1'bz;
                    end

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
                    if (ack_fail) begin
                        error <= 1'b1;      // latch that at least one error happened
                        state <= ST_LOAD_CMD; // retry same command
                    end else begin
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
                    busy <= 1'b0;
                    done <= 1'b1;
                    sda_1 <= 1'bz;
                    scl_1 <= 1'bz;
                    cam_done <= 1'b1;
                    state <= ST_DONE;
                end

                default: begin
                    state <= ST_POWER_START;
                end
            endcase
        end
    end

endmodule