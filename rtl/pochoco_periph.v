// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
// 
// Authors:
// - Nicolás Villegas <navillegas@miuandes.cl>

module pochoco_periph #(
  parameter CyclesPerTenth = 2_500_000,  // 25 MHz / 10 Hz
  parameter DebounceTicks  = 3           // muestras estables para aceptar un cambio
) (
  input  wire        clk_i,
  input  wire        rst_ni,
  input  wire        sel_i,
  input  wire        req_i,
  input  wire        we_i,
  input  wire [7:0]  addr_i,
  input  wire [31:0] wdata_i,
  output reg  [31:0] rdata_o,
  output wire [3:0]  leds_o,
  input  wire [3:0]  btn_i,
  output wire [6:0]  seg1_o,
  output wire [6:0]  seg2_o
);

  wire [5:0] off    = addr_i[7:2];
  wire       access = sel_i & req_i;

  // Debounce de los botones: se intercala entre btn_i y la lectura del
  // offset 2. Offsets 0/1/2 mantienen la misma dirección y semántica de
  // siempre; lo único que cambia es que el offset 2 ya no ve el nivel
  // crudo sino el filtrado.
  wire [3:0] btn_clean;

  debounce4 #(
    .Ticks   (DebounceTicks),
    .DivBits (15)
  ) u_debounce (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .raw_i   (btn_i),
    .clean_o (btn_clean)
  );

  // CYCLES: contador libre de ciclos a 25 MHz. TENTHS: contador libre de
  // décimas de segundo, vía un comparador exacto contra CyclesPerTenth
  // (no es potencia de 2, así que no sirve el truco del acarreo). Los
  // dos de solo lectura, sin start/stop/clear por software.
  localparam integer TenthCntW = $clog2(CyclesPerTenth);

  reg [31:0]           cycles_q;
  reg [TenthCntW-1:0]  tenth_cnt;
  reg [31:0]           tenths_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycles_q  <= 32'b0;
      tenth_cnt <= {TenthCntW{1'b0}};
      tenths_q  <= 32'b0;
    end else begin
      cycles_q <= cycles_q + 32'd1;
      if (tenth_cnt == CyclesPerTenth - 1) begin
        tenth_cnt <= {TenthCntW{1'b0}};
        tenths_q  <= tenths_q + 32'd1;
      end else begin
        tenth_cnt <= tenth_cnt + 1'b1;
      end
    end
  end

  // LEDs and raw digit registers
  reg [3:0]  led_q;
  reg [7:0]  digit_q;
  
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      led_q   <= 4'b0;
      digit_q <= 8'b0;
    end else if (access & we_i) begin
      case (off)
        6'd0: digit_q <= wdata_i[7:0];
        6'd1: led_q   <= wdata_i[3:0];
        default: ;
      endcase
    end
  end

  assign leds_o = led_q;

  // Hex to 7-segment decoder function
  function [6:0] hex2seg;
    input [3:0] hex;
    begin
      case (hex)
        4'h0: hex2seg = 7'b0111111; // 0
        4'h1: hex2seg = 7'b0000110; // 1
        4'h2: hex2seg = 7'b1011011; // 2
        4'h3: hex2seg = 7'b1001111; // 3
        4'h4: hex2seg = 7'b1100110; // 4
        4'h5: hex2seg = 7'b1101101; // 5
        4'h6: hex2seg = 7'b1111101; // 6
        4'h7: hex2seg = 7'b0000111; // 7
        4'h8: hex2seg = 7'b1111111; // 8
        4'h9: hex2seg = 7'b1101111; // 9
        4'hA: hex2seg = 7'b1110111; // A
        4'hB: hex2seg = 7'b1111100; // b
        4'hC: hex2seg = 7'b0111001; // C
        4'hD: hex2seg = 7'b1011110; // d
        4'hE: hex2seg = 7'b1111001; // E
        4'hF: hex2seg = 7'b1110001; // F
        default: hex2seg = 7'b0000000;
      endcase
    end
  endfunction

  assign seg1_o = hex2seg(digit_q[7:4]);
  assign seg2_o = hex2seg(digit_q[3:0]);

  // Registered read data
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rdata_o <= 32'b0;
    else if (access & ~we_i) begin
      case (off)
        6'd2: rdata_o <= {28'b0, btn_clean}; // Buttons, debounced
        6'd3: rdata_o <= cycles_q;           // CYCLES
        6'd4: rdata_o <= tenths_q;           // TENTHS
        default: rdata_o <= 32'b0;
      endcase
    end
  end

endmodule