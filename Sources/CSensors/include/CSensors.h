#ifndef CSENSORS_H
#define CSENSORS_H

#include <stdint.h>

// AppleSMC access (read-only). All functions are not thread-safe; call from one queue.
int smc_open(void);
void smc_close(void);
// Reads a 4-char key. On success returns 0 and fills type (4CC), bytes (up to 32) and size.
int smc_read(const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size);
uint32_t smc_key_count(void);
// Writes the 4-char key at index into out (5 bytes incl. NUL). Returns 0 on success.
int smc_key_at(uint32_t index, char *out);

// Apple Silicon temperature sensors exposed through IOHIDEventSystem.
// names is a flat buffer of max * 64 chars; entry i starts at names + i * 64. Returns count.
int hid_read_temperatures(char *names, double *values, int max);

#endif
