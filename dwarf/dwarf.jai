Compliation_Unit_Header_32 :: struct {
    size: u32;
    version: u16;
    debug_abbrev_offset: u32 #align 2;
    address_size: u8;
} #no_padding;
#run assert(size_of(Compliation_Unit_Header_32) == 11, "Invalid compilation unit header size");

Compliation_Unit_Header_64 :: struct {
    size32: u32;
    size64: u64 #align 4;
    version: u16;
    debug_abbrev_offset: u64 #align 2;
    address_size: u8;
} #no_padding;
#run assert(size_of(Compliation_Unit_Header_64) == 23, "Invalid compilation unit header size");

Debug_Info :: struct {
    compilation_units: [..] Compilation_Unit;
}

Compilation_Unit :: struct {
    producer: string;
    language: u16; // could be a u16, but then our parse function needs to be smarter.
    name: string;
    statement_list: u64; // Could be removed, we only need it until we’ve parsed the line info.
    low_pc: u64;
    high_pc: u64;
    line_info: Line_Info;
}

parse_debug_info :: (elf: *Elf) -> Debug_Info, success: bool {
    debug_info: Debug_Info;
    if !elf.debug_info_section {
        log_error("This elf does not include a .debug_info section");
        return debug_info, false;
    }

    if !elf.debug_abbrev_section {
        log_error("This elf does not include a .debug_abbrev section");
        return debug_info, false;
    }

    debug_info_data := get_section_data(<<elf, elf.debug_info_section);
    abbrev := get_section_data(<<elf, elf.debug_abbrev_section);
    line_programs := get_section_data(<<elf, elf.debug_line_section);

    offset := 0;
    while offset < debug_info_data.count {
        header := cast (*Compliation_Unit_Header_32) (debug_info_data.data + offset);
        if header.size == 0xffff_ffff {
            log_error("We dont support 64 bit DWARF format yet.");
            return debug_info, false;
        }
        if header.version != 4 {
            log_error("Compilation unit has unsupported DWARF version: %\n", header.version);
            return debug_info, false;
        }
        if header.address_size != 8 {
            log_error("Compilation unit has unexpected address_size: %\n", header.address_size);
            return debug_info, false;
        }

        // log("Compilation unit header: %\n", <<header);
        cu_end := offset + header.size + size_of(type_of(header.size));
        if cu_end > debug_info_data.count {
            log_error("Invalid compilation unit size: %\n", header.size);
            return debug_info, false;
        }

        abbreviations, success := parse_abbreviations(abbrev, header.debug_abbrev_offset);
        if !success     return debug_info, false;

        cu_start := offset + size_of(Compliation_Unit_Header_32);
        cu_data := array_view(debug_info_data, cu_start, cu_end - cu_start);
        cu: Compilation_Unit = ---;
        cu, success = parse_compilation_unit(<<elf, cu_data, abbreviations);
        if !success     return debug_info, false;

        statement_list_data := array_view(line_programs, xx cu.statement_list);
        cu.line_info, success = decode_line_info(<<elf, statement_list_data);
        if !success     return debug_info, false;

        if !cu.low_pc && cu.line_info.addresses.count {
            cu.low_pc = cu.line_info.addresses[0];
            cu.high_pc = cu.line_info.addresses[cu.line_info.addresses.count - 1];
        }

        array_add(*debug_info.compilation_units, cu);

        offset = cu_end;
    }

    return debug_info, true;
}

Dwarf_Abbreviation_List :: struct {
    ids: [..] u64;
    values: [..] Dwarf_Abbreviation;
}

Dwarf_Abbreviation :: struct {
    tag: Dwarf_Tag;
    has_children: bool;
    attributes: [..] Dwarf_Attribute;
}

Dwarf_Attribute :: struct {
    type: Dwarf_Attribute_Type;
    format: Dwarf_Attribute_Format;
}

parse_abbreviations :: (abbrev_data: [] u8, offset_in: u64) -> Dwarf_Abbreviation_List, success: bool {
    abbreviations: Dwarf_Abbreviation_List;
    offset := cast(s64) offset_in;
    while offset < abbrev_data.count {
        id: u64 = ---;
        success: bool = ---;
        id, offset, success = parse_uleb128(abbrev_data, offset);
        if !success     return .{}, false;
        if id == 0 {
            break;
        }

        tag: u64 = ---;
        tag, offset, success = parse_uleb128(abbrev_data, offset);
        if !success     return .{}, false;

        abbrev: Dwarf_Abbreviation;
        abbrev.tag = xx tag;
        if offset >= abbrev_data.count  return .{}, false;
        abbrev.has_children = (abbrev_data[offset] > 0);
        offset += 1;

        while true {
            type: u64 = ---;
            format: u64 = ---;
            type, offset, success = parse_uleb128(abbrev_data, offset);
            if !success     return .{}, false;

            format, offset, success = parse_uleb128(abbrev_data, offset);
            if !success     return .{}, false;

            if type == 0 && format == 0   break;

            attribute: Dwarf_Attribute;
            attribute.type = xx type;
            attribute.format = xx format;
            // log("Found attribute %\n", attribute);
            array_add(*abbrev.attributes, attribute);
        }

        // log("Abbreviation %: %\n", id, abbrev);

        array_add(*abbreviations.ids, id);
        array_add(*abbreviations.values, abbrev);
    }
    // log("Found % abbreviations\n", abbreviations.ids.count);

    return abbreviations, true;
}

