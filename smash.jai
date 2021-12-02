
Args :: struct {
    work_dir: string;
    breakpoint: string;
}
timeout_ms := 10;

main :: () {
    args_success, args, is_set, extra_args := parse_arguments(Args, allow_free_arguments = true);
    if !args_success {
        log_error("Could not parse arguments\n");
        exit(1);
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
            print("Could not parse breakpoint address\n");
            exit(1);
        }
        address = cast(u64) result;
    }

    target_args := extra_args;
    if !target_args {
        log_error("Usage: % [-work_dir <dir>] [-breakpoint <address>] [--] <program to run + args>", get_command_line_arguments()[0]);
        exit(1);
    }

    old_teminal_settings: termios;
    {
        result := tcgetattr(STDIN_FILENO, *old_teminal_settings);
        if result != 0 {
            log_error("Could not get terminal settings: %", errno());
            exit(1);
        }
        new_settings := old_teminal_settings;
        new_settings.c_lflag &= ~(Terminal_Lflags.ICANON | .ECHO);
        result = tcsetattr(STDIN_FILENO, .TCSANOW, *new_settings);
        if result != 0 {
            log_error("Could not set terminal settings: %", errno());
            exit(1);
        }
    }
    defer {
        result := tcsetattr(STDIN_FILENO, .TCSANOW, *old_teminal_settings);
        if result != 0 {
            log_error("Could not restore old terminal settings: %", errno());
        }
    }

    target_program_path := target_args[0];
    success := read_target_program(target_program_path);
    if !success {
        log_error("Could not read target program\n");
        exit(1);
    }

    command := join(.. target_args, separator = " ");
    defer free(command);
    print("Launching %\n", command);

    target: Target;
    success, target.pid, target.output_pipe, target.error_pipe = spawn_target_process(target_args, args.work_dir);
    if !success {
        log_error("Failed to spawn target process!\n");
        exit(-1);
    }

    defer {
        close(target.output_pipe);
        close(target.error_pipe);
    }

    print("Target process launched (pid %)!\n", target.pid);

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
            exit(1);
        }
                    
        timer_fd_index = num_fds;
        poll_fds[num_fds].fd = timer_fd;
        poll_fds[num_fds].events = POLLIN;
        num_fds += 1;
    }

    exit_code: s32;
    pending_action := Debugger_Action.NOTHING;
    next_action := Debugger_Action.NOTHING;
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
                }
                print("Next action: %\n", next_action);
            }
            success = read_success && success;
        }
        if !success {
            log_error("Couldn’t read events\n");
            try_kill_and_reap(target.pid);
            exit(1);
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
                exit(1);
            }
            if wait_result != 0 {
                print("Something has happened in the target process!\n");
                if WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP {
                    if (target.temporarily_disabled_breakpoint_index != -1) {
                        enable_breakpoint(*target, target.temporarily_disabled_breakpoint_index);
                        target.temporarily_disabled_breakpoint_index = -1;
                    }

                    target.state = .PAUSED;
                    fetch_registers(*target);

                    for target.breakpoints {
                        if it.address == target.registers.rip - 1 {
                            print("We hit breakpoint number %!\n", it_index);

                            target.registers.rip -= 1;
                            set_registers(*target);

                            target.state = .HIT_BREAKPOINT;
                            pending_action = .NOTHING;
                            disable_breakpoint(*target, it_index);
                            target.temporarily_disabled_breakpoint_index = it_index;
                            break;
                        }
                    }

                    if pending_action == .NOTHING {
                        print("Target state changed to %\n", target.state);

                        fetch_fp_registers(*target);
                        print_registers(*target);
                    }
                } else {
                    if WIFEXITED(status) {
                        exit_code = cast(s32) WEXITSTATUS(status);
                        print("Target has exited with code %\n", exit_code);
                        break;
                    }
                    if WIFSIGNALED(status) {
                        signal := WTERMSIG(status);
                        signal_string := to_string(strsignal(signal));
                        log_error("Target was terminated by signal % (%).\n", signal, signal_string);
                        break;
                    }
                    log_error("Something unexpected happened in the target process: %\n", status);
                    try_kill_and_reap(target.pid);
                    exit(-1);
                }
            }
        }

        if target.state != .RUNNING {
            success = true;
            if pending_action != .NOTHING {
                print("Taking pending action: %\n", pending_action);
                success, pending_action = take_action(*target, pending_action);
            } else if next_action != .NOTHING {
                print("Taking next action: %\n", next_action);
                success, pending_action = take_action(*target, next_action);
                next_action = .NOTHING;
            }
            if !success {
                try_kill_and_reap(target.pid);
                exit(-1);
            }
        }
    }

    print("BYEEEEE\n");
}

Target :: struct {
    pid: pid_t;
    output_pipe: s32;
    error_pipe: s32;
    done_output: bool;
    done_error: bool;
    state: Target_State;
    breakpoints: [..] Breakpoint;

    registers: User_Regs;
    fp_registers: User_Fpregs;

    temporarily_disabled_breakpoint_index: int = -1;
}

Target_State :: enum {
    RUNNING;
    PAUSED;
    HIT_BREAKPOINT;
}

