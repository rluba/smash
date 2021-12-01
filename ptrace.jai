
Ptrace_Request :: __ptrace_request;
__ptrace_request :: enum {
    /* Indicate that the process making this request should be traced.
    All signals received by this process can be intercepted by its
    parent, and its parent can use the other `ptrace' requests.  */
    TRACEME :: 0;
    // #define PT_TRACE_ME TRACEME

    /* Return the word in the process's text space at address ADDR.  */
    PEEKTEXT :: 1;
    // #define PT_READ_I PEEKTEXT

    /* Return the word in the process's data space at address ADDR.  */
    PEEKDATA :: 2;
    // #define PT_READ_D PEEKDATA

    /* Return the word in the process's user area at offset ADDR.  */
    PEEKUSER :: 3;
    // #define PT_READ_U PEEKUSER

    /* Write the word DATA into the process's text space at address ADDR.  */
    POKETEXT :: 4;
    // #define PT_WRITE_I POKETEXT

    /* Write the word DATA into the process's data space at address ADDR.  */
    POKEDATA :: 5;
    // #define PT_WRITE_D POKEDATA

    /* Write the word DATA into the process's user area at offset ADDR.  */
    POKEUSER :: 6;
    // #define PT_WRITE_U POKEUSER

    /* Continue the process.  */
    CONT :: 7;
    // #define PT_CONTINUE CONT

    /* Kill the process.  */
    KILL :: 8;
    // #define PT_KILL KILL

    /* Single step the process.  */
    SINGLESTEP :: 9;
    // #define PT_STEP SINGLESTEP

    /* Get all general purpose registers used by a processes.  */
    GETREGS :: 12;
    // #define PT_GETREGS GETREGS

    /* Set all general purpose registers used by a processes.  */
    SETREGS :: 13;
    // #define PT_SETREGS SETREGS

    /* Get all floating point registers used by a processes.  */
    GETFPREGS :: 14;
    // #define PT_GETFPREGS GETFPREGS

    /* Set all floating point registers used by a processes.  */
    SETFPREGS :: 15;
    // #define PT_SETFPREGS SETFPREGS

    /* Attach to a process that is already running. */
    ATTACH :: 16;
    // #define PT_ATTACH ATTACH

    /* Detach from a process attached to with ATTACH.  */
    DETACH :: 17;
    // #define PT_DETACH DETACH

    /* Get all extended floating point registers used by a processes.  */
    GETFPXREGS :: 18;
    // #define PT_GETFPXREGS GETFPXREGS

    /* Set all extended floating point registers used by a processes.  */
    SETFPXREGS :: 19;
    // #define PT_SETFPXREGS SETFPXREGS

    /* Continue and stop at the next entry to or return from syscall.  */
    SYSCALL :: 24;
    // #define PT_SYSCALL SYSCALL

    /* Get a TLS entry in the GDT.  */
    GET_THREAD_AREA :: 25;
    // #define PT_GET_THREAD_AREA GET_THREAD_AREA

    /* Change a TLS entry in the GDT.  */
    SET_THREAD_AREA :: 26;
    // #define PT_SET_THREAD_AREA SET_THREAD_AREA

    /* Access TLS data.  */
    ARCH_PRCTL :: 30;
    // #define PT_ARCH_PRCTL ARCH_PRCTL

    /* Continue and stop at the next syscall, it will not be executed.  */
    SYSEMU :: 31;
    // #define PT_SYSEMU SYSEMU

    /* Single step the process, the next syscall will not be executed.  */
    SYSEMU_SINGLESTEP :: 32;
    // #define PT_SYSEMU_SINGLESTEP SYSEMU_SINGLESTEP

    /* Execute process until next taken branch.  */
    SINGLEBLOCK :: 33;
    // #define PT_STEPBLOCK SINGLEBLOCK

    /* Set ptrace filter options.  */
    SETOPTIONS :: 0x4200;
    // #define PT_SETOPTIONS SETOPTIONS

    /* Get last ptrace message.  */
    GETEVENTMSG :: 0x4201;
    // #define PT_GETEVENTMSG GETEVENTMSG

    /* Get siginfo for process.  */
    GETSIGINFO :: 0x4202;
    // #define PT_GETSIGINFO GETSIGINFO

    /* Set new siginfo for process.  */
    SETSIGINFO :: 0x4203;
    // #define PT_SETSIGINFO SETSIGINFO

    /* Get register content.  */
    GETREGSET :: 0x4204;
    // #define GETREGSET GETREGSET

    /* Set register content.  */
    SETREGSET :: 0x4205;
    // #define SETREGSET SETREGSET

    /* Like ATTACH, but do not force tracee to trap and do not affect
    signal or group stop state.  */
    SEIZE :: 0x4206;
    // #define SEIZE SEIZE

    /* Trap seized tracee.  */
    INTERRUPT :: 0x4207;
    // #define INTERRUPT INTERRUPT

    /* Wait for next group event.  */
    LISTEN :: 0x4208;
    // #define LISTEN LISTEN

    /* Retrieve siginfo_t structures without removing signals from a queue.  */
    PEEKSIGINFO :: 0x4209;
    // #define PEEKSIGINFO PEEKSIGINFO

    /* Get the mask of blocked signals.  */
    GETSIGMASK :: 0x420a;
    // #define GETSIGMASK GETSIGMASK

    /* Change the mask of blocked signals.  */
    SETSIGMASK :: 0x420b;
    // #define SETSIGMASK SETSIGMASK

    /* Get seccomp BPF filters.  */
    SECCOMP_GET_FILTER :: 0x420c;
    // #define SECCOMP_GET_FILTER SECCOMP_GET_FILTER

    /* Get seccomp BPF filter metadata.  */
    SECCOMP_GET_METADATA :: 0x420d;
    // #define SECCOMP_GET_METADATA SECCOMP_GET_METADATA
}


ptrace :: (request: Ptrace_Request, pid: pid_t, attr: *void, data: *void) -> s64 #foreign libc;

User_Fpregs :: user_fpregs_struct;
user_fpregs_struct :: struct {
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

User_Regs :: user_regs_struct;
user_regs_struct :: struct {
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

#scope_file

libc :: #foreign_system_library "libc";

