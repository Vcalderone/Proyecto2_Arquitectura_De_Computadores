// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
//
// Testbench propio del juego (sw/game.s). A diferencia de
// tb/game_top_tb.v, que ejerce la cadena de entrada de los botones con
// sw/buttons_leds.hex y sin saber nada del juego, este testbench aprieta
// botones limpios (sin rebote inyectado) y verifica la máquina de estados
// completa: pantalla de inicio, las RONDAS rondas, un error deliberado con
// su reintento, el patrón AA, el promedio, el parpadeo final y el reinicio.
//
// LO QUE DE VERDAD VERIFICA: LA MEDICIÓN
// ---------------------------------------
// El testbench no se limita a comprobar que el juego avance. Inyecta un
// tiempo de reacción CONOCIDO: espera exactamente REACTION_TENTHS *
// CYCLES_PER_TENTH ciclos entre que se enciende el LED objetivo y que
// aprieta el botón, y exige que el display muestre ese mismo valor en BCD.
// Si cyc2tenths contara mal, si t0 se tomara en el lugar equivocado o si la
// conversión a BCD estuviera rota, el número no cuadraría.
//
// El firmware es sw/game_sim.hex: el MISMO sw/game.s ensamblado con
// -D CYCLES_PER_TENTH=2500 (ver el Makefile de la raíz), o sea una décima
// de 2500 ciclos en vez de 2 500 000. No hay una segunda copia del programa
// que se pueda desincronizar.
//
// POR QUÉ REACTION_TENTHS = 12
// -----------------------------
// El display es el único punto de observación del tiempo medido, y durante
// los tres segundos de cada ronda muestra el NÚMERO DE RONDA: 0x01 .. 0x10.
// Con un tiempo de reacción entre 1 y 10 décimas, "esperar hasta que DISP
// valga X" se vuelve ambiguo -- podría estar mirando un número de ronda -- y
// el test deja de significar algo. 12 décimas se muestran como 0x12, que no
// colisiona con ningún número de ronda. El `initial` de abajo lo verifica en
// vez de confiar en el comentario.
//
// DOS CARRERAS REALES
// --------------------
// 1. `miss` escribe DISP y recién en la instrucción SIGUIENTE apaga los
//    LEDs. Un check de led_q en el mismo instante en que DISP llega a 0xEE
//    falla. Hay que ESPERAR el apagado, no muestrearlo.
// 2. `start_screen` escribe DISP antes que LEDS, así que al volver desde
//    finish pasa exactamente lo mismo.
//
// De ahí la regla general: NADA de esperas ciegas de duración fija después
// de apretar un botón. Cada paso espera un EVENTO observable (led_q o
// digit_q por acceso jerárquico) con un timeout generoso como techo de
// seguridad. La única espera de duración fija es la que inyecta el tiempo de
// reacción, que es justamente lo que se quiere controlar.
//
// VARIANTES
// ----------
// MEMFILE y RONDAS_N se pueden pisar desde la línea de comandos para correr
// la regresión del divisor (`make sim` la corre):
//   iverilog -g2012 -DMEMFILE=\"sw/game_sim_r4.hex\" -DRONDAS_N=4 ...
// Con RONDAS=4 el tiempo de reacción inyectado sigue siendo 12 décimas, así
// que el promedio tiene que seguir dando 12. Con un div10 clavado en vez de
// la división genérica por RONDAS daría 48/10 = 4.
//
// Correr desde la raíz del proyecto (Icarus resuelve $readmemh relativo al
// cwd del proceso, no al archivo fuente). Con `make sim`, o a mano:
//   iverilog -g2012 -o build/game_tb tb/game_tb.v rtl/*.v \
//            rtl/espino_core/*.v $(yosys-config --datdir)/ice40/cells_sim.v
//   vvp build/game_tb
// Agregar -DDUMP para generar game_tb.vcd (son ~1,6 millones de ciclos: el
// volcado completo de la jerarquía pesa cientos de MB, por eso no es el
// comportamiento por omisión).

`timescale 1ns/1ps

`ifndef MEMFILE
  `define MEMFILE "sw/game_sim.hex"
`endif

`ifndef RONDAS_N
  `define RONDAS_N 10
