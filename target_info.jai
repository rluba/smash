// Extracted from ptrace.jai

User_Fpregs :: struct {
    cwd:       u16;
    swd:       u16;
    ftw:       u16;
    fop:       u16;
    rip:       u64;
    rdp:       u64;
    mxcsr:     u32;
    mxcr_mask: u32;
    st_space:  [32] u32;   /* 8*16 bytes for each FP-reg = 128 bytes */
    xmm_space: [64] u32;  /* 16*16 bytes for each XMM-reg = 256 bytes */
    padding:   [24] u32;
}

Eflags :: enum_flags u64 {
    CF       :: 0x0001;
    PF       :: 0x0004;
    AF       :: 0x0010;
    ZF       :: 0x0040;
    SF       :: 0x0080;
    TF       :: 0x0100;
    IF       :: 0x0200;
    DF       :: 0x0400;
    OF       :: 0x0800;
    IOPL     :: 0x3000;
    NT       :: 0x4000;
    // EFLAGS
    RF       :: 0x0001_0000;
    VM       :: 0x0002_0000;
    AC       :: 0x0004_0000;
    VIF      :: 0x0008_0000;
    VIP      :: 0x0010_0000;
    ID       :: 0x0020_0000;
}

User_Regs :: struct {
    r15:      u64;
    r14:      u64;
    r13:      u64;
    r12:      u64;
    rbp:      u64;
    rbx:      u64;
    r11:      u64;
    r10:      u64;
    r9:       u64;
    r8:       u64;
    rax:      u64;
    rcx:      u64;
    rdx:      u64;
    rsi:      u64;
    rdi:      u64;
    orig_rax: u64;
    rip:      u64;
    cs:       u64;
    eflags:   Eflags;
    rsp:      u64;
    ss:       u64;
    fs_base:  u64;
    gs_base:  u64;
    ds:       u64;
    es:       u64;
    fs:       u64;
    gs:       u64;
}
