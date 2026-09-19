// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
//
// Testbench propio del juego (sw/game.s / sw/game.hex). A diferencia de
// tb/game_top_tb.v (que ejerce el debounce con sw/buttons_leds.hex sin
// saber nada del juego), este testbench aprieta botones "limpios" (sin
// rebote inyectado -- eso ya lo cubre el otro testbench) y verifica la
// máquina de estados completa: pantalla de inicio, los 4 LEDs por ronda,
// el LED objetivo, aciertos, errores y el promedio final.
//
// CÓMO SE LEE EL OBJETIVO DE CADA RONDA
// --------------------------------------
// El objetivo sale de 2 bits bajos de un LFSR que corre en software y que
// nunca se reinicia; replicarlo bit a bit en el testbench (incluyendo el
// conteo exacto de ciclos que el jugador tarda en reaccionar) sería frágil.
// En cambio, se espía `led_q`/`digit_q` por acceso jerárquico -- exactamente
// lo que el programa escribió en LEDS/DISP, igual que tb/game_top_tb.v --
// para saber qué botón apretar y cuándo el estado ya cambió.
//
// TODO SE SINCRONIZA POR EVENTOS, NO POR ESPERAS FIJAS
// -------------------------------------------------------
// Una espera de duración fija después de apretar un botón es una carrera:
// el debounce (ver abajo) puede tardar mucho menos que el margen que se le
// da, y para cuando el testbench termina de esperar, la máquina de estados
// ya pudo haber avanzado una o más rondas y sobreescrito DISP/LEDS. Por eso
// cada paso espera un CAMBIO observable (LEDS que se aparta del objetivo,
// DISP que llega a cierto valor) con un timeout generoso como techo de
// seguridad, nunca una espera ciega.
//
// POR QUÉ TODOS LOS ACIERTOS VAN A MOSTRAR "99"
// -----------------------------------------------
// El debounce (rtl/debounce.v) usa un tick de 2^15 = 32768 ciclos, fijo,
// sin importar CyclesPerTenth -- no es un parámetro que este testbench
// pueda reducir sin tocar rtl/. Con CyclesPerTenth=25 (el valor que pide
// el enunciado de este frente para que las diez rondas corran en segundos
// de simulación), una sola transición de botón tarda de sobra más de 99
// décimas en registrarse limpia. O sea: en ESTE testbench, cualquier
// pulsación válida va a saturar el tiempo mostrado a MAX_TENTHS (99), por
// construcción. Lejos de ser un problema, es gratis: ejercita justo la
// lógica de saturación que pide el enunciado (uno de los dos bugs a evitar
// mencionados en el diseño de sw/game.s), sin tener que forzar tiempos de
// reacción irreales. La suma de 10 aciertos de 99 da un promedio exacto de
// 99 (990 / 10), así que el resultado final también es 100% predecible.
//
// Correr desde la raíz de pochoco_soc/ (Icarus resuelve $readmemh relativo
// al cwd del proceso, no al archivo fuente):
//   iverilog -g2012 -o /tmp/game_tb tb/game_tb.v rtl/*.v rtl/espino_core/*.v
//   vvp /tmp/game_tb
//   gtkwave game_tb.vcd

