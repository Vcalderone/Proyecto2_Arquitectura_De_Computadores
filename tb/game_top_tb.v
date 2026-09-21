// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
//
// Testbench de iverilog para game_top: ejerce la cadena de entrada de los
// botones -- sincronizador de 2 flip-flops (rtl/pochoco_periph.v) y
// debounce (rtl/debounce.v) -- apretando botones en tiempos guionados con
// rebote inyectado, y comprueba que las LEDs solo sigan al valor filtrado,
// nunca al crudo. También revisa CYCLES por acceso jerárquico.
//
// No sabe nada del juego: el firmware cargado es sw/buttons_leds.hex, uno
// de los tres tests de oro del assembler, que espeja BTN -> LEDS en loop.
// La máquina de estados del juego la cubre tb/game_tb.v.
//
// DebounceDivBits se pisa a 10 (tick cada 2^10 = 1024 ciclos, en vez de
// 2^15 = 32768) para que el testbench corra rápido, y los pulsos de rebote
// inyectados van escalados a esa misma base: un rebote tiene que ser corto
// FRENTE AL TICK, no corto en valor absoluto, o deja de ser un rebote.
//
// El tick viene de un contador libre de DivBits bits, así que una ventana
// de N*TICK ciclos contiene exactamente N ticks. De ahí salen los dos
// márgenes que usa este testbench:
//   - SETTLE = 4*TICK  -> 4 ticks >= los 3 (DebounceTicks) que hacen falta
//     para aceptar un cambio: garantiza que el valor final ya se asentó.
//   - Toda la secuencia de rebote dura menos de un TICK, así que como mucho
//     una muestra cae dentro del rebote. Con 3 muestras necesarias, ni el
//     rebote ni un tick posterior alcanzan a mover clean_o.
//
// Correr desde la raíz del proyecto (Icarus resuelve $readmemh relativo al
// cwd del proceso, no al archivo fuente). Con `make sim`, o a mano:
//   iverilog -g2012 -o build/game_top_tb tb/game_top_tb.v rtl/*.v \
//            rtl/espino_core/*.v $(yosys-config --datdir)/ice40/cells_sim.v
//   vvp build/game_top_tb
//   gtkwave game_top_tb.vcd

`timescale 1ns/1ps

module game_top_tb;

  localparam CLK_PERIOD  = 40;        // 25 MHz
  localparam DIV_BITS    = 10;
  localparam TICK        = 1 << DIV_BITS; // ciclos por muestra del debounce
  localparam SETTLE      = 4 * TICK;      // >= 3 ticks de estabilidad, con margen
  localparam BOUNCE      = 20;            // ancho de cada pulso de rebote

  reg        clk;
  reg  [3:0] switch;
  wire [3:0] led;
  wire       seg1_a, seg1_b, seg1_c, seg1_d, seg1_e, seg1_f, seg1_g;
  wire       seg2_a, seg2_b, seg2_c, seg2_d, seg2_e, seg2_f, seg2_g;

  integer errors;

  game_top #(
    .MemFile         ("sw/buttons_leds.hex"),
    .DebounceDivBits (DIV_BITS)
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
  wire [31:0] cycles_q  = dut.u_soc.u_periph.cycles_q;
  wire [3:0]  btn_sync  = dut.u_soc.u_periph.btn_sync;
  wire [3:0]  btn_clean = dut.u_soc.u_periph.btn_clean;

  always #(CLK_PERIOD/2) clk = ~clk;

  task wait_cycles(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  task check(input ok_in, input [8*128-1:0] label);
    begin
      if (!ok_in) begin
        $display("FAIL @%0t: %0s", $time, label);
        errors = errors + 1;
      end else begin
        $display("ok   @%0t: %0s", $time, label);
      end
    end
  endtask

  task check4(input [3:0] expected, input [8*128-1:0] label);
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

    // Deja pasar el power-on reset interno de pochoco_soc más unas vueltas
    // del loop de buttons_leds.s. Se espera a rst_ni en vez de contar
    // ciclos para no depender de cuánto dura el reset.
    wait (dut.u_soc.rst_ni);
    wait_cycles(64);
    check4(4'b0000, "reposo tras reset");

    // --- Sincronizador de 2 flip-flops ----------------------------------
    // btn_i viene de un pad asíncrono y entra al debounce a través de
    // btn_meta/btn_sync. Dos flancos después de mover i_Switch, btn_sync
    // ya tiene que reflejarlo; btn_clean no, porque le faltan 3 ticks (y
    // en 2 ciclos cae como mucho 1).
    switch = 4'b0100;
    wait_cycles(2);
    #1;   // epsilon: deja que se apliquen las asignaciones no bloqueantes
          // del segundo flanco antes de muestrear
    check(btn_sync  === 4'b0100, "sincronizador: btn_sync sigue a i_Switch en 2 ciclos");
    check(btn_clean === 4'b0000, "sincronizador: btn_clean todavia no se movio");

    // Se suelta enseguida: el pulso es mucho más corto que 3 ticks, así que
    // tampoco debe llegar nunca a las LEDs.
    switch = 4'b0000;
    wait_cycles(SETTLE);
    check4(4'b0000, "pulso de 2 ciclos filtrado: LEDs nunca se movieron");

    // --- Boton 0: rebote antes de asentar en 1 -------------------------
    // Toda la secuencia dura 4*BOUNCE = 80 ciclos, bastante menos que un
    // TICK, así que como mucho una muestra cae en pleno rebote.
    switch[0] = 1'b1; wait_cycles(BOUNCE);
    switch[0] = 1'b0; wait_cycles(BOUNCE);
    switch[0] = 1'b1; wait_cycles(BOUNCE);
    switch[0] = 1'b0; wait_cycles(BOUNCE);
    switch[0] = 1'b1;                       // valor final: apretado
    wait_cycles(TICK);                      // 1 tick más: 2 muestras en 1 como
                                            // mucho, y hacen falta 3
    check4(4'b0000, "boton 0 en pleno rebote, LED todavia no debe moverse");

    wait_cycles(SETTLE);
    check4(4'b0001, "boton 0 asentado -> LED0 encendido");

    // --- Boton 0: suelta con rebote -------------------------------------
    switch[0] = 1'b0; wait_cycles(BOUNCE);
    switch[0] = 1'b1; wait_cycles(BOUNCE);
    switch[0] = 1'b0;
    wait_cycles(SETTLE);
    check4(4'b0000, "boton 0 soltado y asentado -> LEDs apagadas");

    // --- Botones 1 y 3 juntos, sin rebote (caso limpio) ------------------
    switch[1] = 1'b1; switch[3] = 1'b1;
    wait_cycles(SETTLE);
    check4(4'b1010, "botones 1 y 3 -> LED1 y LED3 encendidas");

    // --- Pulsacion sostenida corta (rebote), no debe leerse como cambio --
    // Un cero suelto deja el registro de desplazamiento con valores mixtos:
    // ni set (&sr) ni clr (~|sr), así que clean_o retiene.
    switch[1] = 1'b0; wait_cycles(BOUNCE);
    switch[1] = 1'b1; wait_cycles(BOUNCE);
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

    if (errors == 0) begin
      $display("\n=== PASS: todos los checks OK ===");
      $finish;
    end else begin
      $fatal(1, "\n=== FAIL: %0d check(s) fallaron ===", errors);
    end
  end

endmodule
