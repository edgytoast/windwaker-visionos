// libc++'s std::string, instantiated inside the game's own object (visionos/cmake/framework.cmake).
// The SDK's <string> declares basic_string<char>'s out-of-line members `extern template`: code that
// grows a string calls libc++.dylib's copy, which frees the old buffer with the system's delete.
// cos_pc's strings live in the game's heap (its operator new is the game's), so those members must
// be the game object's own: instantiated here, they are, and framework.cmake's game_private.txt
// keeps them local to it. `nm -m wwvr_game.o | grep undefined | grep NSt3__1` lists what still
// comes from libc++.dylib. One of those frees a caller's block: std::thread's __thread_struct,
// made by the game's new and deleted by libc++.dylib when the thread exits, so a std::thread in
// cos_pc must start inside a JKRPcHostAllocScope (pc_hd_textures.cpp's does).
#include <string>

template class std::basic_string<char>;
template std::string std::operator+ <char, std::char_traits<char>, std::allocator<char>>(const char*, const std::string&);
