main :: () {
    success, pid, output_pipe, error_pipe := spawn_target_process(.["echo", "hello debugger"], "");
    if !success {
        log_error("Failed to spawn target process!\n");
        exit(-1);
    }

    defer {
        close(output_pipe);
        close(error_pipe);
    }

    print("Target process launched!\n");
    ptrace(.CONT, pid, null, null);

    timeout_ms := 0;

    poll_fds: [3] pollfd;
    poll_fds[0].fd = output_pipe;
    poll_fds[0].events = POLLIN;
    poll_fds[1].fd = error_pipe;
    poll_fds[1].events = POLLIN;
    num_fds: u32 = 2;

    timer_fd: s32 = -1;
    defer {
        if timer_fd != -1 {
            close(timer_fd);
        }
    }

    timeout_reached := false;
    if timeout_ms {
        timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
        if timer_fd == -1 {
            log_error("Couldn’t create timer fd: %\n", errno());
            try_kill_and_reap(pid);
            exit(-1);
        }

        poll_fds[num_fds].fd = timer_fd;
        poll_fds[num_fds].events = POLLIN;
        num_fds += 1;

        timeout_spec: timespec;
        timeout_spec.tv_sec = timeout_ms / 1000;
        timeout_spec.tv_nsec = (timeout_ms % 1000) * 1000 * 1000;
        timer_spec: itimerspec;
        timer_spec.it_value = timeout_spec;
        result := timerfd_settime(timer_fd, 0, *timer_spec, null);
        if (result == -1) {
            log_error("Couldn’t set timer: %\n", errno());
            try_kill_and_reap(pid);
            exit(-1);
        }
    }

    fcntl(output_pipe, F_SETFL, fcntl(output_pipe, F_GETFL) | O_NONBLOCK);
    fcntl(error\_pipe, F_SETFL, fcntl(error\_pipe, F_GETFL) | O_NONBLOCK);

    output_builder: String_Builder;
    error_builder : String_Builder;
    defer {
        free_buffers(*output_builder);
        free_buffers(*error_builder);
    }

    done_output: bool;
    done_error: bool;
    while true {
        num_events := poll(poll_fds.data, num_fds, -1);
        // @Speed: Only read from the pipe we got a POLLIN signal from?
        success := read_entire_pipe(output_pipe, *output_builder, true);
        success &&= read_entire_pipe(error\_pipe, *error_builder, true);
        if !success {
            log_error("Couldn’t read output\n");
            break;
        }

        if poll_fds[0].revents & POLLHUP    done_output = true;
        if poll_fds[1].revents & POLLHUP    done_error = true;

        if timeout_ms && poll_fds[2].revents & POLLIN {
            num_exp: u64;
            size_read := read(timer_fd, *num_exp, size_of(type_of(num_exp)));
            if size_read != size_of(type_of(num_exp)) {
                log_error("Couldn’t read timer: % (read %)\n", errno(), size_read);
            }

            // We’ve hit a timeout! Time to kill the child. (will be reaped below)
            timeout_reached = true;
            result := kill(pid, SIGKILL);
            if result == -1 {
                log_error("Couldn’t kill child %: %\n", pid, errno());
            }
            break;
        }

        if done_output && done_error    break;
    }

    // Reap the zombie child process
    status: s32 = ---;
    result := waitpid(pid, *status, 0);
    if result == -1 {
        log_error("Couldn’t reap child process: %\n", errno());
        exit(1);
    }

    output_string := builder_to_string(*output_builder);
    error_string  := builder_to_string(*error_builder);

    exit_code: u32;
    if WIFEXITED(status) {
        exit_code = cast(u32) WEXITSTATUS(status);
    } else {
        log_error("Unexpected child status after reaping: %\n", status);
        // Set an exit_code here so that on a successful launch, user code
        // doesnt assume the child process exited normally.
        exit_code = 1;
    }
    if timeout_reached exit_code = 1;

    if WIFSIGNALED(status) {
        signal := WTERMSIG(status);
        signal_string := to_string(strsignal(signal));
        log_error("Command was terminated by signal % (%).\n", signal, signal_string);
    }
    
    print("Full output was:\n%\n\nFull error output was:\n%\n", output_string, error_string);
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

        ptrace(.TRACEME, 0, null, null);
        
        execvp(c_cmd[0], c_cmd.data);

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

read_entire_pipe :: (fd: s32, builder: *String_Builder, print_result: bool) -> success: bool {
    buffer: [2048] u8;
    while true {
        bytes_read := read(fd, buffer.data, buffer.count-1);
        if bytes_read == 0  return true;
        if bytes_read < 0 {
            read_error := errno();
            if read_error == EAGAIN || read_error == EWOULDBLOCK {
                // @Incomplete: Also ignore EINTR?
                break;
            }
            return false;
        }

        append(builder, buffer.data, bytes_read);
        if print_result {
            buffer_str := to_string(buffer.data, bytes_read);
            print("%", buffer_str);
        }
    }

    return true;
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

#scope_file

#import "Basic";
#import "POSIX";

#load "ptrace.jai";
