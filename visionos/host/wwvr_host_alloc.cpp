// The framework's host allocator (visionos/cmake/framework.cmake explains the two allocators).
// Everything in WindWakerVisionGame.framework outside the game's own object (cos_sdk, Aurora,
// Dawn, SDL, the DSP and this host) allocates with these: malloc, like libc++.dylib, so a string
// that libc++.dylib grows or frees is always its kind of block. Delete gives a block of the game's
// heaps back to the game (a game object freed on this side), anything else to free().
// Not exported: visionos/exports.txt lists only the bridge, so the rest of the process (SwiftUI)
// keeps the system's operators.
#include <cstddef>
#include <cstdlib>
#include <new>

extern "C" void wwvr_game_delete(void* ptr);  // visionos/game/wwvr_game_side.cpp

namespace {
void* HostAlloc(std::size_t size) {
    // malloc's blocks are 16-byte aligned, __STDCPP_DEFAULT_NEW_ALIGNMENT__ on arm64.
    void* ptr = std::malloc(size != 0 ? size : 1);
    if (ptr == nullptr) {
        std::abort();
    }
    return ptr;
}
}  // namespace

void* operator new(std::size_t size) { return HostAlloc(size); }
void* operator new[](std::size_t size) { return HostAlloc(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept { return std::malloc(size != 0 ? size : 1); }
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept { return std::malloc(size != 0 ? size : 1); }

void operator delete(void* ptr) noexcept { wwvr_game_delete(ptr); }
void operator delete[](void* ptr) noexcept { wwvr_game_delete(ptr); }
void operator delete(void* ptr, std::size_t) noexcept { wwvr_game_delete(ptr); }
void operator delete[](void* ptr, std::size_t) noexcept { wwvr_game_delete(ptr); }
void operator delete(void* ptr, const std::nothrow_t&) noexcept { wwvr_game_delete(ptr); }
void operator delete[](void* ptr, const std::nothrow_t&) noexcept { wwvr_game_delete(ptr); }
