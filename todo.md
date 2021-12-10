* Show source code for x64 backend (compilation unit does not contain low_pc/high_pc)
* Show source code along with disassembly
* Show variable information
* Show stack traces
    * use rip. if not useful, try finding the return address at $rsp
    * Decode dwarf debug info, walk the stak using DW_AT_frame_base
* Handle signals, especially sigsegv
* Implement client-server communication
* Get a GL window running on macOS
* Add command for adding / removing breakpoints at run-time

