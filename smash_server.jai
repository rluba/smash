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
        client_socket, client_addr := accept(server_socket, 0);
        if client_socket == -1 {
            log_error("Socket accept failed: %\n", errno());
            return 1;
        }
        print("Accepted socket % from %\n", client_socket, client_addr);

        close(client_socket);
    }

    return 0;
}

#scope_file

#import "Command_Line";

#load "socket.jai";
#load "logger.jai";
#load "common.jai";