parse_compilation_unit :: (elf: Elf, data: [] u8, abbrevs: Dwarf_Abbreviation_List) -> Compilation_Unit, success: bool {
    offset := 0;
    cu: Compilation_Unit;
    abbrev_id: u64 = ---;
    success: bool = ---;
    abbrev_id, offset, success = parse_uleb128(data, offset);
    if !success     return cu, false;

    abbrev := find_abbrev(abbrevs, abbrev_id);
    if !abbrev  return cu, false;

    if abbrev.tag != .COMPILE_UNIT {
        log_error("Unexpected abbreviation: %\n", <<abbrev);
        return cu, false;
    }

    if !abbrev.has_children {
        log_error("Unexpected compile unit withot children: %\n", <<abbrev);
        return cu, false;
    }

    // log("CU abbrev: %\n", <<abbrev);

    for abbrev.attributes {
        if it.type == {
            case .PRODUCER;
                cu.producer, offset, success = parse_string_attribute(elf, it.format, data, offset);
            case .LANGUAGE;
                value: u64;
                value, offset, success = parse_unsigned_int_attribute(elf, it.format, data, offset);
                if !success     return cu, false;
                range_check_and_store(value, type_info(type_of(cu.language)), *cu.language);
            case .NAME;
                cu.name, offset, success = parse_string_attribute(elf, it.format, data, offset);
                if !success     return cu, false;
            case .STMT_LIST;
                cu.statement_list, offset, success = parse_unsigned_int_attribute(elf, it.format, data, offset);
                if !success     return cu, false;
            case .LOW_PC;
                cu.low_pc, offset, success = parse_unsigned_int_attribute(elf, it.format, data, offset);
                if !success     return cu, false;
            case .HIGH_PC;
                cu.high_pc, offset, success = parse_unsigned_int_attribute(elf, it.format, data, offset);
                if !success     return cu, false;
                if it.format != .ADDR {
                    if !cu.low_pc {
                        log_error("Parsed a relative high_pc before finding a low_pc. That’s technically legal but not yet supported.\n");
                        return cu, false;
                    }
                    cu.high_pc += cu.low_pc;
                }
            case;
                offset, success = skip_attribute(elf, it.format, data, offset);
                if !success     return cu, false;
        }
    }
    done := false;
    while !done {
        done, offset, success = parse_debug_info_entry(elf, data, offset, abbrevs);
        if !success     return cu, false;
    }

    if offset != data.count {
        remainder := array_view(data, offset);
        log_error("Unexpected additional data after parsing the compilation unit. Offset was % of %. Remainder:\n%\n", offset, data.count, remainder);
        return cu, false;
    }

    // log("Compilation unit: %\n", cu);

    return cu, true;
}

parse_debug_info_entry :: (elf: Elf, data: [] u8, offset_in: s64, abbrevs: Dwarf_Abbreviation_List) -> done: bool, offset: s64, success: bool {
    abbrev_id, offset, success := parse_uleb128(data, offset_in);
    if !success     return false, offset, false;

    if abbrev_id == 0   return true, offset, true;

    abbrev := find_abbrev(abbrevs, abbrev_id);
    if !abbrev  return false, offset, false;

    // log("Parsing abbrev: %\n", <<abbrev);

    for abbrev.attributes {
        offset, success = skip_attribute(elf, it.format, data, offset);
        if !success     return false, offset, false;
    }

    if abbrev.has_children {
        // log("Parsing children\n");
        done := false;
        while !done {
            done, offset, success = parse_debug_info_entry(elf, data, offset, abbrevs);
            if !success     return false, offset, false;
        }
        // log("Done parsing children\n");
    }

    return false, offset, true;
}

find_abbrev :: (abbrevs: Dwarf_Abbreviation_List, id: u64) -> *Dwarf_Abbreviation {
    for abbrevs.ids {
        if it == id   {
            return *abbrevs.values[it_index];
        }
    }

    log_error("Could not find abbreviation %\n", id);
    return null;
}

