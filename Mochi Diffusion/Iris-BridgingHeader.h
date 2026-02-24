// Iris-BridgingHeader.h
#import "../iris.c/iris.h"

// Metal init is not declared in iris.h, but the app links the MPS Iris library.
int iris_metal_init(void);
