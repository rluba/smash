* Show variable information
* Show stack traces
    * use rip. if not useful, try finding the return address at $rsp
    * Decode dwarf debug info, walk the stak using DW_AT_frame_base
* Handle signals, especially sigsegv
* Disassemble true memory content, not just static ELF (to get relocated code, loaded libraries, etc.)
* Implement client-server communication
* Get a GL window running on macOS
* Add command for adding / removing breakpoints at run-time