Breakpoint :: struct {
    address: u64;
    original_instruction_word: s64;
}

add_breakpoint :: (using target: *Target, address: u64) -> success: bool, breakpoint: Breakpoint {
    for breakpoints {
        if it.address == address {
            return true, it;
        }
    }

    print("Adding new breakpoint at 0x%\n", formatHex64(address));

    aligned_address := address & ~(0x7);
    target_offset := address - aligned_address;

    set_errno(0);
    original_word := ptrace(.PEEKTEXT, pid, cast(*void)aligned_address, null);
    if original_word == -1 {
        error := errno();
        if error != 0 {
            log_error("Could not get program text at address %: %\n", formatHex64(aligned_address), error);
            return false, .{};
        }
    }

    breakpoint: Breakpoint;
    breakpoint.address = address;
    breakpoint.original_instruction_word = original_word;
    array_add(*breakpoints, breakpoint);

    success := enable_breakpoint(target, breakpoints.count - 1);
    return success, breakpoint;
}

enable_breakpoint :: (using target: *Target, breakpoint_index: int) -> success: bool {
    breakpoint := target.breakpoints[breakpoint_index];
    print("Enabling breakpoint at 0x%\n", formatHex64(breakpoint.address));
    aligned_address := breakpoint.address & ~(0x7);
    target_offset := breakpoint.address - aligned_address;

    modified_word := breakpoint.original_instruction_word & ~(0xFF << (target_offset * 8));
    modified_word |= OPCODE_INT3 << (target_offset * 8);
    print("Original: %\nModified: %\n", formatHex64(breakpoint.original_instruction_word), formatHex64(modified_word));
    result := ptrace(.POKETEXT, pid, cast(*void)aligned_address, cast(*void)modified_word);
    if result != 0 {
        log_error("Could not update program text at address %: %\n", formatHex64(aligned_address), errno());
        return false;
    }

    return true;
}

disable_breakpoint :: (using target: *Target, breakpoint_index: int) -> success: bool {
    breakpoint := target.breakpoints[breakpoint_index];
    print("Disabling breakpoint at 0x%\n", formatHex64(breakpoint.address));

    aligned_address := breakpoint.address & ~(0x7);
    target_offset := breakpoint.address - aligned_address;

    result := ptrace(.POKETEXT, pid, cast(*void)aligned_address, cast(*void)breakpoint.original_instruction_word);
    if result != 0 {
        log_error("Could not update program text at address %: %\n", formatHex64(aligned_address), errno());
        return false;
    }

    return true;
}

Debugger_Action :: enum {
    NOTHING;
    CONTINUE;
    STEP;
}

take_action :: (using target: *Target, action: Debugger_Action) -> success: bool, pending_action: Debugger_Action {
    pending_action := Debugger_Action.NOTHING;
    if action == {
        case .STEP;
            result := ptrace(.SINGLESTEP, target.pid, null, null);
            if result != 0 {
                log_error("Could not continue. .STEP failed with errno %\n", errno());
                return false, .NOTHING;
            }
        case .CONTINUE;
            request := Ptrace_Request.CONT;
            if target.state == .HIT_BREAKPOINT {
                request = .SINGLESTEP;
                pending_action = action;
            }

            result := ptrace(request, target.pid, null, null);
            if result != 0 {
                log_error("Could not continue. .% failed with errno %\n", request, errno());
                return false, .NOTHING;
            }
    }
    target.state = .RUNNING;
    return true, pending_action;
}

print_target_output :: (using target: *Target) -> success: bool {
    success := print_entire_pipe(output_pipe);
    success &&= print_entire_pipe(error_pipe);
    if !success {
        log_error("Couldn’t read output\n");
        return false;
    }

    return true;
}

fetch_registers :: (using target: *Target) -> success: bool {
    result := ptrace(.GETREGS, pid, null, *target.registers);
    if result != 0 {
        log_error("Could not get registers. .GETREGS failed with errno %\n", errno());
        return false;
    }

    return true;
}

set_registers :: (using target: *Target) -> success: bool {
    result := ptrace(.SETREGS, pid, null, *target.registers);
    if result != 0 {
        log_error("Could not set registers. .SETREGS failed with errno %\n", errno());
        return false;
    }

    return true;
}

fetch_fp_registers :: (using target: *Target) -> success: bool {
    result := ptrace(.GETFPREGS, pid, null, *target.fp_registers);
    if result != 0 {
        log_error("Could not get FP registers. .GETFPREGS failed with errno %\n", errno());
        return false;
    }

    return true;
}

print_registers :: (using target: *Target) {
    print("RIP: %\n", formatHex64(registers.rip));
    print("Registers: %\n", registers);
    // print("FP Registers: %\n", fp_registers);
}

