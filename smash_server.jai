timeout_ms := 10;

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

    xed_tables_init();
    format_options: Xed_Format_Options;
    xed_format_set_options(format_options);

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

Deserialized_Message :: struct {
    pool: Pool;
    message: *Message;
}

Debug_State :: struct {
    client_socket: s32;
    target: Target;
    poll_fds: [..] pollfd;
    pending_messages: [..] Deserialized_Message;
    unused_pools: [..] Pool;
    pending_action := Debugger_Action.NOTHING;
    source_display := Source_Display.DISASSEMBLY;
}

smash_server_thread_entry_proc :: (thread: *Thread) -> s64 {
    using state: Debug_State;
    remember_allocators(*pending_messages);
    remember_allocators(*unused_pools);

    client_socket = cast(s32) thread.data;
    defer close(client_socket);
    defer free_target(*target);

    result := fcntl(client_socket, F_SETFL, fcntl(client_socket, F_GETFL) | O_NONBLOCK);
    if result == -1 {
        log_error("Couldn’t set socket to non-blocking: error %", errno());
        return 1;
    }

    // @Speed: Use a ring buffer instead?
    unparsed_buffer: [512] u8; // @Incomplete: maybe auto-grow this buffer up to a certain size?
    num_unparsed_bytes := 0;

    fd := array_add(*poll_fds);
    fd.fd = client_socket;
    fd.events = POLLIN;

    while true {
        num_events := poll(poll_fds.data, xx poll_fds.count, -1);
        success := true;
        received_new_data := false;
        if poll_fds[0].revents & POLLIN {
            result := recv(client_socket, unparsed_buffer.data + num_unparsed_bytes, xx (unparsed_buffer.count - num_unparsed_bytes), 0);
            if result == -1 {
                log_error("Couldn’t read from socket %: error %", client_socket, errno());
                success = false;
            } else if result > 0 {
                log("Received % bytes:", result);
                num_unparsed_bytes += result;
                received_new_data = true;
            }
        }
        if poll_fds.count > 1 {
            if poll_fds[1].revents & POLLIN {
                success = print_entire_pipe(target.output_pipe);
            }
            if poll_fds[2].revents & POLLIN {
                success = print_entire_pipe(target.error_pipe) && success;
            }
            if poll_fds[3].revents & POLLIN {
                num_exp: u64;
                size_read := read(target.timer_fd, *num_exp, size_of(type_of(num_exp)));
                if size_read != size_of(type_of(num_exp)) {
                    log_error("Couldn’t read timer: error % (read %)\n", errno(), size_read);
                }
            }
        }
        if !success {
            log_error("Couldn’t read events\n");
            break;
        }

        if received_new_data {
            while true {
                pool: Pool;
                if unused_pools.count {
                    pool = pop(*unused_pools);
                } else {
                    set_allocators(*pool);
                }

                push_allocator(pool_allocator_proc, *pool);

                data := array_view(unparsed_buffer, 0, num_unparsed_bytes);
                message, num_bytes_parsed, success := deserialize_message(data);
                if !success {
                    log_error("Could not parse message (after % bytes)", num_bytes_parsed);
                    return 1;
                }

                if message {
                    log("Parsed message %", message.type);

                    message_with_pool: Deserialized_Message;
                    message_with_pool.message = message;
                    message_with_pool.pool = pool;
                    array_add(*pending_messages, message_with_pool);

                    num_unparsed_bytes -= num_bytes_parsed;
                    // @Speed: use memmove, once we have it!
                    for i: 0..num_unparsed_bytes-1 {
                        unparsed_buffer[i] = unparsed_buffer[i + num_bytes_parsed];
                    }
                } else {
                    reset(*pool);
                    array_add(*unused_pools, pool);
                    
                    if num_unparsed_bytes == unparsed_buffer.count {
                        log_error("Message is not complete, but we ran out of buffer space!");
                        return 1;
                    }
                    break;
                }
            }
        }

        if target.state == .RUNNING {
            status: s32 = ---;
            wait_result := waitpid(target.pid, *status, WNOHANG);
            if wait_result == -1 {
                log_error("Couldn’t wait for target process: %\n", errno());
                return 1;
            }

            if wait_result != 0 {
                // log("Something has happened in the target process!\n");
                if WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP {
                    if (target.temporarily_disabled_breakpoint_index != -1) {
                        enable_breakpoint(*target, target.temporarily_disabled_breakpoint_index);
                        target.temporarily_disabled_breakpoint_index = -1;
                    }

                    target.state = .PAUSED;
                    if !fetch_registers(*target)    return 1;

                    for target.breakpoints {
                        if it.address == target.registers.rip - 1 {
                            log("We hit breakpoint number %!\n", it_index);

                            target.registers.rip -= 1;
                            if !set_registers(*target)  return 1;

                            target.state = .HIT_BREAKPOINT;
                            pending_action = .NOTHING;
                            disable_breakpoint(*target, it_index);
                            target.temporarily_disabled_breakpoint_index = it_index;
                            break;
                        }
                    }

                    if pending_action == .NOTHING {
                        // log("Target state changed to %\n", target.state);

                        if !fetch_fp_registers(*target)     return 1;
                        print_registers(*target);
                        if !print_source(*target, source_display)   return 1;
                    }
                } else {
                    if WIFEXITED(status) {
                        target_exit_code := cast(s32) WEXITSTATUS(status);
                        log("Target has exited with code %\n", target_exit_code);
                        break;
                    }
                    if WIFSIGNALED(status) {
                        signal := WTERMSIG(status);
                        signal_string := to_string(strsignal(signal));
                        log_error("Target was terminated by signal % (%).\n", signal, signal_string);
                        success, info := fetch_signal_info(*target);
                        if !success     return 1;
                        print("Signal details: %\n", info);
                        if info.si_signo == {
                            case SIGSEGV;
                                print("Segfault! Code % – %\n", cast(Si_Code_Sigsegv) info.si_code, info._sigfault);
                        }
                        if !fetch_registers(*target)   return 1;
                        print_registers(*target);
                        
                        break;
                    }
                    log_error("Something unexpected happened in the target process: %\n", status);
                    return 1;
                }
            }
        }

        if target.state != .RUNNING {
            success = true;

            if target.state != .NONE && pending_action != .NOTHING {
                // log("Taking pending action: %\n", pending_action);
                success, pending_action = take_action(*target, pending_action);
            } else {
                for pending_messages {
                    if #complete it.message.type == {
                        case .INIT;
                            message_init := cast(*Message_Init) it.message;
                            log("Received init message: %", <<message_init);
                            success = handle_init_message(*state, <<message_init);
                        case .RUN;
                            message_run := cast(*Message_Run) it.message;
                            log("Received run message: %", <<message_run);
                            success = handle_run_message(*state, <<message_run);
                    }

                    reset(*it.pool);
                    array_add(*unused_pools, it.pool);

                    remove it;

                    if pending_action != .NOTHING   break;
                    if target.state == .RUNNING   break;
                }
            }

            if !success {
                return 1;
            }
        }
    }

    return 0;
}