parse_uleb128 :: (data: [] u8, offset_in: s64, $Type := u64 ) -> value: Type, len: int, success: bool {
    value: u64;
    shift := 0;

    offset := offset_in;
    while true {
        if offset == data.count {
            log_error("Unexpected end at offset % while decoding a ULEB128 value\n", offset);
            return 0, 0, false;
        }

        byte := data[offset];
        value |= ((cast(u64) byte & 0x7F) << shift);
        offset += 1;
        if !(byte & 0x80)  break;
        shift += 7;
    }


    result: Type = cast(Type) value;
    return result, offset, true;
}

parse_sleb128 :: (data: [] u8, offset_in: s64) -> value: s64, len: int, success: bool {
    result: s64;
    shift := 0;

    offset := offset_in;
    while true {
        if offset == data.count {
            log_error("Unexpected end at offset % while decoding a ULEB128 value\n", offset);
            return 0, 0, false;
        }

        byte := data[offset];
        result |= ((cast(s64) byte & 0x7F) << shift);
        offset += 1;
        shift += 7;
        if !(byte & 0x80) {
            if shift < size_of(s64) * 8 && (byte & 0x40) {
                // sign extend
                extension := - (1 << shift);
                result |= extension;
            }
            break;
        }
    }

    return result, offset, true;
}

parse_string_attribute :: (elf: Elf, format: Dwarf_Attribute_Format, data: [] u8, offset: s64) -> result: string, offset: s64, success: bool {
    if format == {
        case .STRING;
            str, success := get_c_string_from_data(data, offset);
            if !success return "", offset, false;

            return str, offset + str.count + 1, true;

        case .STRP;
            str_offset, end_offset, success := parse_integer(data, offset, u32);
            if !success     return "", offset, false;

            str: string = ---;
            str, success = get_debug_string(elf, str_offset);
            return str, end_offset, success;

        case;
            log_error("Unsupported string attribute format: %\n", format);
            return "", offset, false;
    }

}

parse_unsigned_int_attribute :: (elf: Elf, format: Dwarf_Attribute_Format, data: [] u8, offset: s64) -> result: u64, offset: s64, success: bool {
    if format == {
        case .REF1; #through;
        case .DATA1;
            result, end_offset, success := parse_integer(data, offset, u8);
            return result, end_offset, success;

        case .REF2; #through;
        case .DATA2;
            result, end_offset, success := parse_integer(data, offset, u16);
            return result, end_offset, success;

        case .REF4; #through;
        case .DATA4;
            result, end_offset, success := parse_integer(data, offset, u32);
            return result, end_offset, success;

        case .REF8; #through;
        case .DATA8;
            result, end_offset, success := parse_integer(data, offset, u64);
            return result, end_offset, success;

        case .REF_UDATA; #through;
        case .UDATA; 
            result, end_offset, success := parse_uleb128(data, offset);
            return result, end_offset, success;

        case .SEC_OFFSET;
            // @ToDo: Depends on whether its dwarf 32 or 64.
            result, end_offset, success := parse_integer(data, offset, u32);
            return result, end_offset, success;

        case .ADDR;
            result, end_offset, success := parse_integer(data, offset, u64);
            return result, end_offset, success;

        case .FLAG;
            result, end_offset, success := parse_integer(data, offset, u8);
            return result, end_offset, success;
        case .FLAG_PRESENT;
            return 1, offset, true;
        
        case;
            log_error("Unsupported data attribute format: %\n", format);
            return 0, offset, false;
    }
}

parse_signed_int_attribute :: (elf: Elf, format: Dwarf_Attribute_Format, data: [] u8, offset: s64) -> result: s64, offset: s64, success: bool {
    if format == {
        case .SDATA; 
            result, end_offset, success := parse_sleb128(data, offset);
            return result, end_offset, success;
        case;
            log_error("Unsupported data attribute format: %\n", format);
            return 0, offset, false;
    }
}

parse_length_block :: (elf: Elf, format: Dwarf_Attribute_Format, data: [] u8, offset_in: s64) -> result: [] u8, offset: s64, success: bool {
    length: u64 = ---;
    offset: s64 = ---;
    success: bool = ---;
    if format == {
        case .BLOCK1;
            length, offset, success = parse_integer(data, offset_in, u8);
        case .BLOCK2;
            length, offset, success = parse_integer(data, offset_in, u16);
        case .BLOCK4;
            length, offset, success = parse_integer(data, offset_in, u32);
        case .EXPRLOC; #through;
        case .BLOCK;
            length, offset, success = parse_uleb128(data, offset_in);
    }

    end := offset + cast (s64) length;
    if end > data.count {
        log_error("Block length went out of bounds: %\n", length);
        return .[], offset, false;
    }

    return array_view(data, offset, xx length), end, true;
}

