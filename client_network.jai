network_thread: Thread;


Connection_Status :: enum {
    DISCONNECTED;
    CONNECTING;
    CONNECTED;
}

connection_status: Connection_Status;

Network_Command_Type :: enum {
    NONE;
    CONNECT;
}

Server :: struct {
    name: string;
    port: u16;
}

Network_Command :: struct {
    type: Network_Command_Type;
    union {
        server: Server;
    }
}

free_command :: (command: *Network_Command) {
    if #complete command.type == {
        case .NONE;
        case .CONNECT;
            free(command.server.name);
    }

    command.type = .NONE;
}

Network_Result_Type :: enum {
    ERROR;
}

Network_Result :: struct {
    type: Network_Result_Type;
    union {
        error: string;
    }
}

try_get_next_result :: () -> result: Network_Result, success: bool {
    wait_result := wait_for(*network_result_semaphore, 0);
    if wait_result == .ERROR {
        log_error("Could not fetch result!");
        return .{}, false;
    }

    if wait_result == .TIMEOUT   return .{}, false;

    assert(wait_result == .SUCCESS);
    lock(*network_result_mutex);
    defer unlock(*network_result_mutex);
    assert(network_results.count > 0);
    result := network_results[0];
    array_ordered_remove_by_index(*network_results, 0);
    return result, true;
}

free_result :: (result: *Network_Result) {
    if #complete result.type == {
        case .ERROR;
            free(result.error);
    }
}

next_command_mutex: Mutex;
next_command_semaphore: Semaphore;
next_command: Network_Command;

network_result_mutex: Mutex;
network_result_semaphore: Semaphore;
network_results: [..] Network_Result;

client_network_init :: () {
    connection_status = .DISCONNECTED;
    init(*next_command_mutex);
    init(*next_command_semaphore);
    init(*network_result_mutex);
    init(*network_result_semaphore);
    thread_init(*network_thread, network_thread_proc);
    thread_start(*network_thread);
}

client_network_connect :: (server_name: string, port: u16) {
    lock(*next_command_mutex);
    defer unlock(*next_command_mutex);
    free_command(*next_command);
    next_command.type = .CONNECT;
    next_command.server.name = copy_string(server_name);
    next_command.server.port = port;
    connection_status = .CONNECTING;
    signal(*next_command_semaphore);
}

#scope_file

network_thread_proc :: (thread: *Thread) -> s64{
    while true {
        log("Waiting for a command…");
        wait_for(*next_command_semaphore);
        log("Checking next command!");

        {
            lock(*next_command_mutex);
            defer unlock(*next_command_mutex);
            if #complete next_command.type == {
                case .NONE;
                    log_error("Receieved NONE command!");
                    assert(false);
                case .CONNECT;
                    server := next_command.server;
                    try_connect(server);

            }
            free_command(*next_command);
        }
    }
    return 0;
}

try_connect :: (server: Server) {
    server_c_string := to_c_string(server.name);
    defer free(server_c_string);

    addresses: *addrinfo;
    result := getaddrinfo(server_c_string, null, null, *addresses);
    if result != 0 {
        add_error(sprint("Could not look up \"%\": %", server.name, result));
        return;
    }
    defer freeaddrinfo(addresses);

    log("Pretending to connect to %:%\n", <<addresses, server.port);

    // print("Address: ");
    // for addr_data.sa_data print("% ", it);
    // print("\n");
    // sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    // if (sock == -1) {
    //     print("Failed to created TCP socket. Error code: %\n", errno()); 
    //     exit(1);
    // }

    // defer close(sock);

    // if (connect(sock, *addr_data, size_of(type_of(addr_data))) == -1) {
    //     print("Failed to connect. Error code %\n", errno());
    //     exit(1);
    // }
    // hello := "GET / HTTP/1.1\nHost: google.com\nAccept-Language: en\n\n";
    // num_sent := send(sock, hello.data, cast(u64) hello.count, 0);
}

add_error :: (error: string) {
    log_error("Adding error: %", error);
    result: Network_Result;
    result.type = .ERROR;
    result.error = error;
    lock(*network_result_mutex);
    defer unlock(*network_result_mutex);
    array_add(*network_results, result);
    signal(*network_result_semaphore);
}

#import "Thread";
#load "socket.jai";