free_target :: (target: *Target) {
    if target.output_pipe != -1 {
        close(target.output_pipe);
        target.output_pipe = -1;
    }
    if target.error_pipe != -1 {
        close(target.error_pipe);
        target.error_pipe = -1;
    }

    if target.timer_fd != -1 {
        close(target.timer_fd);
        target.timer_fd = -1;
    }

    if target.pid != -1 {
        try_kill_and_reap(target.pid);
        target.pid = -1;
    }
    // @Incomplete: Moar cleanup
}

handle_init_message :: (using state: *Debug_State, message: Message_Init) -> success: bool {
    free_target(*target);
    poll_fds.count = 1;

    if message.version != 1 {
        log_error("Unexpected init version: %", message.version);
        return false;
    }

    target_program_path := message.args[0];
    success, elf := read_target_program(target_program_path);
    if !success {
        log_error("Could not read target program\n");
        return false;
    }

    target.debug_info = parse_debug_info(*elf);

    {
        array_reserve(*target.instruction_addresses, elf.text.count / 5);
        array_reserve(*target.instructions, elf.text.count / 5);
        offset := 0;
        while offset < elf.text.count {
            address := elf.text_section.address + cast (u64) offset;
            array_add(*target.instruction_addresses, address);
            inst := array_add(*target.instructions);
            success := decode_instruction(*elf, offset, inst);
            if !success {
                log_error("Could not decode instruction at 0x%\n", formatHex64(address));
                return false;
            }
            offset += inst._decoded_length;
        }
    }

    command := join(.. message.args, separator = " ");
    defer free(command);
    log("Launching %\n", command);

    success, target.pid, target.output_pipe, target.error_pipe = spawn_target_process(message.args, message.work_dir);
    if !success {
        log_error("Failed to spawn target process!\n");
        return false;
    }

    log("Target process launched (pid %)!\n", target.pid);

    target.state = .PAUSED;
    
    fcntl(target.output_pipe, F_SETFL, fcntl(target.output_pipe, F_GETFL) | O_NONBLOCK);
    fcntl(target.error\_pipe, F_SETFL, fcntl(target.error\_pipe, F_GETFL) | O_NONBLOCK);
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);

    target.timer_fd, success = create_timer(timeout_ms);
    if !success {
        return false;
    }

    {
        fd := array_add(*poll_fds);
        fd.fd = target.output_pipe;
        fd.events = POLLIN;
    }
    {
        fd := array_add(*poll_fds);
        fd.fd = target.error_pipe;
        fd.events = POLLIN;
    }
    {
        fd := array_add(*poll_fds);
        fd.fd = target.timer_fd;
        fd.events = POLLIN;
    }
    assert(poll_fds.count == 4);

    return true;
}

handle_run_message :: (using state: *Debug_State, message: Message_Run) -> bool {
    success: bool;
    if #complete message.run_type == {
        case .CONTINUE;
            success, pending_action = take_action(*target, .CONTINUE);
        case .STEP;
            success, pending_action = take_action(*target, .STEP);
    }
    return success;
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
#load "target.jai";
#load "xed.jai";
