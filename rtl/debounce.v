// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
//
// Reescritura conductual del debounce del Proyecto 1 (antes a nivel de
// compuerta). Misma latencia (Ticks muestras estables), misma polaridad
// (activo en alto: 1 = apretado), pensado para los 4 botones de la Go
// Board con un solo generador de tick compartido.

// Contador libre de DivBits bits; tick_o dura un ciclo cada 2^DivBits
// ciclos de clk_i (con DivBits=15 a 25 MHz: cada 1,31 ms, igual que el
// prescaler del Proyecto 1).
module debounce_tick #(
  parameter integer DivBits = 15
) (
  input  wire clk_i,
  input  wire rst_ni,
  output wire tick_o
);
  reg [DivBits-1:0] cnt;

  always @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) cnt <= {DivBits{1'b0}};
    else         cnt <= cnt + 1'b1;

  assign tick_o = &cnt;
endmodule

// Acepta raw_i como nuevo valor de clean_o solo tras Ticks muestras (a
// razón de tick_i) consecutivas e iguales -- misma idea que el registro
// de desplazamiento a nivel de compuerta del Proyecto 1, generalizada a
// Ticks bits: set = todas en 1, clr = todas en 0, si no retiene. Un
// rebote deja el registro con valores mixtos, así que ni set ni clr se
// activan y clean_o no se mueve.
module debounce #(
  parameter integer Ticks = 3
) (
  input  wire clk_i,
  input  wire rst_ni,
  input  wire tick_i,
  input  wire raw_i,
  output reg  clean_o
);
  reg [Ticks-1:0] sr;

  wire set = &sr;
  wire clr = ~|sr;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sr      <= {Ticks{1'b0}};
      clean_o <= 1'b0;
    end else if (tick_i) begin
      sr <= (sr << 1) | raw_i;
      if (set) clean_o <= 1'b1;
      else if (clr) clean_o <= 1'b0;
    end
  end
endmodule

// Cuatro debounce independientes sobre un tick compartido: es el módulo
// que se intercala entre btn_i y la lectura del offset 2 en
// pochoco_periph.v.
module debounce4 #(
  parameter integer Ticks   = 3,
  parameter integer DivBits = 15
) (
  input  wire       clk_i,
  input  wire       rst_ni,
  input  wire [3:0] raw_i,
  output wire [3:0] clean_o
);
  wire tick;

  debounce_tick #(.DivBits(DivBits)) u_tick (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .tick_o (tick)
  );

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_btn
      debounce #(.Ticks(Ticks)) u_db (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .tick_i  (tick),
        .raw_i   (raw_i[i]),
        .clean_o (clean_o[i])
      );
    end
  endgenerate
endmodule
