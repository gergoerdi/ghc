/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2018
 *
 * Non-moving garbage collector and allocator: Sweep phase
 *
 * ---------------------------------------------------------------------------*/

#pragma once

#include "NonMoving.h"
#include "Hash.h"

GNUC_ATTR_HOT void nonmoving_sweep(void);

// Remove unmarked entries in oldest generation scavenged_large_objects list
void nonmoving_sweep_large_objects(void);

// Remove unmarked entries in the array list. Runs in STW phase.
void nonmoving_sweep_array_list(void);

// Remove dead entries in the stable name table
void nonmoving_sweep_stable_name_table(void);

// Collect the set of segments to be collected during a major GC into
// nonmoving_heap.sweep_list.
void nonmoving_prepare_sweep(void);

#if defined(DEBUG)
// The non-moving equivalent of the moving collector's gcCAFs.
void nonmoving_gc_cafs(struct MarkQueue_ *queue);
#endif
