debugger_logger :: (message: string, data: *void, info: Log_Info) {
    color := 240;
    if info.common_flags & .ERROR {
        color = 1;
    }

    print("\e[38;5;%m%\e[0;m", color, message);

    if message && (message[message.count-1] != #char "\n") write_string("\n");
}

