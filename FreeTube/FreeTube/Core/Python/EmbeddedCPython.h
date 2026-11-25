#ifndef FreeTube_EmbeddedCPython_h
#define FreeTube_EmbeddedCPython_h

#include <stddef.h>

int FreeTubePythonInitialize(const char *home, const char *modulePath,
                             char *error, size_t errorCapacity);
int FreeTubePythonAcquireGIL(void);
void FreeTubePythonReleaseGIL(int state);

#endif