parse_integer :: (data: [] u8, offset: s64, $T: Type) -> value: T, offset: s64, success: bool {
    end_offset := offset + size_of(T);
    if end_offset > data.count  {
        log_error("Unexpected end of data while parsing %\n", T);
        return 0, offset, false;
    }
    value := <<(cast(*T) (data.data + offset));
    return value, end_offset, true;
}

skip_attribute :: (elf: Elf, format: Dwarf_Attribute_Format, data: [] u8, offset_in: s64) -> offset: s64, success: bool {
    if format == {
        case .STRING; #through;
        case .STRP;
            str, offset, success := parse_string_attribute(elf, format, data, offset_in);
            return offset, success;
        case .DATA1; #through;
        case .DATA2; #through;
        case .DATA4; #through;
        case .DATA8; #through;
        case .UDATA; #through;
        case .REF1; #through;
        case .REF2; #through;
        case .REF4; #through;
        case .REF8; #through;
        case .REF_UDATA; #through;
        case .SEC_OFFSET; #through; 
        case .ADDR; #through;
        case .FLAG; #through;
        case .FLAG_PRESENT;
            value, offset, success := parse_unsigned_int_attribute(elf, format, data, offset_in);
            return offset, success;
        case .SDATA;
            value, offset, success := parse_signed_int_attribute(elf, format, data, offset_in);
            return offset, success;
        case .BLOCK1; #through;
        case .BLOCK2; #through;
        case .BLOCK4; #through;
        case .BLOCK; #through;
        case .EXPRLOC;
            value, offset, success := parse_length_block(elf, format, data, offset_in);
            return offset, success;
        case;
            log_error("Couldn’t skip over unsupported attribute format: %\n", format);
            return offset_in, false;
    }
}

range_check_and_store :: (value: $T, info: *Type_Info_Integer, pointer: *void) -> (success: bool, low: T, high: T) {
	#assert((T == u64) || (T == s64));

	size := info.runtime_size;

	#if T == u64 {
		low, high := unsigned_integer_range_from_size(size);
		if (value < low) || (value > high)  return false, low, high;

		store(pointer, value, size);
		return true, low, high;
	} else {
		low, high := signed_integer_range_from_size(size);
		if (value < low) || (value > high)  return false, low, high;

		store(pointer, value, size);
		return true, low, high;
	}

	store :: (pointer: *void, value: T, size: int) {
		if size == {
			case 1;
			<< cast(*s8)  pointer = xx,no_check value;
			case 2;
			<< cast(*s16) pointer = xx,no_check value;
			case 4;
			<< cast(*s32) pointer = xx,no_check value;
			case 8;
			<< cast(*s64) pointer = xx,no_check value;
			case;
			assert(false);
		}
	}
}

signed_integer_range_from_size :: (size_in_bytes: int) -> (low: s64, high: s64) {
	assert((size_in_bytes == 1) || (size_in_bytes == 2) || (size_in_bytes == 4) || (size_in_bytes == 8));

	high := (1 << (size_in_bytes*8-1)) - 1;
	low  := ~high;

	return low, high;
}

unsigned_integer_range_from_size :: (size_in_bytes: int) -> (low: u64, high: u64) {
	assert((size_in_bytes == 1) || (size_in_bytes == 2) || (size_in_bytes == 4) || (size_in_bytes == 8));

	high: u64 = ---;
	if size_in_bytes == 8 {
		high = cast(u64) 0xffff_ffff_ffff_ffff;  // Hardcode 8 to prevent unpredictable behavior due to platform-specific details. In the future the outcome of << will be language-defined in all cases.
	} else {
		high = cast(u64) (1 << (size_in_bytes*8)) - 1;  // @CompilerBug: Why do we need to cast the 1? That is dumb.
	}

	return 0, high;
}

get_debug_string :: (elf: Elf, offset: u64) -> result: string, success: bool {
    if !elf.debug_str_section                   return "", false;

    if offset >= elf.debug_str_section.size {
        log_error("Debug string offset % is out of bounds\n", offset);
        return "", false;
    }

    section_data := get_section_data(elf, elf.debug_str_section);
    result, success := get_c_string_from_data(section_data, xx offset);
    return result, success;
}

get_c_string_from_data :: (data: [] u8, offset: s64) -> result: string, success: bool {
    str: string = ---;
    str.data = data.data + offset;
    str.count = 0;
    while offset + str.count < data.count && str.data[str.count] != 0 {
        str.count += 1;
    }
    if offset + str.count == data.count {
        log_error("Unexpected end of data while parsing a string at offset %\n", offset);
        return "", false;
    }

    // log("Found string \"%\"\n", str);

    return str, true;
}

#load "dwarf_enums.jai";
#load "line_program.jai";
