/*
 *  fishhook.c
 *  CHotSwiftFishhook
 *
 *  Mach-O dynamic symbol rebinding for HotSwift.
 *
 *  This implementation walks the Mach-O structures of loaded images to locate
 *  indirect symbol pointer sections (__la_symbol_ptr, __nl_symbol_ptr, __got)
 *  and replaces entries that match requested symbol names.
 *
 *  Works on both arm64 and x86_64 by using the mach_header_64 variant
 *  (all modern Apple platforms are 64-bit).
 */

#include "fishhook.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <mach/vm_prot.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSAtomic.h>
#include <pthread.h>

/* --------------------------------------------------------------------------
   Internal types — we always operate on 64-bit Mach-O structures.
   -------------------------------------------------------------------------- */
typedef struct mach_header_64     hs_mach_header_t;
typedef struct segment_command_64 hs_segment_command_t;
typedef struct section_64         hs_section_t;
typedef struct nlist_64           hs_nlist_t;

#define HS_LC_SEGMENT             LC_SEGMENT_64
#define HS_HEADER_MAGIC           MH_MAGIC_64

/* --------------------------------------------------------------------------
   Linked-list node that stores a snapshot of the rebindings the caller has
   registered so far.  Each call to hotswift_rebind_symbols() prepends a new
   node; the dyld callback walks the whole list so that late-loaded images
   pick up every rebinding ever registered.
   -------------------------------------------------------------------------- */
struct rebinding_entry {
    struct hotswift_rebinding *rebindings;
    size_t                     count;
    struct rebinding_entry    *next;
};

/* Global head of the rebinding list. */
static struct rebinding_entry *g_rebinding_head = NULL;

/* Guard so we register the dyld callback exactly once. */
static int g_dyld_callback_registered = 0;

/* Mutex protecting the global list and registration flag. */
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

/* --------------------------------------------------------------------------
   Forward declarations
   -------------------------------------------------------------------------- */
static void hs_dyld_callback(const struct mach_header *header, intptr_t slide);
static void hs_rebind_image(const hs_mach_header_t *header, intptr_t slide,
                            struct rebinding_entry *entry_list);
static void hs_rebind_section(const hs_mach_header_t *header, intptr_t slide,
                              const hs_section_t *section,
                              const uint32_t *indirect_symtab,
                              const hs_nlist_t *symtab, const char *strtab,
                              uint32_t symtab_count, uint32_t strsize,
                              struct rebinding_entry *entry_list);

/* --------------------------------------------------------------------------
   page_align — round an address down to the nearest page boundary.
   -------------------------------------------------------------------------- */
static uintptr_t page_align(uintptr_t addr) {
    long page_size = sysconf(_SC_PAGESIZE);
    return addr & ~((uintptr_t)page_size - 1);
}

/* --------------------------------------------------------------------------
   make_writable / restore_protection
   __DATA_CONST is mapped read-only at runtime.  We temporarily toggle write
   access with mprotect so we can patch pointers, then restore the original
   protection bits.
   -------------------------------------------------------------------------- */
static int make_section_writable(const hs_section_t *section, intptr_t slide) {
    uintptr_t start = page_align(section->addr + (uintptr_t)slide);
    uintptr_t end   = section->addr + (uintptr_t)slide + section->size;
    long page_size  = sysconf(_SC_PAGESIZE);
    size_t length   = end - start;

    /* Round length up to a full page. */
    if (length % (size_t)page_size != 0) {
        length += (size_t)page_size - (length % (size_t)page_size);
    }

    return mprotect((void *)start, length, PROT_READ | PROT_WRITE);
}

static void restore_section_protection(const hs_section_t *section, intptr_t slide) {
    uintptr_t start = page_align(section->addr + (uintptr_t)slide);
    uintptr_t end   = section->addr + (uintptr_t)slide + section->size;
    long page_size  = sysconf(_SC_PAGESIZE);
    size_t length   = end - start;

    if (length % (size_t)page_size != 0) {
        length += (size_t)page_size - (length % (size_t)page_size);
    }

    mprotect((void *)start, length, PROT_READ);
}

