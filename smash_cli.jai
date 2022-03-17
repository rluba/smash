Args :: struct {
    work_dir: string;
    breakpoint: string;
}
timeout_ms := 10;

main :: () {
    context.logger = debugger_logger;

    // We have to wrap main so we can ensure that the defer can restore the original temrinal settings before we exit.
    // sigh...
    return_code := do_main();
    exit(return_code);
}

do_main :: () -> s32 {
    args_success, args, is_set, extra_args := parse_arguments(Args);
    if !args_success {
        log_error("Could not parse arguments\n");
        return 1;
    }

    address: u64;
    if is_set.breakpoint {
        result: int;
        success: bool = ---;
        remainder: string = ---;
        if begins_with(args.breakpoint, "0x") {
            hex_str := slice(args.breakpoint, 2, args.breakpoint.count - 2);
            result, success, remainder = string_to_int(hex_str, 16);
        } else {
            result, success, remainder = string_to_int(args.breakpoint, 10);
        }
        if !success || remainder {
            log("Could not parse breakpoint address\n");
            return 1;
        }
        address = cast(u64) result;
    }

    target_args := extra_args;
    if !target_args {
        log_error("Usage: % [-work_dir <dir>] [-breakpoint <address>] [--] <program to run + args>", get_command_line_arguments()[0]);
        return 1;
    }

    old_teminal_settings: termios;
    {
        result := tcgetattr(STDIN_FILENO, *old_teminal_settings);
        if result != 0 {
            log_error("Could not get terminal settings: %", errno());
            return 1;
        }
        new_settings := old_teminal_settings;
        new_settings.c_lflag &= ~(Terminal_Lflags.ICANON | .ECHO);
        result = tcsetattr(STDIN_FILENO, .TCSANOW, *new_settings);
        if result != 0 {
            log_error("Could not set terminal settings: %", errno());
            return 1;
        }
    }
    defer {
        result := tcsetattr(STDIN_FILENO, .TCSANOW, *old_teminal_settings);
        if result != 0 {
            log_error("Could not restore old terminal settings: %", errno());
        }
    }

    target_program_path := target_args[0];
    success, elf := read_target_program(target_program_path);
    if !success {
        log_error("Could not read target program\n");
        return 1;
    }

    target: Target;

    target.debug_info = parse_debug_info(*elf);

    xed_tables_init();
    format_options: Xed_Format_Options;
    xed_format_set_options(format_options);

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
                return 1;
            }
            offset += inst._decoded_length;
        }
    }

    command := join(.. target_args, separator = " ");
    defer free(command);
    log("Launching %\n", command);

    success, target.pid, target.output_pipe, target.error_pipe = spawn_target_process(target_args, args.work_dir);
    if !success {
        log_error("Failed to spawn target process!\n");
        return 1;
    }

    defer {
        close(target.output_pipe);
        close(target.error_pipe);
    }

    log("Target process launched (pid %)!\n", target.pid);

    target.state = .PAUSED;
    
    if address {
        add_breakpoint(*target, address);
    }

    fcntl(target.output_pipe, F_SETFL, fcntl(target.output_pipe, F_GETFL) | O_NONBLOCK);
    fcntl(target.error\_pipe, F_SETFL, fcntl(target.error\_pipe, F_GETFL) | O_NONBLOCK);
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);

    poll_fds: [4] pollfd;
    poll_fds[0].fd = target.output_pipe;
    poll_fds[0].events = POLLIN;
    poll_fds[1].fd = target.error_pipe;
    poll_fds[1].events = POLLIN;
    poll_fds[2].fd = STDIN_FILENO;
    poll_fds[2].events = POLLIN;
    num_fds: u32 = 3;

    // Using a timer for this SUCKS because it introduces a fixed delay to everything the debugger does.
    // But there’s no clean way of waiting for child events like waitpid does, but with using poll().
    // Linux 5.3 introduced "pidfd_open" that _should_ solve that issue.
    // But that’s not available on Ubuntu 18.04 (kernel’s too old).
    // So we will have to create a separate thread that does the waitpid stuff and signals the main thread
    // or whatever. Sigh.
    //      - rluba 2021-12-01
    timer_fd: s32 = -1;
    timer_fd_index: int = ---;
    defer {
        if timer_fd != -1 {
            close(timer_fd);
        }
    }

    if timeout_ms {
        timer_fd, success = create_timer(timeout_ms);
        if !success {
            try_kill_and_reap(target.pid);
            return 1;
        }
                    
        timer_fd_index = num_fds;
        poll_fds[num_fds].fd = timer_fd;
        poll_fds[num_fds].events = POLLIN;
        num_fds += 1;
    }

    target_exit_code: s32;
    pending_action := Debugger_Action.NOTHING;
    next_action := Debugger_Action.NOTHING;
    source_display := Source_Display.DISASSEMBLY;
    while true {
        num_events := poll(poll_fds.data, num_fds, -1);
        success := true;
        if poll_fds[0].revents & POLLIN {
            success = print_entire_pipe(target.output_pipe);
        }
        if poll_fds[1].revents & POLLIN {
            success = print_entire_pipe(target.error_pipe) && success;
        }
        if poll_fds[2].revents & POLLIN {
            input_buffer: [1] u8;
            read_success, num_read := get_input(input_buffer);
            if read_success {
                assert(num_read > 0);
                if input_buffer[0] == {
                    case #char "c";
                        next_action = .CONTINUE;
                    case #char "s";
                        next_action = .STEP;
                    case #char "d";
                        if source_display == {
                            case .DISASSEMBLY;  source_display = .SOURCE;
                            case .SOURCE;       source_display = .DISASSEMBLY;
                        }
                        if !print_source(*target, source_display)   return 1;
                }
                if next_action != .NOTHING {
                    log("Next action: %\n", next_action);
                }
            }
            success = read_success && success;
        }
        if !success {
            log_error("Couldn’t read events\n");
            try_kill_and_reap(target.pid);
            return 1;
        }

        if poll_fds[0].revents & POLLHUP    target.done_output = true;
        if poll_fds[1].revents & POLLHUP    target.done_error = true;

        if timeout_ms && poll_fds[timer_fd_index].revents & POLLIN {
            num_exp: u64;
            size_read := read(timer_fd, *num_exp, size_of(type_of(num_exp)));
            if size_read != size_of(type_of(num_exp)) {
                log_error("Couldn’t read timer: % (read %)\n", errno(), size_read);
            }
        }

        if target.state == .RUNNING {
            status: s32 = ---;
            wait_result := waitpid(target.pid, *status, WNOHANG);
            if wait_result == -1 {
                log_error("Couldn’t wait for target process: %\n", errno());
                try_kill_and_reap(target.pid);
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
                        target_exit_code = cast(s32) WEXITSTATUS(status);
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
                    try_kill_and_reap(target.pid);
                    return 1;
                }
            }
        }

        if target.state != .RUNNING {
            success = true;
            if pending_action != .NOTHING {
                // log("Taking pending action: %\n", pending_action);
                success, pending_action = take_action(*target, pending_action);
            } else if next_action != .NOTHING {
                // log("Taking next action: %\n", next_action);
                success, pending_action = take_action(*target, next_action);
                next_action = .NOTHING;
            }
            if !success {
                try_kill_and_reap(target.pid);
                return 1;
            }
        }
    }

    log("BYEEEEE\n");
    return 0;
}

#scope_file

print_entire_pipe :: (fd: s32) -> success: bool {
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

        buffer_str := to_string(buffer.data, bytes_read);
        print("%", buffer_str);
    }

    return true;
}


#load "target.jai";
#load "logger.jai";
#load "termios.jai";
#load "xed.jai";
