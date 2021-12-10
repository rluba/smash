Line_Info :: struct {
    dirs: [..] string;
    files: [..] File_Info;
    addresses: [..] u64;
    mappings: [..] Line_Mapping;
}

File_Info :: struct {
    dir_id: u64;
    path: string;
}

Line_Mapping :: struct {
    file_id: u32;
    line: u32;
    column: u32;
    is_end: bool;
}

Line_Program_Header :: struct {
    size: u32;
    version: u16;
    header_length: u32 #align 2;
    minimum_instruction_length: u8;
    maximum_operations_per_instruction: u8;
    default_is_stmt: bool;
    line_base: s8;
    line_range: u8;
    opcode_base: u8;
} #no_padding;

decode_line_info :: (elf: Elf, data: [] u8) -> Line_Info, success: bool {
    info: Line_Info;

    header := cast(*Line_Program_Header) data.data;

    if header.size == 0xffff_ffff {
        log_error("We dont support 64 bit DWARF format yet.");
        return info, false;
    }

    program_end := header.size + size_of(type_of(header.size));
    if program_end > data.count {
        log_error("Invalid line program size: %\n", header.size);
        return info, false;
    }

    if header.version != 4 {
        log_error("Line program has unsupported DWARF version: %\n", header.version);
        return info, false;
    }

    if (cast(*u8)*header.minimum_instruction_length) + header.header_length > data.data + data.count {
        log_error("Invalid line program header length: %\n", header.header_length);
        return info, false;
    }

    offset := size_of(Line_Program_Header);

    if offset + header.opcode_base - 1> data.count {
        log_error("Invalid line program opcode base: %\n", header.opcode_base);
        return info, false;
    }

    standard_opcode_lengths: [] u8 = array_view(data, offset, header.opcode_base - 1);

    // log("Opcode lengths: %\n", standard_opcode_lengths);

    offset += header.opcode_base - 1;

    while true {
        dir, success := get_c_string_from_data(data, offset);
        if !success     return info, false;

        offset += dir.count + 1;
        if !dir break;

        array_add(*info.dirs, dir);
    }

    success: bool = ---;
    while true {
        file: File_Info = ---;
        file, offset, success = parse_file_info(info, data, offset, stop_at_zero = true);
        if !success     return info, false;

        if !file.path   break;

        array_add(*info.files, file);
    }

    state: Line_Program_State;
    state.file_id = 1;
    state.line = 1;
    state.is_stmt = header.default_is_stmt;
    while offset < program_end {
        byte := data[offset];
        offset += 1;
        if byte >= header.opcode_base {
            apply_special_opcode(*info, *state, byte, <<header);
        } else {
            if cast(Line_Program_Operation) byte == {
                case .EXTENDED_OPERATION;
                    len: u64 = ---;
                    len, offset, success = parse_uleb128(data, offset);
                    if !success                     return info, false;
                    if offset + cast (s64) len > data.count    {
                        log_error("Line program: Extended operation went out of bounds!\n");
                        return info, false;
                    }
                    op_start_offset := offset;
                    extended_op := cast(Line_Program_Extended_Operation) data[offset];
                    offset += 1;
                    if extended_op == {
                        case .END_SEQUENCE;
                            state.is_end = true;
                            array_add(*info.addresses, state.address);
                            array_add(*info.mappings, state.mapping);
                            // log("\t0x%: %\n", formatHex64(state.address), state.mapping);
                            offset += xx len - 1;
                            break;

                        case .SET_ADDRESS;
                            state.address, offset, success = parse_integer(data, offset, u64);

                        case .DEFINE_FILE;
                            file: File_Info = ---;
                            file, offset, success = parse_file_info(info, data, offset, stop_at_zero = false);
                            if !success     return info, false;

                            array_add(*info.files, file);

                        case .SET_DISCRIMINATOR;
                            state.discriminator, offset, success = parse_uleb128(data, offset);
                            if !success     return info, false;

                        case;
                            log_error("Found unknown extended line program operation: %\n", extended_op);
                            offset += xx len;
                    }
                    if op_start_offset + xx len != offset {
                        log_error("Invalid extended operator length for %: % vs %\n", extended_op, len, offset - op_start_offset);
                        return info, false;
                    }

                case .COPY;
                    array_add(*info.addresses, state.address);
                    array_add(*info.mappings, state.mapping);
                    // log("\t0x%: %\n", formatHex64(state.address), state.mapping);
                    state.discriminator = 0;
                    state.basic_block = false;
                    state.prologue_end = false;
                    state.epilogue_begin = false;
                case .ADVANCE_PC;
                    operation_advance: u64 = ---;
                    operation_advance, offset, success = parse_uleb128(data, offset);
                    if !success     return info, false;

                    advance_address(*state, operation_advance, <<header);
                case .ADVANCE_LINE;
                    delta: s64 = ---;
                    delta, offset, success = parse_sleb128(data, offset);
                    if !success     return info, false;
                    // log("Line delta: %\n", delta);

                    state.line = xx (cast(s64) state.line + delta);
                case .SET_FILE;
                    state.file_id, offset, success = parse_uleb128(data, offset, u32);
                    if !success     return info, false;
                case .SET_COLUMN;
                    state.column, offset, success = parse_uleb128(data, offset, u32);
                    if !success     return info, false;
                case .NEGATE_STMT;
                    state.is_stmt = !state.is_stmt;
                case .SET_BASIC_BLOCK;
                    state.basic_block = true;
                case .CONST_ADD_PC;
                    adjusted_opcode := 255 - header.opcode_base;
                    operation_advance := adjusted_opcode / header.line_range;
                    advance_address(*state, operation_advance, <<header);
                case .FIXED_ADVANCE_PC;
                    value: u16 = ---;
                    value, offset, success = parse_integer(data, offset, u16);
                    if !success     return info, false;
                    state.address += value;
                    state.op_index = 0;
                case .SET_PROLOGUE_END;
                    state.prologue_end = true;
                case .SET_EPILOGUE_BEGIN;
                    state.epilogue_begin = true;
                case .SET_ISA;
                    state.isa, offset, success = parse_uleb128(data, offset);
                    if !success     return info, false;
                case;
                    log_error("Found unknown line code operation: %\n", byte);
                    // @ToDo: Skip over this based on the header information
                    return info, false;
            }
        }
    }
    if offset != program_end {
        log_error("Line program end does not match header value: % vs %\n", offset, program_end);
        return info, false;
    }

    // log("Line info: %\n", info);

    // log("Line table:\n");
    // for info.addresses {
    //     log("\t0x%: %\n", formatHex64(it), info.mappings[it_index]);
    // }


    return info, true;
}

