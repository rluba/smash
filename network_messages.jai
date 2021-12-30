Message_Type :: enum u32 {
    INIT;
    RUN;
}

Message :: struct {
    type: Message_Type;
}

Init_Message :: struct {
    using base: Message;
    type = .INIT;
    version: u16;
    work_dir: string;
    args: [..] string;
}

Run_Type :: enum u8 {
    CONTINUE;
    STEP;
}

Run_Message :: struct {
    using base: Message;
    run_type: Run_Type;
}