/* --------------------------------------------------------------------------
   hs_rebind_section
   Given a single indirect-pointer section (e.g. __la_symbol_ptr), iterate
   every slot, resolve the symbol name through the indirect → symbol →
   string-table chain, and replace if it matches a requested rebinding.
   -------------------------------------------------------------------------- */
static void hs_rebind_section(const hs_mach_header_t *header, intptr_t slide,
                              const hs_section_t *section,
                              const uint32_t *indirect_symtab,
                              const hs_nlist_t *symtab, const char *strtab,
                              uint32_t symtab_count, uint32_t strsize,
                              struct rebinding_entry *entry_list)
{
    /*
     * section->reserved1 is the index into the indirect symbol table where
     * this section's entries begin.
     */
    uint32_t indirect_offset = section->reserved1;

    /* Number of pointer-sized slots in the section. */
    size_t pointer_count = section->size / sizeof(void *);

    /* Base address of the pointer array in memory. */
    void **indirect_pointers = (void **)(uintptr_t)(section->addr + (uintptr_t)slide);

    /* Determine whether this section lives in a read-only segment
       (__DATA_CONST) so we can toggle write access. */
    int needs_mprotect = 0;

    /* Walk backwards from the section to find its parent segment name. */
    const uint8_t *cursor = (const uint8_t *)header + sizeof(hs_mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == HS_LC_SEGMENT) {
            const hs_segment_command_t *seg = (const hs_segment_command_t *)cursor;
            uintptr_t seg_start = seg->vmaddr + (uintptr_t)slide;
            uintptr_t seg_end   = seg_start + seg->vmsize;
            uintptr_t sec_addr  = section->addr + (uintptr_t)slide;
            if (sec_addr >= seg_start && sec_addr < seg_end) {
                if (strcmp(seg->segname, "__DATA_CONST") == 0) {
                    needs_mprotect = 1;
                }
                break;
            }
        }
        cursor += lc->cmdsize;
    }

    if (needs_mprotect) {
        if (make_section_writable(section, slide) != 0) {
            return; /* Cannot make writable — skip this section. */
        }
    }

    for (size_t i = 0; i < pointer_count; i++) {
        /* Index into the indirect symbol table for this slot. */
        uint32_t symtab_index = indirect_symtab[indirect_offset + i];

        /* Skip special indirect-symbol-table sentinel values. */
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        /* Bounds check against the symbol table. */
        if (symtab_index >= symtab_count) {
            continue;
        }

        /* Retrieve the string-table offset from the nlist entry.
           Symbol names in the string table are prefixed with '_'. */
        uint32_t str_offset = symtab[symtab_index].n_un.n_strx;

        /* Bounds check against the string table. */
        if (str_offset >= strsize) {
            continue;
        }

        const char *symbol_name = strtab + str_offset;

        /* The linker stores names with a leading underscore; skip past it
           so the caller can use the plain C name (e.g. "open" not "_open"). */
        int has_leading_underscore = (symbol_name[0] == '_');
        const char *clean_name = has_leading_underscore ? symbol_name + 1 : symbol_name;

        /* Walk every registered rebinding entry and check for a match. */
        struct rebinding_entry *entry = entry_list;
        while (entry != NULL) {
            for (size_t j = 0; j < entry->count; j++) {
                const char *target = entry->rebindings[j].name;
                if (strcmp(clean_name, target) == 0) {
                    /* Store the original pointer if the caller wants it and
                       we haven't stored one yet (first image wins). */
                    if (entry->rebindings[j].replaced != NULL &&
                        *entry->rebindings[j].replaced == NULL) {
                        *entry->rebindings[j].replaced = indirect_pointers[i];
                    }
                    /* Patch the slot to point at the replacement. */
                    indirect_pointers[i] = entry->rebindings[j].replacement;
                    goto next_pointer; /* This slot is done. */
                }
            }
            entry = entry->next;
        }
    next_pointer:;
    }

    if (needs_mprotect) {
        restore_section_protection(section, slide);
    }
}

