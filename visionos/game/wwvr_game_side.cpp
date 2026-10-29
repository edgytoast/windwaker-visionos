// The game's side of the Apple Vision Pro port: code linked into the game's own object
// (visionos/cmake/framework.cmake, wwvr_game.o), where operator new/delete are the game's
// (native/src/pc/game_hooks/pc_jkr_heap.cpp). Compiled like a game unit (cos_game_headers).
#include "JSystem/JKernel/JKRHeap.h"

#include <stdlib.h>

// The framework's other allocator (visionos/host/wwvr_host_alloc.cpp) frees through this: a block
// one of the game's heaps owns goes back to that heap, anything else to the system, as the game's
// own operator delete does. JKRHeap::findFromRoot checks the root heap's range first, so a host
// block never walks the heap tree.
extern "C" void wwvr_game_delete(void* ptr) {
    if (ptr == NULL) {
        return;
    }
    JKRHeap* heap = JKRHeap::findFromRoot(ptr);
    if (heap == NULL) {
        ::free(ptr);
        return;
    }
    JKRHeap::free(ptr, heap);
}
