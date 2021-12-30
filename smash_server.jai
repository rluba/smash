Args :: struct {
    port: u16 = DEFAULT_PORT;
}

main :: () {
    context.logger = debugger_logger;

    return_code := do_main();

    exit(return_code);
}

do_main :: () -> s32 {
    args_success, args := parse_arguments(Args);
    if !args_success {
        log_error("Could not parse arguments\n");
        return 1;
    }

    server_socket := socket(AF_INET, SOCK_STREAM, 0);
    if server_socket == -1 {
        log_error("Could not create socket: %\n", errno());
        return 1;
    }
    defer close(server_socket);

	result := bind(server_socket, INADDR_ANY, args.port);
	if result == -1 {
		log_error("Couldn’t bind socket: %\n", errno());
		return 1;
	}

	result = listen(server_socket, SOMAXCONN);
	if result == -1 {
		log_error("Couldn’t listen on socket: %\n", errno());
        return 1;
	}
	log("Listening on socket %\n", server_socket);

    while true {
        client_socket, client_addr := accept(server_socket);
        if client_socket == -1 {
            log_error("Socket accept failed: %\n", errno());
            return 1;
        }
        print("Accepted socket % from %\n", client_socket, client_addr);
        thread := New(Thread);
        thread_init(thread, smash_server_thread_entry_proc);
        thread.data = xx client_socket;
        thread_start(thread);
    }

    return 0;
}

smash_server_thread_entry_proc :: (thread: *Thread) -> s64 {
    client_socket := cast(s32) thread.data;
    buffer: [512] u8;

    result := recv(client_socket, buffer.data, buffer.count, 0);
    if result == -1 {
        log_error("Couldn’t read from socket %: error %", client_socket, errno());
        return 1;
    }

    print("Received % bytes:", result);
    for i: 0..result-1 {
        if i % 16 == 0  print("\n");
        print("% ", formatInt(buffer[i], base = 16, minimum_digits = 2));
    }

    close(client_socket);

    return 0;
}


#scope_file

#import "Command_Line";
#import "POSIX";
#import "Thread";

#load "socket.jai";
#load "logger.jai";
#load "common.jai";