/* --------------------------------------------------------------------------
   hs_rebind_image
   Walk the load commands of a single Mach-O image to find the symbol table,
   string table, indirect symbol table, and every relevant section in __DATA /
   __DATA_CONST.  Then rebind each section.
   -------------------------------------------------------------------------- */
static void hs_rebind_image(const hs_mach_header_t *header, intptr_t slide,
                            struct rebinding_entry *entry_list)
{
    if (entry_list == NULL) {
        return;
    }

    /* Pointers we need to collect from load commands. */
    const hs_nlist_t   *symtab_ptr        = NULL;
    const char         *strtab_ptr        = NULL;
    const uint32_t     *indirect_symtab   = NULL;
    uint32_t            symtab_count      = 0;
    uint32_t            str_table_size    = 0;

    /* First pass: locate LC_SYMTAB and LC_DYSYMTAB. */
    const uint8_t *cursor = (const uint8_t *)header + sizeof(hs_mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;

        if (lc->cmd == LC_SYMTAB) {
            const struct symtab_command *sym_cmd = (const struct symtab_command *)cursor;
            symtab_ptr      = (const hs_nlist_t *)((const uint8_t *)header + sym_cmd->symoff);
            strtab_ptr      = (const char *)((const uint8_t *)header + sym_cmd->stroff);
            symtab_count    = sym_cmd->nsyms;
            str_table_size  = sym_cmd->strsize;
        }

        if (lc->cmd == LC_DYSYMTAB) {
            const struct dysymtab_command *dysym = (const struct dysymtab_command *)cursor;
            indirect_symtab = (const uint32_t *)((const uint8_t *)header + dysym->indirectsymoff);
        }

        cursor += lc->cmdsize;
    }

    /* All three are required to resolve indirect symbols. */
    if (symtab_ptr == NULL || strtab_ptr == NULL || indirect_symtab == NULL) {
        return;
    }

    /* Second pass: walk segments and their sections, looking for indirect
       pointer sections (identified by section type flags). */
    cursor = (const uint8_t *)header + sizeof(hs_mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;

        if (lc->cmd == HS_LC_SEGMENT) {
            const hs_segment_command_t *seg = (const hs_segment_command_t *)cursor;

            /* Only look at __DATA and __DATA_CONST segments. */
            if (strcmp(seg->segname, "__DATA") != 0 &&
                strcmp(seg->segname, "__DATA_CONST") != 0) {
                cursor += lc->cmdsize;
                continue;
            }

            /* Iterate sections within the segment. */
            const hs_section_t *sections = (const hs_section_t *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) {
                const hs_section_t *sec = &sections[j];
                uint32_t sec_type = sec->flags & SECTION_TYPE;

                /*
                 * We care about three section types:
                 *   S_LAZY_SYMBOL_POINTERS      — __la_symbol_ptr
                 *   S_NON_LAZY_SYMBOL_POINTERS  — __nl_symbol_ptr / __got
                 */
                if (sec_type == S_LAZY_SYMBOL_POINTERS ||
                    sec_type == S_NON_LAZY_SYMBOL_POINTERS) {
                    hs_rebind_section(header, slide, sec,
                                      indirect_symtab, symtab_ptr, strtab_ptr,
                                      symtab_count, str_table_size,
                                      entry_list);
                }
            }
        }

        cursor += lc->cmdsize;
    }
}

/* --------------------------------------------------------------------------
   hs_dyld_callback
   Called by dyld for every image that is loaded (including images loaded
   after we register).  We rebind all registered symbols in the new image.
   -------------------------------------------------------------------------- */