spawn_target_process :: (cmd: [] string, working_directory: string) -> success: bool, pid: pid_t, output_pipe: s32, error_pipe: s32 {
    output_pipes        : [2] s32;
    error_pipes         : [2] s32;
    // Used to communicate from the child process if
    // the command was not able to be executed.
    process_status_pipes: [2] s32;

    pipe(*output_pipes);
    pipe(*error\_pipes);
    pipe(*process_status_pipes);

    pid := fork();

    if pid < 0 {
        log_error("Couldn’t fork: %\n", errno());
        return false, -1, -1, -1;
    }

    if pid == 0 {
        // we're in the child process
        if working_directory != "" set_working_directory(working_directory);

        close(process_status_pipes[0]);

        // close the input pipes
        close(output_pipes[0]);
        close(error\_pipes[0]);

        // map the file descriptors from pipe() to this process' stdout and stderr handles
        if dup2(output_pipes[1], 1) < 0 then exit(-1);
        if dup2(error\_pipes[1], 2) < 0 then exit(-1);

        c_cmd: [..] *u8;
        for cmd {
            array_add(*c_cmd, to_c_string(it));
        }
        // the list must be null terminated
        array_add(*c_cmd, null);

        ptrace_result := ptrace(.TRACEME, 0, null, null);
        if ptrace_result == 0 {
            execvp(c_cmd[0], c_cmd.data);
        } else {
            log_error("Could not start tracing. TRACEME failed with errno %\n", errno());
        }

        error := errno();
        write(process_status_pipes[1], *error, size_of(type_of(error)));

        exit(error);
        // silence not-all-control-paths return
        return false, -1, -1, -1;
    } else {
        // parent process
        close(process_status_pipes[1]);
        defer {
            close(process_status_pipes[0]);
        }

        fcntl(process_status_pipes[0], F_SETFL, fcntl(process_status_pipes[0], F_GETFL) | O_NONBLOCK);

        // Close our copy of the child’s I/O file descriptors.
        // Otherwise we won’t get a HUP event when the child dies.
        close(output_pipes[1]);
        close(error_pipes[1]);

        // Wait for the child to hit the sigtrap form the .TRACEME call.
        status: s32;
        result := waitpid(pid, *status, 0);
        if result == -1 {
            log_error("Couldn’t wait for the child process: %\n", errno());
        }
        if (WIFEXITED(status)) {
            exit_code := cast(u32) WEXITSTATUS(status);
            log_error("Target process exited with code % without hitting the trap.\n", exit_code);
            // Get the details
            {
                status: u32;
                // read process status pipe, if there is data there, the child process
                // failed to execute the command we gave it, and wrote the errno value
                // into the pipe.
                result := read(process_status_pipes[0], *status, size_of(type_of(status)));
                if (result > 0) {
                    log_error("Command failed with errno %.\n", status);
                }
            }
            return false, pid, output_pipes[0], error_pipes[0];
        } else if (WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP) {
            // Everything as expected
        } else {
            log_error("Unexpected status: %", status);
            if WIFSIGNALED(status) {
                signal := WTERMSIG(status);
                signal_string := to_string(strsignal(signal));
                log_error("Command was terminated by signal % (%).\n", signal, signal_string);
            }
            return false, pid, output_pipes[0], error_pipes[0];
        }



        return true, pid, output_pipes[0], error_pipes[0];
    }
}

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

get_input :: (buffer: [] u8) -> success: bool, num_read: int {
    total := 0;
    while true {
        bytes_read := read(STDIN_FILENO, buffer.data, cast(u64) buffer.count);
        if bytes_read == 0          break;

        if bytes_read < 0 {
            read_error := errno();
            if read_error == EAGAIN || read_error == EWOULDBLOCK {
                // @Incomplete: Also ignore EINTR?
                break;
            }
            return false, total;
        }

        total += bytes_read;
        if total == buffer.count    break;
    }

    return true, total;
}


try_kill_and_reap :: (pid: pid_t) {
    status: s32;
    result := kill(pid, SIGKILL);
    if result == -1 {
        log_error("Couldn’t kill child %: %\n", pid, errno());
        return;
    }
    // Remove the zombie child process
    result = waitpid(pid, *status, 0);
    if (result == -1) {
        log_error("Couldn’t reap child %: %\n", pid, errno());
    }
}

create_timer :: (timeout_ms: int) -> timer_fd: s32, success: bool {
    timer_fd := timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
    if timer_fd == -1 {
        log_error("Couldn’t create timer fd: %\n", errno());
        return -1, false;
    }

    timeout_spec: timespec;
    timeout_spec.tv_sec = timeout_ms / 1000;
    timeout_spec.tv_nsec = (timeout_ms % 1000) * 1000 * 1000;
    timer_spec: itimerspec;
    timer_spec.it_interval = timeout_spec; // Recurring timeout
    timer_spec.it_value = timeout_spec;    // first-time timeout
    result := timerfd_settime(timer_fd, 0, *timer_spec, null);
    if (result == -1) {
        log_error("Couldn’t set timer: %\n", errno());
        close(timer_fd);
        return -1, false;
    }

    return timer_fd, true;
}


#scope_file

OPCODE_INT3 :: 0xCC;

formatHex64 :: #bake_arguments formatInt(base = 16, minimum_digits = 16);

#import "Basic";
#import "POSIX";
#import "Command_Line";
#import "String";

#load "ptrace.jai";
#load "elf.jai";
#load "termios.jai";
