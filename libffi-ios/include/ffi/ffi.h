#ifdef __arm__
    #include <arm/arch.h>
    #ifdef __aarch64__
        #include "arm64/ffi.h"
    #elif defined(_ARM_ARCH_7)
        #include "armv7/ffi.h"
    #endif
#elif defined(__i386__)
    #include "i386/ffi.h"
#elif defined(__LP64__)
    #include "x86_64/ffi.h"
#else
    #error "Unsupported architecture"
#endif