`endif

module game_tb;

  localparam CLK_PERIOD = 40;              // 25 MHz

  // --- Debounce -------------------------------------------------------
  // DivBits=6: tick cada 64 ciclos en vez de cada 32768. Con Ticks=3, una
  // transición de botón se acepta en ~200 ciclos, bastante menos que la
  // décima simulada de 2500 ciclos. Eso es lo que hace que el tiempo de
  // reacción inyectado se mida entero en la décima 12 y no se desborde a
  // la 13.
  localparam DIV_BITS = 6;
  localparam TICK     = 1 << DIV_BITS;
  localparam SETTLE   = 4 * TICK;          // >= 3 ticks: el valor ya se asentó

  // --- Constantes del juego (deben coincidir con los .equ de sw/game.s,
  //     con CYCLES_PER_TENTH pisado por el Makefile) -------------------
  localparam CYCLES_PER_TENTH = 2500;
  localparam RONDAS           = `RONDAS_N;
  localparam ESPERA_TENTHS    = 30;
  localparam PARPADEO_TENTHS  = 5;

  localparam [7:0] PAT_START = 8'h00;
  localparam [7:0] PAT_ERROR = 8'hEE;
  localparam [7:0] PAT_AVG   = 8'hAA;

  // --- Estímulo de la medición ----------------------------------------
  localparam REACTION_TENTHS = 12;
  localparam REACTION_CYCLES = REACTION_TENTHS * CYCLES_PER_TENTH;
  localparam [7:0] DISP_REACTION = 8'h12;  // BCD de 12

  // Ronda (1..RONDAS-1) en la que se ejerce un error deliberado.
  localparam MISS_ON_ROUND = 3;
  // El error se aprieta rápido a propósito: `miss` no mide nada, así que
  // no tiene sentido gastar décimas simuladas en él.
  localparam MISS_DELAY = 200;

  // Techo de seguridad de las esperas por evento. La más larga con
  // diferencia es la de ESPERA_TENTHS (3 s de juego = 75 000 ciclos), así
  // que el doble sobra.
  localparam TIMEOUT = 2 * ESPERA_TENTHS * CYCLES_PER_TENTH;

  // Ventana para comprobar que un estado se MANTIENE. Más larga que un
  // período completo de parpadeo, así que si el programa siguiera en
  // finish_blink en vez de haber vuelto a start_screen, se notaría.
  localparam STABLE_WIN = 3 * PARPADEO_TENTHS * CYCLES_PER_TENTH;

  reg        clk;
  reg  [3:0] switch;
  wire [3:0] led;
  wire       seg1_a, seg1_b, seg1_c, seg1_d, seg1_e, seg1_f, seg1_g;
  wire       seg2_a, seg2_b, seg2_c, seg2_d, seg2_e, seg2_f, seg2_g;

  integer errors;
  integer round_idx;

  game_top #(
    .MemFile         (`MEMFILE),
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

  // Acceso jerárquico a lo que el programa escribió en DISP y LEDS. Es el
  // único punto de observación que tiene este testbench: el objetivo de
  // cada ronda sale de un LFSR que corre en software y que nunca se
  // reinicia, así que replicarlo acá sería frágil; se espía cuál LED se
  // encendió y se aprieta ese botón.
  wire [7:0]  disp_q = dut.u_soc.u_periph.digit_q;
  wire [3:0]  led_q  = dut.u_soc.u_periph.led_q;

  always #(CLK_PERIOD/2) clk = ~clk;

  // ---------------------------------------------------------------------
  // Utilidades
  // ---------------------------------------------------------------------
  task wait_cycles(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  task check(input ok_in, input string label);
    begin
      if (!ok_in) begin
        $display("FAIL @%0t: %0s", $time, label);
        errors = errors + 1;
      end else begin
        $display("ok   @%0t: %0s", $time, label);
      end
    end
  endtask

  // Empaqueta 0..99 como los dos dígitos BCD que el display decodifica.
  function [7:0] bcd2(input integer n);
    begin
      bcd2 = {4'(n / 10), 4'(n % 10)};
    end
  endfunction

  // Máscara de un solo bit garantizada distinta de `t`, para el error.
  function [3:0] wrong_button(input [3:0] t);
    begin
      wrong_button = (t !== 4'b0001) ? 4'b0001 : 4'b0010;
    end
  endfunction

  // --- Esperas por evento ----------------------------------------------
  // Todas devuelven en `ok` si el evento llegó antes del timeout, y todas
  // reportan con `check`, así que un timeout es un FAIL con nombre y no un
  // cuelgue silencioso.
  reg ok;

  task expect_led(input [3:0] val, input string label);
    integer i;
    begin
      ok = (led_q === val);
      for (i = 0; i < TIMEOUT && !ok; i = i + 1) begin
        @(posedge clk);
        if (led_q === val) ok = 1'b1;
      end
      if (!ok) $display("       (LEDS quedo en %b, se esperaba %b)", led_q, val);
      check(ok, label);
    end
  endtask

  task expect_disp(input [7:0] val, input string label);
    integer i;
    begin
      ok = (disp_q === val);
      for (i = 0; i < TIMEOUT && !ok; i = i + 1) begin
        @(posedge clk);
        if (disp_q === val) ok = 1'b1;
      end
      if (!ok) $display("       (DISP quedo en %02h, se esperaba %02h)", disp_q, val);
      check(ok, label);
    end
  endtask

  // Espera a que se encienda exactamente un LED (el objetivo de la ronda)
  // y lo captura.
  reg [3:0] target;

  task expect_led_onehot(input string label);
    integer i;
    reg [3:0] v;
    begin
      ok     = 1'b0;
      target = 4'b0000;
      for (i = 0; i < TIMEOUT && !ok; i = i + 1) begin
        @(posedge clk);
        v = led_q;
        if (v != 4'b0000 && (v & (v - 4'b0001)) == 4'b0000) begin
          ok     = 1'b1;
          target = v;
        end
      end
      check(ok, label);
    end
  endtask

  // Espera a que DISP se aparte de `from_val`, capturando el nuevo valor.
  reg [7:0] new_disp;

  task expect_disp_change(input [7:0] from_val, input string label);
    integer i;
    begin
      ok       = 1'b0;
      new_disp = from_val;
      for (i = 0; i < TIMEOUT && !ok; i = i + 1) begin
        @(posedge clk);
        if (disp_q !== from_val) begin
          ok       = 1'b1;
          new_disp = disp_q;
        end
      end
      check(ok, label);
    end
  endtask

  // ---------------------------------------------------------------------
  // Una ronda completa
  //
  //   round_begin  -> 4 LEDs + número de ronda en el display
  //   [error opcional: botón equivocado, EE, LEDs apagados, reintento]
  //   arm          -> un solo LED
  //   ...se espera REACTION_CYCLES exactos...
  //   hit          -> el display tiene que mostrar REACTION_TENTHS en BCD
  // ---------------------------------------------------------------------
  task play_round(input integer n, input do_miss);
    reg [3:0] wrong;
    begin
      expect_led(4'b1111, $sformatf("ronda %0d: round_begin enciende los 4 LEDs", n));
      expect_disp(bcd2(n), $sformatf("ronda %0d: el display muestra el numero de ronda", n));

      if (do_miss) begin
        expect_led_onehot($sformatf("ronda %0d: arm enciende el LED objetivo", n));

        wrong  = wrong_button(target);
        wait_cycles(MISS_DELAY);
        switch = wrong;

        expect_disp(PAT_ERROR,
                    $sformatf("ronda %0d: la pulsacion incorrecta muestra EE", n));
        // CARRERA: miss escribe DISP y recién en la instrucción siguiente
        // apaga los LEDs. Muestrear led_q acá daría todavía el objetivo
        // encendido; hay que esperar el apagado.
        expect_led(4'b0000,
                   $sformatf("ronda %0d: miss apaga los LEDs (despues de escribir EE)", n));

        switch = 4'b0000;

        // El reintento es de la MISMA ronda: los aciertos no se pierden,
        // así que el número mostrado no puede haber avanzado.
        expect_led(4'b1111,
                   $sformatf("ronda %0d: el reintento vuelve a la fase de los 4 LEDs", n));
        expect_disp(bcd2(n),
                    $sformatf("ronda %0d: el numero de ronda NO avanzo tras el error", n));
      end

      expect_led_onehot($sformatf("ronda %0d: arm enciende un solo LED (el objetivo)", n));

      // Único retardo de duración fija del testbench, y es el estímulo:
      // el tiempo de reacción que el juego tiene que medir.
      wait_cycles(REACTION_CYCLES);
      switch = target;

      expect_disp(DISP_REACTION,
                  $sformatf("ronda %0d: el display mide %0d decimas de reaccion (BCD %02h)",
                            n, REACTION_TENTHS, DISP_REACTION));

      // Soltar antes de que el juego vuelva a leer BTN. En la última ronda
      // esto además evita que finish_blink lea el botón todavía apretado y
      // reinicie el juego de inmediato.
      switch = 4'b0000;
    end
  endtask

  // ---------------------------------------------------------------------
  initial begin
`ifdef DUMP
    $dumpfile("game_tb.vcd");
    $dumpvars(0, game_tb);
`endif

    errors = 0;
    clk    = 1'b0;
    switch = 4'b0000;

    // El display es el único punto de observación del tiempo medido, así
    // que REACTION_TENTHS no puede coincidir con ningún número de ronda.
    for (round_idx = 1; round_idx <= RONDAS; round_idx = round_idx + 1)
      if (bcd2(round_idx) === DISP_REACTION)
        $fatal(1, "REACTION_TENTHS=%0d colisiona con el numero de ronda %0d",
               REACTION_TENTHS, round_idx);
    if (RONDAS < MISS_ON_ROUND + 1)
      $fatal(1, "RONDAS=%0d es muy chico para ejercer el error en la ronda %0d",
             RONDAS, MISS_ON_ROUND);

    $display("== game_tb: MEMFILE=%0s, RONDAS=%0d, reaccion inyectada=%0d decimas ==",
             `MEMFILE, RONDAS, REACTION_TENTHS);

    // Deja pasar el power-on reset interno de pochoco_soc (16 ciclos) más
    // la inicialización de _start/start_screen.
    wait_cycles(200);

    // === START_SCREEN ===================================================
    // DISP y LEDS también valen cero tras el reset, así que el check fuerte
    // no es el valor sino que se MANTENGA: el programa está parado en
    // ss_wait_press esperando una pulsación, no avanzando solo.
    expect_disp(PAT_START, "pantalla de inicio: el display muestra 00");
    expect_led(4'b0000,    "pantalla de inicio: los LEDs estan apagados");
    wait_cycles(STABLE_WIN);
    check(disp_q === PAT_START && led_q === 4'b0000,
          "pantalla de inicio: el juego espera una pulsacion, no avanza solo");

    // Cualquier botón siembra el LFSR y arranca la ronda 1. Se sostiene lo
    // suficiente para que el debounce lo acepte y después se suelta, porque
    // start_screen espera a que se suelte antes de seguir.
    switch = 4'b0001;
    wait_cycles(2 * SETTLE);
    switch = 4'b0000;

    // === RONDAS =========================================================
    for (round_idx = 1; round_idx <= RONDAS; round_idx = round_idx + 1)
      play_round(round_idx, round_idx == MISS_ON_ROUND);

    // === FINISH =========================================================
    expect_disp(PAT_AVG, "finish: el display muestra el patron AA");
    expect_disp_change(PAT_AVG, "finish: el display pasa de AA al promedio");
    check(new_disp === DISP_REACTION,
          $sformatf("finish: el promedio de las %0d rondas es %0d decimas (BCD %02h, leido %02h)",
                    RONDAS, REACTION_TENTHS, DISP_REACTION, new_disp));

    // -- Parpadeo: un período completo, no una muestra suelta -------------
    expect_led(4'b1111, "finish: el parpadeo arranca con los 4 LEDs encendidos");
    expect_led(4'b0000, "finish: el parpadeo los apaga");
    expect_led(4'b1111, "finish: el parpadeo los vuelve a encender");

    // -- Una pulsación vuelve a INIT --------------------------------------
    switch = 4'b0001;
    expect_disp(PAT_START, "reinicio: una pulsacion en finish vuelve al display 00");
    // CARRERA: igual que en miss, start_screen escribe DISP antes que LEDS.
    // Hay que esperar el apagado, no muestrearlo junto con el display.
    expect_led(4'b0000, "reinicio: los LEDs quedan apagados (despues de escribir 00)");
    // Con el botón todavía apretado el programa queda parado en
    // ss_wait_release, así que el estado es estable y comprobable. La
    // ventana es más larga que un período de parpadeo: si en realidad
    // siguiera en finish_blink, los LEDs se habrían movido.
    wait_cycles(STABLE_WIN);
    check(disp_q === PAT_START && led_q === 4'b0000,
          "reinicio: el juego quedo en la pantalla de inicio, no parpadeando");
    switch = 4'b0000;

    if (errors == 0) begin
      $display("\n=== PASS: todos los checks OK ===");
      $finish;
    end else begin
      $fatal(1, "\n=== FAIL: %0d check(s) fallaron ===", errors);
    end
  end

endmodule
