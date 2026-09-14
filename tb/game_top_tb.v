// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
//
// Testbench de iverilog para game_top: aprieta botones en tiempos
// guionados (con rebote inyectado) y deja ver en gtkwave que las LEDs
// solo siguen al valor filtrado, no al crudo. También revisa CYCLES y
// TENTHS por acceso jerárquico, sin depender de sw/game.s (todavía un
// esqueleto): el firmware cargado es sw/buttons_leds.hex, uno de los
// tres tests de oro del assembler, que ya espeja BTN -> LEDS en loop.
//
// CyclesPerTenth se pisa a 25 (en vez de 2 500 000) para que TENTHS
// avance a un ritmo observable en simulación, tal como exige el
// contrato de docs/memory_map.md. DebounceTicks se deja en su default
// (3): el tick de muestreo es de 2^15 ciclos, así que igual corre en
// segundos de wall-clock, no minutos.
//
// Correr desde la raíz de pochoco_soc/ (Icarus resuelve $readmemh
// relativo al cwd del proceso, no al archivo fuente):
//   iverilog -g2012 -o /tmp/game_top_tb tb/game_top_tb.v rtl/*.v rtl/espino_core/*.v
//   vvp /tmp/game_top_tb
//   gtkwave game_top_tb.vcd

`timescale 1ns/1ps

module game_top_tb;

  localparam CLK_PERIOD = 40;      // 25 MHz
  localparam TICK       = 32768;   // ciclos por muestra del debounce
  localparam SETTLE     = 4 * TICK; // >= 3 ticks de estabilidad, con margen

  reg        clk;
  reg  [3:0] switch;
  wire [3:0] led;
  wire       seg1_a, seg1_b, seg1_c, seg1_d, seg1_e, seg1_f, seg1_g;
  wire       seg2_a, seg2_b, seg2_c, seg2_d, seg2_e, seg2_f, seg2_g;

  integer errors;

  game_top #(
    .MemFile        ("sw/buttons_leds.hex"),
    .CyclesPerTenth (25)
  ) dut (
    .i_Clk        (clk),
    .o_LED        (led),
    .i_Switch     (switch),
    .o_Segment1_A (seg1_a), .o_Segment1_B (seg1_b), .o_Segment1_C (seg1_c),
    .o_Segment1_D (seg1_d), .o_Segment1_E (seg1_e), .o_Segment1_F (seg1_f),
    .o_Segment1_G (seg1_g),
    .o_Segment2_A (seg2_a), .o_Segment2_B (seg2_b), .o_Segment2_C (seg2_c),
    .o_Segment2_D (seg2_d), .o_Segment2_E (seg2_e), .o_Segment2_F (seg2_f),
    .o_Segment2_G (seg2_g),
    .i_SPI_SCLK   (1'b0),
    .i_SPI_MOSI   (1'b0),
    .i_SPI_CS_n   (1'b1),
    .o_SPI_MISO   ()
  );

  // Acceso jerárquico a estado interno, solo para verificación/gtkwave.
  // No hace falta que game.s/game.hex exista para esto.
  wire [31:0] cycles_q  = dut.u_soc.u_periph.cycles_q;
  wire [31:0] tenths_q  = dut.u_soc.u_periph.tenths_q;
  wire [3:0]  btn_clean = dut.u_soc.u_periph.btn_clean;

  always #(CLK_PERIOD/2) clk = ~clk;

  task wait_cycles(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  task check4(input [3:0] expected, input [127:0] label);
    begin
      if (led !== expected) begin
        $display("FAIL @%0t: %0s -- o_LED=%b, esperado %b", $time, label, led, expected);
        errors = errors + 1;
      end else begin
        $display("ok   @%0t: %0s -- o_LED=%b", $time, label, led);
      end
    end
  endtask

  initial begin
    $dumpfile("game_top_tb.vcd");
    $dumpvars(0, game_top_tb);

    errors = 0;
    clk    = 1'b0;
    switch = 4'b0000;

    // Deja pasar el power-on reset interno de pochoco_soc (16 ciclos)
    // más unas vueltas del loop de buttons_leds.s.
    wait_cycles(64);
    check4(4'b0000, "reposo tras reset");

    // --- Boton 0: rebote antes de asentar en 1 -------------------------
    switch[0] = 1'b1; wait_cycles(500);
    switch[0] = 1'b0; wait_cycles(500);
    switch[0] = 1'b1; wait_cycles(500);
    switch[0] = 1'b0; wait_cycles(500);
    switch[0] = 1'b1;                       // valor final: apretado
    wait_cycles(2 * TICK);                  // aun dentro de la ventana de rebote
    check4(4'b0000, "boton 0 en pleno rebote, LED todavia no debe moverse");

    wait_cycles(SETTLE);
    check4(4'b0001, "boton 0 asentado -> LED0 encendido");

    // --- Boton 0: suelta con rebote -------------------------------------
    switch[0] = 1'b0; wait_cycles(500);
    switch[0] = 1'b1; wait_cycles(500);
    switch[0] = 1'b0;
    wait_cycles(SETTLE);
    check4(4'b0000, "boton 0 soltado y asentado -> LEDs apagadas");

    // --- Botones 1 y 3 juntos, sin rebote (caso limpio) ------------------
    switch[1] = 1'b1; switch[3] = 1'b1;
    wait_cycles(SETTLE);
    check4(4'b1010, "botones 1 y 3 -> LED1 y LED3 encendidas");

    // --- Pulsacion sostenida corta (rebote), no debe leerse como cambio --
    switch[1] = 1'b0; wait_cycles(200);
    switch[1] = 1'b1; wait_cycles(200);
    check4(4'b1010, "glitch mas corto que un tick -> sin efecto en LEDs");

    switch = 4'b0000;
    wait_cycles(SETTLE);
    check4(4'b0000, "todo soltado y asentado");

    // --- CYCLES: contador libre, +1 exacto por ciclo ---------------------
    begin : cycles_check
      reg [31:0] c0, c1;
      c0 = cycles_q;
      wait_cycles(1000);
      c1 = cycles_q;
      if (c1 - c0 !== 32'd1000) begin
        $display("FAIL: CYCLES avanzo %0d en 1000 ciclos, esperado 1000", c1 - c0);
        errors = errors + 1;
      end else begin
        $display("ok   : CYCLES avanzo exactamente 1000 en 1000 ciclos");
      end
    end

    // --- TENTHS: con CyclesPerTenth=25, debe avanzar 1 cada 25 ciclos -----
    begin : tenths_check
      reg [31:0] t0, t1;
      integer    n_periods;
      t0 = tenths_q;
      n_periods = 40;                 // 40 * 25 = 1000 ciclos
      wait_cycles(n_periods * 25);
      t1 = tenths_q;
      if (t1 - t0 !== n_periods) begin
        $display("FAIL: TENTHS avanzo %0d en %0d periodos, esperado %0d",
                  t1 - t0, n_periods, n_periods);
        errors = errors + 1;
      end else begin
        $display("ok   : TENTHS avanzo exactamente %0d en %0d ciclos", n_periods, n_periods * 25);
      end
    end

    if (errors == 0) $display("\n=== PASS: todos los checks OK ===");
    else              $display("\n=== FAIL: %0d check(s) fallaron ===", errors);

    $finish;
  end

endmodule
