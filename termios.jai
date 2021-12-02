NCCS :: 19;
cc_t :: u8;
tcflag_t :: u32;

termios :: struct {
    c_iflag: tcflag_t;		/* input mode flags */
	c_oflag: tcflag_t;		/* output mode flags */
	c_cflag: tcflag_t;		/* control mode flags */
	c_lflag: Terminal_Lflags;		/* local mode flags */
    c_line: cc_t;			/* line discipline */
    c_cc: [NCCS] cc_t;		/* control characters */
}

tcgetattr :: (fd: s32, termios_p: *termios) -> s32 #foreign libc;
tcsetattr :: (fd: s32, optional_actions: Terminal_Actions, termios_p: *termios) -> s32 #foreign libc;


/* c_lflag bits */
Terminal_Lflags :: enum_flags u32 {
    ISIG ::	    0x0000_0001;
    ICANON ::	0x0000_0002;
    XCASE ::	0x0000_0004;
    ECHO ::	    0x0000_0008;
    ECHOE ::	0x0000_0010;
    ECHOK ::	0x0000_0020;
    ECHONL ::	0x0000_0040;
    NOFLSH ::	0x0000_0080;
    TOSTOP ::	0x0000_0100;
    ECHOCTL ::	0x0000_0200;
    ECHOPRT ::	0x0000_0400;
    ECHOKE ::	0x0000_0800;
    FLUSHO ::	0x0000_1000;
    PENDIN ::	0x0000_4000;
    IEXTEN ::	0x0000_8000;
    EXTPROC ::	0x0001_0000;
}

Terminal_Actions :: enum {
    TCSANOW   :: 0;
    TCSADRAIN :: 1;
    TCSAFLUSH :: 2;
}

#scope_file

libc :: #foreign_system_library "libc";

