// Iris-BridgingHeader.h
#import "../iris.c/iris.h"

// Metal init is not declared in iris.h, but the app links the MPS Iris library.
int iris_metal_init(void);

// Clears Iris's process-wide Metal caches: the GPU copies of weights, keyed by
// their CPU address, and the activation pool. iris_free does not touch them.
void iris_metal_reset(void);
