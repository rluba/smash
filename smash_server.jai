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


    reuse_addr: s32 = 1;
    result := setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, *reuse_addr, size_of(type_of(reuse_addr)));
	if result == -1 {
		log_error("Couldn’t set socket options: %\n", errno());
		return 1;
	}

	result = bind(server_socket, INADDR_ANY, args.port);
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
    // @Speed: Use a ring buffer instead?
    buffer: [512] u8; // @Incomplete: maybe auto-grow this buffer up to a certain size?

    num_unparsed_bytes := 0;
    pool: Pool;
    set_allocators(*pool);
    while true {
        result := recv(client_socket, buffer.data + num_unparsed_bytes, xx (buffer.count - num_unparsed_bytes), 0);
        if result == -1 {
            log_error("Couldn’t read from socket %: error %", client_socket, errno());
            break;
        }

        log("Received % bytes:", result);
        num_unparsed_bytes += result;

        // for i: 0..result-1 {
        //     if i % 16 == 0  print("\n");
        //     print("% ", formatInt(buffer[i], base = 16, minimum_digits = 2));
        // }
        
        {
            push_allocator(pool_allocator_proc, *pool);

            data := array_view(buffer, 0, num_unparsed_bytes);
            message, num_bytes_parsed, success := deserialize_message(data);
            if !success {
                log_error("Could not parse message (after % bytes)", num_bytes_parsed);
                break;
            }

            if message {
                if #complete message.type == {
                    case .INIT;
                        message_init := cast(*Init_Message) message;
                        log("Received init message: %", <<message_init);
                    case .RUN;
                        message_run := cast(*Run_Message) message;
                        log("Received run message: %", <<message_run);
                }

                num_unparsed_bytes -= num_bytes_parsed;
                // @Speed: use memmove, once we have it!
                for i: 0..num_unparsed_bytes-1 {
                    buffer[i] = buffer[i + num_bytes_parsed];
                }
            } else {
                if num_unparsed_bytes == buffer.count {
                    log_error("Message is not complete, but we ran out of buffer space!");
                    break;
                }
            }
        }
        reset(*pool);
    }

    close(client_socket);

    return 0;
}


#scope_file

#import "Command_Line";
#import "POSIX";
#import "Thread";
#import "Pool";

#load "socket.jai";
#load "logger.jai";
#load "common.jai";
#load "network_messages.jai";
