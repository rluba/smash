Target :: struct {
    pid: pid_t = -1;
    output_pipe: s32 = -1;
    error_pipe: s32 = -1;
    timer_fd: s32 = -1;

    done_output: bool;
    done_error: bool;
    state: Target_State;
    breakpoints: [..] Breakpoint;

    registers: User_Regs;
    fp_registers: User_Fpregs;

    temporarily_disabled_breakpoint_index: int = -1;

    instruction_addresses: [..] u64;
    instructions: [..] Xed_Decoded_Inst;
    debug_info: Debug_Info;

    source_files: [..] string;
    source_files_content: [..] string;
}

Target_State :: enum {
    NONE;
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

    log("Adding new breakpoint at 0x%\n", formatHex64(address));

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
    // log("Enabling breakpoint at 0x%\n", formatHex64(breakpoint.address));
    aligned_address := breakpoint.address & ~(0x7);
    target_offset := breakpoint.address - aligned_address;

    modified_word := breakpoint.original_instruction_word & ~(0xFF << (target_offset * 8));
    modified_word |= OPCODE_INT3 << (target_offset * 8);
    // log("Original: %\nModified: %\n", formatHex64(breakpoint.original_instruction_word), formatHex64(modified_word));
    result := ptrace(.POKETEXT, pid, cast(*void)aligned_address, cast(*void)modified_word);
    if result != 0 {
        log_error("Could not update program text at address %: %\n", formatHex64(aligned_address), errno());
        return false;
    }

    return true;
}

disable_breakpoint :: (using target: *Target, breakpoint_index: int) -> success: bool {
    breakpoint := target.breakpoints[breakpoint_index];
    // log("Disabling breakpoint at 0x%\n", formatHex64(breakpoint.address));

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
    log("RIP: %\n", formatHex64(registers.rip));
    log("Registers: %\n", registers);
    // log("FP Registers: %\n", fp_registers);
}

Source_Display :: enum {
    DISASSEMBLY;
    SOURCE;
}

print_source :: (using target: *Target, source_display: Source_Display) -> success: bool {
    rip := target.registers.rip;
    if source_display == {
        case .DISASSEMBLY;
            rip_instruction_index := -1;
            for instruction_addresses {
                if rip == it {
                    rip_instruction_index = it_index;
                    break;
                }
            }
            if rip_instruction_index == -1 {
                log_error("Could not find instruction for RIP %\n", formatHex64(rip));
            } else {
                start := Max(rip_instruction_index - 5, 0);
                end := Min(rip_instruction_index + 5, instructions.count - 1);
                for start..end {
                    inst := *instructions[it];
                    success := print_instruction(<<inst, instruction_addresses[it], it == rip_instruction_index);
                    if !success {
                        log_error("Could not print instruction at %\n", formatHex64(instruction_addresses[it]));
                        return false;
                    }
                }
            }
        case .SOURCE; 
            cu: *Compilation_Unit;
            for * debug_info.compilation_units {
                if rip >= it.low_pc && rip < it.high_pc {
                    log("Source is from compilation unit %\n", it_index);
                    cu = it;
                    break;
                }
            }
            if !cu {
                log_error("Couldn’t find compilation unit for RIP %\n", formatHex64(rip));
                return true;
            }
            for cu.line_info.addresses {
                if rip < it {
                    if it_index == 0 {
                        log_error("RIP % is not covered by line info\n", formatHex64(rip));
                        return true;
                    }

                    mapping := cu.line_info.mappings[it_index - 1];
                    filename: string;
                    if mapping.file_id > 0 {
                        file_info := cu.line_info.files[mapping.file_id - 1];
                        if file_info.dir_id > 0 {
                            filename = tprint("%/%", cu.line_info.dirs[file_info.dir_id - 1], file_info.path);
                        } else {
                            filename = file_info.path;
                        }
                    }
                    source: string;
                    if filename {
                        for source_files {
                            if it == filename {
                                source = source_files_content[it_index];
                                break;
                            }
                        }
                        if !source {
                            array_add(*source_files, filename);
                            success: bool;
                            source, success = read_entire_file(filename);
                            if !success {
                                log_error("Could not load source file %\n", filename);
                            }
                            array_add(*source_files_content, source);
                        }
                    } else {
                        filename = "(unknown file)";
                    }

                    log("File: % line: % column: %\n", filename, mapping.line, mapping.column); 
                    if mapping.line > 0 && source {
                        source_line_index := cast (s64) mapping.line - 1;
                        source_lines := split(source, "\n");
                        start := Max(source_line_index - 5, 0);
                        end := Min(source_line_index + 5, source_lines.count - 1);
                        for start..end {
                            if it == source_line_index {
                                log("-> %\n", source_lines[it]);
                            } else {
                                log("   %\n", source_lines[it]);
                            }
                        }
                    }

                    break;
                }
            }


    }

    return true;
}

fetch_signal_info :: (using target: *Target) -> success: bool, result: Siginfo {
    info: Siginfo;
    result := ptrace(.GETSIGINFO, pid, null, *info);
    if result != 0 {
        log_error("Could not get signal info. .GETSIGINFO failed with errno %\n", errno());
        return false, info;
    }

    return true, info;
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
    if !pid     return;

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

decode_instruction :: (elf: *Elf, offset: s64, inst: *Xed_Decoded_Inst) -> success: bool {
    xed_decoded_inst_zero(inst);
    xed_decoded_inst_set_mode(inst, .LONG_64, .WIDTH_64B);

    error := xed_decode(inst, elf.text.data + offset, cast (u32) (elf.text.count - offset));
    if error != .NONE {
        log_error("Could not decode instruction: %\n", error);
        return false;
    }

    return true;
}

print_instruction :: (inst: Xed_Decoded_Inst, address: u64, is_current_instruction: bool) -> success: bool {
    // log("Instruction: %\n", inst);
    inst_buffer: [32] u8; 
    success := xed_format_context(.ATT, *inst, inst_buffer.data, inst_buffer.count, address, null, null);
    if !success {
        log_error("Could not format instruction\n");
        return false;
    }

    inst_str := to_string(inst_buffer.data);
    if is_current_instruction {
        log("-> %\n", inst_str);
    } else {
        log("   %\n", inst_str);
    }
    return true;
}

#scope_module 

formatHex64 :: #bake_arguments formatInt(base = 16, minimum_digits = 16);

OPCODE_INT3 :: 0xCC;

#scope_file

#import "Basic";
#import "POSIX";
#import "Command_Line";
#import "String";

#load "dwarf/dwarf.jai";
#load "elf.jai";
// #load "logger.jai";
#load "ptrace.jai";
// #load "xed.jai";