parse_file_info :: (info: Line_Info, data: [] u8, offset_in: s64, stop_at_zero: bool) -> File_Info, offset: s64, success: bool {
    offset := offset_in;
    file: File_Info = ---;
    success: bool = ---;
    file.path, success = get_c_string_from_data(data, offset);
    if !success     return file, offset, false;

    offset += file.path.count + 1;
    if !file.path && stop_at_zero {
        return file, offset, true;
    }

    file.dir_id, offset, success = parse_uleb128(data, offset);
    if !success     return file, offset, false;
    if xx file.dir_id > info.dirs.count {
        log_error("File’s dir ID is out of bounds: %\n", file.dir_id);
        return file, offset, false;
    }

    mod_time: u64 = ---;
    mod_time, offset, success = parse_uleb128(data, offset);
    if !success     return file, offset, false;

    length: u64 = ---;
    length, offset, success = parse_uleb128(data, offset);
    if !success     return file, offset, false;

    return file, offset, true;
}

Line_Program_State :: struct {
    address: u64;
    op_index: u64; // Could be way smaller
    using mapping: Line_Mapping;
    is_stmt: bool;
    basic_block: bool;
    prologue_end: bool;
    epilogue_begin :bool;
    discriminator: u64;
    isa: u64;
}

apply_special_opcode :: (info: *Line_Info, state: *Line_Program_State, opcode: u8, header: Line_Program_Header) {
    adjusted_opcode := opcode - header.opcode_base;
    // log("special opcode %", opcode);
    operation_advance := adjusted_opcode / header.line_range;
    advance_address(state, operation_advance, header);
    line_delta := header.line_base + cast (s64) (adjusted_opcode % header.line_range);
    // log("special opcode line delta %", line_delta);
    state.line = xx (cast (s64) state.line + line_delta);

    array_add(*info.addresses, state.address);
    array_add(*info.mappings, state.mapping);
    // log("\t0x%: %\n", formatHex64(state.address), state.mapping);

    state.basic_block = false;
    state.prologue_end = false;
    state.epilogue_begin = false;
    state.discriminator = 0;
}

advance_address :: (state: *Line_Program_State, operation_advance: u64, header: Line_Program_Header) {
    // log("Advance address % for % (%)\n", operation_advance, formatHex64(state.address), state.op_index);
    state.address += header.minimum_instruction_length * ((state.op_index + operation_advance) / header.maximum_operations_per_instruction);
    state.op_index = (state.op_index + operation_advance) % header.maximum_operations_per_instruction;
    // log("After advance: % (%)\n", formatHex64(state.address), state.op_index);
}

Line_Program_Operation :: enum {
    EXTENDED_OPERATION  :: 0x00;
    COPY                :: 0x01;
    ADVANCE_PC;
    ADVANCE_LINE;
    SET_FILE;
    SET_COLUMN;
    NEGATE_STMT;
    SET_BASIC_BLOCK;
    CONST_ADD_PC;
    FIXED_ADVANCE_PC;
    SET_PROLOGUE_END;
    SET_EPILOGUE_BEGIN;
    SET_ISA;
}

Line_Program_Extended_Operation :: enum {
    END_SEQUENCE        :: 0x01;
    SET_ADDRESS;
    DEFINE_FILE;
    SET_DISCRIMINATOR;
}
