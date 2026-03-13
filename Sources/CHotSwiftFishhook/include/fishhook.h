#ifndef HOTSWIFT_FISHHOOK_H
#define HOTSWIFT_FISHHOOK_H

#include <stddef.h>
#include <stdint.h>

// Rebinding structure
struct hotswift_rebinding {
    const char *name;       // Symbol name to rebind
    void *replacement;      // New function pointer
    void **replaced;        // Output: original function pointer (can be NULL)
};

// Rebind symbols in all loaded Mach-O images
// Returns 0 on success, -1 on failure
int hotswift_rebind_symbols(struct hotswift_rebinding rebindings[], size_t rebindings_count);

// Rebind symbols only in a specific image (loaded via dlopen)
int hotswift_rebind_symbols_image(void *header, intptr_t slide,
                                   struct hotswift_rebinding rebindings[], size_t rebindings_count);

#endif
