#ifndef WM_FIPS_CORE_H
#define WM_FIPS_CORE_H
#include <stdint.h>
#include <stddef.h>
// Extension only. JSON pointers must be freed exactly once. Input is borrowed.
char *wm_fips_start(const uint8_t *secret32, const char *private_directory);
char *wm_fips_stop(void);
char *wm_fips_status(void);
char *wm_fips_peers(void);
char *wm_fips_probe(const char *npub);
void wm_fips_string_free(char *value);
int32_t wm_fips_input(const uint8_t *bytes, size_t length);
// Owned duplicate; close ONLY in DispatchSource cancellation handler. Do not
// read: output() clears readiness when the bounded queue becomes empty.
int32_t wm_fips_output_descriptor(void);
int32_t wm_fips_output(uint8_t *bytes, size_t capacity);
#endif