`timescale 1ns/1ps

module game_tb;

  localparam CLK_PERIOD = 40;             // 25 MHz
  localparam TICK       = 32768;          // ciclos por muestra del debounce
  localparam SETTLE     = 4 * TICK;       // margen de asentamiento (ver tb/game_top_tb.v)
  localparam TIMEOUT    = SETTLE + 10000; // techo de seguridad para esperas por evento

  // Constantes del juego (deben coincidir con los .equ de sw/game.s)
  localparam [7:0] PAT_START    = 8'h00;
  localparam [7:0] PAT_ERROR    = 8'hEE;
  localparam [7:0] PAT_AVG      = 8'hAA;
  localparam [7:0] AVG_EXPECTED = 8'h99;   // ver nota de cabecera: 10 aciertos de 99
  localparam RONDAS        = 10;
  localparam MISS_ON_ROUND = 3;            // en qué ronda (1..9) se ejerce un error

  reg        clk;
  reg  [3:0] switch;
  wire [3:0] led;
  wire       seg1_a, seg1_b, seg1_c, seg1_d, seg1_e, seg1_f, seg1_g;
  wire       seg2_a, seg2_b, seg2_c, seg2_d, seg2_e, seg2_f, seg2_g;

  integer errors;
  integer round_idx;

  game_top #(
    .MemFile        ("sw/game.hex"),
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
  wire [7:0]  disp_q = dut.u_soc.u_periph.digit_q;
  wire [3:0]  led_q  = dut.u_soc.u_periph.led_q;

  always #(CLK_PERIOD/2) clk = ~clk;

  task wait_cycles(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  task check(input ok_in, input [8*96-1:0] label);
    begin
      if (!ok_in) begin
        $display("FAIL @%0t: %0s", $time, label);
        errors = errors + 1;
      end else begin
        $display("ok   @%0t: %0s", $time, label);
      end
    end
  endtask

  // Espera hasta que led_q == val, o hasta agotar timeout ciclos.
  task wait_led_eq(input [3:0] val, input integer timeout, output reg ok);
    integer i;
    begin
      ok = (led_q === val);
      for (i = 0; i < timeout && !ok; i = i + 1) begin
        @(posedge clk);
        if (led_q === val) ok = 1'b1;
      end
    end
  endtask

  // Espera hasta que disp_q == val, o hasta agotar timeout ciclos.
  task wait_disp_eq(input [7:0] val, input integer timeout, output reg ok);
    integer i;
    begin
      ok = (disp_q === val);
      for (i = 0; i < timeout && !ok; i = i + 1) begin
        @(posedge clk);
        if (disp_q === val) ok = 1'b1;
      end
    end
  endtask

  // Espera hasta que led_q sea distinto de cero y de un solo bit (el LED
  // objetivo de la ronda), capturándolo en `target`.
  task wait_led_onehot(output reg [3:0] target_out, input integer timeout, output reg ok);
    integer i;
    reg [3:0] v;
    begin
      ok = 1'b0;
      target_out = 4'b0000;
      for (i = 0; i < timeout && !ok; i = i + 1) begin
        @(posedge clk);
        v = led_q;
        if (v != 4'b0000 && (v & (v - 4'b0001)) == 4'b0000) begin
          ok = 1'b1;
          target_out = v;
        end
      end
    end
  endtask

  // Espera hasta que led_q se aparte de `from_val` (la ronda ya se
  // procesó: acierto -> round_begin escribe 0xF; error -> miss apaga los
  // LEDs), capturando el nuevo valor en `new_val`.
  task wait_led_change(input [3:0] from_val, input integer timeout, output reg [3:0] new_val, output reg ok);
    integer i;
    begin
      ok = 1'b0;
      new_val = from_val;
      for (i = 0; i < timeout && !ok; i = i + 1) begin
        @(posedge clk);
        if (led_q !== from_val) begin
          ok = 1'b1;
          new_val = led_q;
        end
      end
    end
  endtask

  // Devuelve una máscara de un solo bit garantizada distinta de `t`, para
  // forzar un error deliberado.
  function [3:0] wrong_button(input [3:0] t);
    begin
      if (t !== 4'b0001) wrong_button = 4'b0001;
      else                wrong_button = 4'b0010;
    end
  endfunction

  reg [3:0] target;
  reg [3:0] new_led;
  reg       ok;
  reg [7:0] round_number_before;

  // -- Una ronda con pulsación correcta ------------------------------------
  task play_hit_round;
    begin
      wait_led_eq(4'b1111, TIMEOUT, ok);
      check(ok, "round_begin: los 4 LEDs se encienden");
      wait_cycles(100);   // deja que show_bcd(ronda) termine de escribir DISP

      wait_led_onehot(target, TIMEOUT, ok);
      check(ok, "arm: se enciende exactamente un LED (el objetivo)");

      switch = target;
      wait_led_change(target, TIMEOUT, new_led, ok);
      check(ok, "hit: la ronda se procesa tras la pulsacion correcta");
      check(disp_q === AVG_EXPECTED,
            "hit: tiempo de reaccion valido y saturado a 99 (ver cabecera)");

      switch = 4'b0000;
    end
  endtask

  // -- Una ronda con un error deliberado, seguido del reintento correcto --
  task play_miss_then_hit_round;
    reg [3:0] wrong;
    begin
      wait_led_eq(4'b1111, TIMEOUT, ok);
      check(ok, "round_begin: los 4 LEDs se encienden (antes del error)");
      wait_cycles(100);
      round_number_before = disp_q;

      wait_led_onehot(target, TIMEOUT, ok);
      check(ok, "arm: se enciende exactamente un LED (antes del error)");

      wrong = wrong_button(target);
      switch = wrong;
      wait_led_change(target, TIMEOUT, new_led, ok);
      check(ok, "miss: la ronda se procesa tras la pulsacion incorrecta");
      check(new_led === 4'b0000, "miss: LEDS quedan apagados");
      check(disp_q === PAT_ERROR, "miss: DISP muestra EE");

      switch = 4'b0000;

      // Reintento de la MISMA ronda: los 4 LEDs de nuevo, mismo número.
      wait_led_eq(4'b1111, TIMEOUT, ok);
      check(ok, "miss: vuelve a la fase de los 4 LEDs (reintento)");
      wait_cycles(100);
      check(disp_q === round_number_before,
            "miss: el numero de ronda no avanzo (aciertos no se pierden)");

      wait_led_onehot(target, TIMEOUT, ok);
      check(ok, "miss: el reintento arma un nuevo objetivo");

      switch = target;
      wait_led_change(target, TIMEOUT, new_led, ok);
      check(ok, "miss+hit: la ronda se procesa tras la pulsacion correcta");
      check(disp_q === AVG_EXPECTED,
            "miss+hit: tiempo de reaccion valido y saturado a 99");

      switch = 4'b0000;
    end
  endtask

  initial begin
    $dumpfile("game_tb.vcd");
    $dumpvars(0, game_tb);

    errors = 0;
    clk    = 1'b0;
    switch = 4'b0000;

    // Deja pasar el power-on reset interno de pochoco_soc (16 ciclos) más
    // la inicialización de _start/start_screen.
    wait_cycles(200);

    // === START_SCREEN ===================================================
    check(disp_q === PAT_START && led_q === 4'b0000,
          "pantalla de inicio: 00, LEDs apagados");

    switch = 4'b0001;      // cualquier botón siembra el LFSR y arranca
    wait_cycles(SETTLE);   // garantiza que la pulsacion se registre
    switch = 4'b0000;      // suelta; el que sigue espera lo que haga falta

    // === RONDAS 1..9 (una de ellas con un error deliberado) =============
    for (round_idx = 1; round_idx <= RONDAS - 1; round_idx = round_idx + 1) begin
      if (round_idx == MISS_ON_ROUND) play_miss_then_hit_round;
      else                             play_hit_round;
    end

    // === RONDA 10 -- termina en FINISH ==================================
    wait_led_eq(4'b1111, TIMEOUT, ok);
    check(ok, "round_begin: los 4 LEDs se encienden (ultima ronda)");
    wait_cycles(100);

    wait_led_onehot(target, TIMEOUT, ok);
    check(ok, "arm: se enciende exactamente un LED (objetivo de la ultima ronda)");

    switch = target;

    // Tras el décimo acierto el programa entra a FINISH: primero PAT_AVG,
    // luego el promedio. Ninguno de los dos toca LEDS todavía (eso ocurre
    // recién en finish_blink), así que hay que esperar por DISP, no por LEDS.
    wait_disp_eq(PAT_AVG, TIMEOUT, ok);
    check(ok, "finish: DISP muestra AA (patron de promedio)");

    wait_disp_eq(AVG_EXPECTED, 5000, ok);
    check(ok, "finish: el promedio de las diez rondas es 99 (990/10, ver cabecera)");

    switch = 4'b0000;

    // -- Los LEDs deben parpadear mientras se espera una pulsación -------
    begin : blink_check
      reg seen_off, seen_on;
      integer k;
      seen_off = 1'b0;
      seen_on  = 1'b0;
      for (k = 0; k < 500; k = k + 1) begin
        @(posedge clk);
        if (led_q === 4'b0000) seen_off = 1'b1;
        if (led_q === 4'b1111) seen_on  = 1'b1;
      end
      check(seen_off && seen_on,
            "finish: los LEDs alternan entre apagado y encendido (parpadeo)");
    end

    // -- Una pulsación vuelve a INIT. Se comprueba MIENTRAS se sostiene el
    // botón: start_screen escribe PAT_START/LEDS=0 y se queda esperando a
    // que se suelte, así que el valor es estable para verificarlo (si se
    // soltara antes de chequear, el programa ya podría haber avanzado a
    // round_begin y sobreescrito DISP).
    switch = 4'b0001;
    wait_cycles(SETTLE);
    check(disp_q === PAT_START && led_q === 4'b0000,
          "una pulsacion en finish vuelve a la pantalla de inicio");
    switch = 4'b0000;

    if (errors == 0) $display("\n=== PASS: todos los checks OK ===");
    else              $display("\n=== FAIL: %0d check(s) fallaron ===", errors);

    $finish;
  end

endmodule
