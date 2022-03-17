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

Debug_State :: struct {
    client_socket: s32;
    target: Target;
    poll_fds: [..] pollfd;
    message_parser: Message_Parser(thread_safe = false);
    messages_to_send: [..] [] u8;
    pending_action := Debugger_Action.NOTHING;
    source_display := Source_Display.DISASSEMBLY;
}

smash_server_thread_entry_proc :: (thread: *Thread) -> s64 {
    using state: Debug_State;
    init(*message_parser);

    client_socket = cast(s32) thread.data;
    defer close(client_socket);
    defer free_target(*target);

    result := fcntl(client_socket, F_SETFL, fcntl(client_socket, F_GETFL) | O_NONBLOCK);
    if result == -1 {
        log_error("Couldn’t set socket to non-blocking: error %", errno());
        return 1;
    }

    unsent_buffer: [] u8;
    send_offset: int;

    server_fd := array_add(*poll_fds);
    server_fd.fd = client_socket;
    server_fd.events = POLLIN;

    while true {
        if !unsent_buffer.count && messages_to_send.count {
            message_buffer := pop(*messages_to_send);
            unsent_buffer = message_buffer;
        }
        if send_offset < unsent_buffer.count {
            server_fd.events = POLLIN | POLLOUT;
        } else {
            server_fd.events = POLLIN;
        }

        num_events := poll(poll_fds.data, xx poll_fds.count, -1);
        success := true;
        if poll_fds[0].revents & POLLIN {
            if !read_raw_message_data(*message_parser, client_socket) {
                success = false;
            }
        }
        if poll_fds[0].revents & POLLOUT {
            assert(send_offset < unsent_buffer.count);
            flags: s32 = 0;
            #if OS == .LINUX {
                flags |= MSG_NOSIGNAL;
            }
            // @Speed: We send at most one message per iteration here!
            // Instead we could loop until we can’t write more or have nothing to say…
            bytes_sent := send(client_socket, unsent_buffer.data + send_offset, xx (unsent_buffer.count - send_offset), flags);
            if bytes_sent == -1 {
                log_error("Couldn’t write to socket %: error %", client_socket, errno());
                success = false;
            } else if bytes_sent > 0 {
                log("Sent % bytes", bytes_sent);
                send_offset += bytes_sent;
                if send_offset == unsent_buffer.count {
                    array_reset(*unsent_buffer);
                    send_offset = 0;
                }
            }
        }
        if poll_fds.count > 1 {
            if poll_fds[1].revents & POLLIN {
                success = send_entire_pipe(*state, target.output_pipe, .STDOUT);
            }
            if poll_fds[2].revents & POLLIN {
                success = send_entire_pipe(*state, target.error_pipe, .STDERR) && success;
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
            log_error("Couldn’t handle poll events\n");
            break;
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
                        target.state = .EXITED;
                    } else if WIFSIGNALED(status) {
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
                        
                        target.state = .EXITED;
                    } else {
                        log_error("Something unexpected happened in the target process: %\n", status);
                        return 1;
                    }
                }
            }
        }

        if target.state != .RUNNING {
            success = true;

            if target.state != .NONE && pending_action != .NOTHING {
                // log("Taking pending action: %\n", pending_action);
                success, pending_action = take_action(*target, pending_action);
            } else {
                while true {
                    deserialized_message, success := get_next_deserialized_message(*message_parser);
                    if !success     break;

                    if #complete deserialized_message.message.type == {
                        case .INIT;
                            message_init := cast(*Message_Init) deserialized_message.message;
                            log("Received init message: %", <<message_init);
                            success = handle_init_message(*state, <<message_init);
                        case .RUN;
                            message_run := cast(*Message_Run) deserialized_message.message;
                            log("Received run message: %", <<message_run);
                            success = handle_run_message(*state, <<message_run);
                        case .OUTPUT;
                            assert(false);
                    }

                    free_deserialized_message(*message_parser, deserialized_message);

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

// @Speed: We chop things up in to too many messages here.
send_entire_pipe :: (state: *Debug_State, fd: s32, type: Output_Type) -> success: bool {
    buffer: [2048] u8;
    while true {
        bytes_read := read(fd, buffer.data, buffer.count);
        if bytes_read == 0  return true;
        if bytes_read < 0 {
            read_error := errno();
            if read_error == EAGAIN || read_error == EWOULDBLOCK {
                // @Incomplete: Also ignore EINTR?
                break;
            }
            return false;
        }

        message: Message_Output;
        message.output_type = type;
        message.data.data = buffer.data;
        message.data.count = bytes_read;
        send_message(state, *message);

        // buffer_str := to_string(buffer.data, bytes_read);
        // print("%", buffer_str);
    }

    return true;
}

send_message :: (using state: *Debug_State, message: *Message) {
    data := serialize_message(message);
    array_add(*messages_to_send, data);
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

#load "socket.jai";
#load "logger.jai";
#load "common.jai";
#load "network_messages.jai";
#load "target.jai";
#load "xed.jai";