static void hs_dyld_callback(const struct mach_header *header, intptr_t slide)
{
    pthread_mutex_lock(&g_mutex);
    struct rebinding_entry *entry_list = g_rebinding_head;
    pthread_mutex_unlock(&g_mutex);

    hs_rebind_image((const hs_mach_header_t *)header, slide, entry_list);
}

/* --------------------------------------------------------------------------
   prepend_rebindings
   Allocate a new entry node, copy the caller's array into it, and prepend
   to the global list.
   -------------------------------------------------------------------------- */
static int prepend_rebindings(struct rebinding_entry **head,
                              struct hotswift_rebinding rebindings[],
                              size_t count)
{
    struct rebinding_entry *new_entry = malloc(sizeof(struct rebinding_entry));
    if (new_entry == NULL) {
        return -1;
    }

    /* Copy the rebindings array so the caller doesn't need to keep it alive. */
    new_entry->rebindings = malloc(sizeof(struct hotswift_rebinding) * count);
    if (new_entry->rebindings == NULL) {
        free(new_entry);
        return -1;
    }
    memcpy(new_entry->rebindings, rebindings,
           sizeof(struct hotswift_rebinding) * count);
    new_entry->count = count;
    new_entry->next  = *head;
    *head = new_entry;

    return 0;
}

/* ==========================================================================
   Public API
   ========================================================================== */

/*
 * hotswift_rebind_symbols
 *
 * Register the given rebindings and apply them to every currently-loaded
 * Mach-O image.  Also ensures a dyld callback is registered so that
 * future images (e.g. from dlopen) are rebinded automatically.
 */
int hotswift_rebind_symbols(struct hotswift_rebinding rebindings[],
                            size_t rebindings_count)
{
    if (rebindings_count == 0) {
        return 0;
    }

    pthread_mutex_lock(&g_mutex);

    /* Prepend to the global list. */
    int rc = prepend_rebindings(&g_rebinding_head, rebindings, rebindings_count);
    if (rc != 0) {
        pthread_mutex_unlock(&g_mutex);
        return -1;
    }

    int need_register = !g_dyld_callback_registered;
    if (need_register) {
        g_dyld_callback_registered = 1;
    }

    /* Capture the head pointer while we still hold the lock so the else
       branch below doesn't read g_rebinding_head after unlock (race). */
    struct rebinding_entry *current_head = g_rebinding_head;

    pthread_mutex_unlock(&g_mutex);

    if (need_register) {
        /*
         * _dyld_register_func_for_add_image will immediately call our
         * callback once for every image that is already loaded, then again
         * for each image loaded in the future.  The first invocation covers
         * all currently-loaded images, so we don't need a separate loop.
         */
        _dyld_register_func_for_add_image(hs_dyld_callback);
    } else {
        /*
         * The dyld callback is already registered and won't re-fire for
         * existing images.  Walk them manually so the new rebindings are
         * applied to images that were loaded before this call.
         */
        uint32_t image_count = _dyld_image_count();
        for (uint32_t i = 0; i < image_count; i++) {
            const struct mach_header *hdr = _dyld_get_image_header(i);
            if (hdr == NULL) {
                continue;
            }
            hs_rebind_image((const hs_mach_header_t *)hdr,
                            _dyld_get_image_vmaddr_slide(i),
                            current_head);
        }
    }

    return 0;
}

/*
 * hotswift_rebind_symbols_image
 *
 * Rebind symbols in a single image only (useful when the caller has
 * a specific dylib handle from dlopen).  Does NOT register a dyld
 * callback or modify the global rebinding list.
 */
int hotswift_rebind_symbols_image(void *header, intptr_t slide,
                                   struct hotswift_rebinding rebindings[],
                                   size_t rebindings_count)
{
    if (header == NULL || rebindings_count == 0) {
        return -1;
    }

    /* Build a temporary single-node entry list on the stack. */
    struct rebinding_entry entry;
    entry.rebindings = rebindings;
    entry.count      = rebindings_count;
    entry.next       = NULL;

    hs_rebind_image((const hs_mach_header_t *)header, slide, &entry);

    return 0;
}
