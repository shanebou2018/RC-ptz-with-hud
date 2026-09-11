// PulseState lives here, not inline in lora_vehicle_esp32.ino, because of
// an Arduino IDE gotcha: the IDE auto-generates forward declarations for
// every function in the .ino and inserts them right after the #include
// block -- BEFORE any struct/class defined later in that same file. Since
// startPulse()/updatePulse() take a `PulseState &` parameter, an inline
// struct definition (even one that textually appears earlier in the file
// than those functions) still ends up AFTER the auto-generated
// prototypes, and the build fails with "'PulseState' was not declared in
// this scope". Pulling the struct into a #include'd header sidesteps
// this entirely, since header content is present before the IDE's
// prototype generator ever runs.
#ifndef PULSE_STATE_H
#define PULSE_STATE_H

#include <Arduino.h>

struct PulseState {
  bool active = false;
  unsigned long startMs = 0;
};

#endif  // PULSE_STATE_H
