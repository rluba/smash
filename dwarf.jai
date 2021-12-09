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

Compilation_Unit :: struct {
    producer: string;
    language: u16; // could be a u16, but then our parse function needs to be smarter.
    name: string;
    statement_list: u64;
    low_pc: u64;
    high_pc: u64;
}

parse_debug_info :: (elf: *Elf) -> success: bool {
    if !elf.debug_info_section {
        log_error("This elf does not include a .debug_info section");
        return false;
    }

    if !elf.debug_abbrev_section {
        log_error("This elf does not include a .debug_abbrev section");
        return false;
    }

    debug_info := get_section_data(elf, elf.debug_info_section);
    abbrev := get_section_data(elf, elf.debug_abbrev_section);

    offset := 0;
    while offset < debug_info.count {
        header := cast (*Compliation_Unit_Header_32) (debug_info.data + offset);
        if header.size == 0xffff_ffff {
            log_error("We dont support 64 bit DWARF format yet.");
            return false;
        }
        if header.version != 4 {
            log_error("Compilation unit has unsupported dwarf version: %\n", header.version);
            return false;
        }
        if header.address_size != 8 {
            log_error("Compilation unit has unexpected address_size: %\n", header.address_size);
            return false;
        }

        log("Compilation unit header: %\n", <<header);
        cu_end := offset + header.size + size_of(type_of(header.size));
        if cu_end > debug_info.count {
            log_error("Invalid compilation unit size: %\n", header.size);
            return false;
        }

        abbreviations, success := parse_abbreviations(abbrev, header.debug_abbrev_offset);
        if !success     return false;

        cu: [] u8 = ---;
        cu.data = debug_info.data + offset + size_of(Compliation_Unit_Header_32);
        cu.count = header.size;
        parse_compilation_unit(elf, cu, abbreviations);

        offset = cu_end;
    }

    return true;
}

Dwarf_Abbreviations :: struct {
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
    form: Dwarf_Attribute_Form;
}

parse_abbreviations :: (abbrev_data: [] u8, offset_in: u64) -> Dwarf_Abbreviations, success: bool {
    abbreviations: Dwarf_Abbreviations;
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
            form: u64 = ---;
            type, offset, success = parse_uleb128(abbrev_data, offset);
            if !success     return .{}, false;

            form, offset, success = parse_uleb128(abbrev_data, offset);
            if !success     return .{}, false;

            if type == 0 && form == 0   break;

            attribute: Dwarf_Attribute;
            attribute.type = xx type;
            attribute.form = xx form;
            // log("Found attribute %\n", attribute);
            array_add(*abbrev.attributes, attribute);
        }

        // log("Abbreviation %: %\n", id, abbrev);

        array_add(*abbreviations.ids, id);
        array_add(*abbreviations.values, abbrev);
    }
    log("Found % abbreviations\n", abbreviations.ids.count);

    return abbreviations, true;
}

parse_compilation_unit :: (elf: *Elf, data: [] u8, abbrevs: Dwarf_Abbreviations) -> success: bool {
    offset := 0;
    cu: Compilation_Unit;
    while true {
        abbrev_id: u64 = ---;
        success: bool = ---;
        abbrev_id, offset, success = parse_uleb128(data, offset);
        if !success     return false;

        abbrev: *Dwarf_Abbreviation;
        for abbrevs.ids {
            if it == abbrev_id   {
                abbrev = *abbrevs.values[it_index];
                break;
            }
        }
        if !abbrev {
            log_error("Could not find abbreviation %\n", abbrev_id);
            return false;
        }

        if abbrev.tag != .COMPILE_UNIT {
            log_error("Unexpected abbreviation: %\n", <<abbrev);
            return false;
        }

        log("CU abbrev: %\n", <<abbrev);

        for abbrev.attributes {
            if it.type == {
                case .PRODUCER;
                    cu.producer, offset, success = parse_string_attribute(elf, it.form, data, offset);
                case .LANGUAGE;
                    value: u64;
                    value, offset, success = parse_uint_attribute(elf, it.form, data, offset);
                    if !success     return false;
                    range_check_and_store(value, type_info(type_of(cu.language)), *cu.language);
                case .NAME;
                    cu.name, offset, success = parse_string_attribute(elf, it.form, data, offset);
                    if !success     return false;
                case .STMT_LIST;
                    cu.statement_list, offset, success = parse_uint_attribute(elf, it.form, data, offset);
                    if !success     return false;
                case .LOW_PC;
                    cu.low_pc, offset, success = parse_uint_attribute(elf, it.form, data, offset);
                    if !success     return false;
                case .HIGH_PC;
                    cu.high_pc, offset, success = parse_uint_attribute(elf, it.form, data, offset);
                    if !success     return false;
                case;
                    offset, success = skip_attribute(elf, it.form, data, offset);
                    if !success     return false;
            }
        }
        log("Compilation unit: %\n", cu);
        break; // For now
    }
    return true;
}

parse_uleb128 :: (data: [] u8, offset_in: s64) -> value: u64, len: int, success: bool {
    result: u64;
    shift := 0;

    offset := offset_in;
    while true {
        if offset == data.count {
            log_error("Unexpected end at offset % while decoding a ULEB128 value\n", offset);
            return 0, 0, false;
        }

        byte := data[offset];
        result |= ((cast(u64) byte & 0x7F) << shift);
        offset += 1;
        if !(byte & 0x80)  break;
        shift += 7;
    }

    return result, offset, true;
}

parse_string_attribute :: (elf: *Elf, form: Dwarf_Attribute_Form, data: [] u8, offset: s64) -> result: string, offset: s64, success: bool {
    if form == {
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
            log_error("Unsupported string attribute format: %\n", form);
            return "", offset, false;
    }

}

parse_uint_attribute :: (elf: *Elf, form: Dwarf_Attribute_Form, data: [] u8, offset: s64) -> result: u64, offset: s64, success: bool {
    if form == {
        case .FLAG; #through;
        case .DATA1;
            result, end_offset, success := parse_integer(data, offset, u8);
            return result, end_offset, success;

        case .DATA2;
            result, end_offset, success := parse_integer(data, offset, u16);
            return result, end_offset, success;

        case .DATA4;
            result, end_offset, success := parse_integer(data, offset, u32);
            return result, end_offset, success;

        case .DATA8;
            result, end_offset, success := parse_integer(data, offset, u64);
            return result, end_offset, success;

        case .SEC_OFFSET;
            // @ToDo: Depends on whether its dwarf 32 or 64.
            result, end_offset, success := parse_integer(data, offset, u32);
            return result, end_offset, success;

        case .ADDR;
            result, end_offset, success := parse_integer(data, offset, u64);
            return result, end_offset, success;

        case .FLAG_PRESENT;
            return 1, offset, true;
        
        case;
            log_error("Unsupported data attribute format: %\n", form);
            return 0, offset, false;
    }
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

skip_attribute :: (elf: *Elf, form: Dwarf_Attribute_Form, data: [] u8, offset_in: s64) -> offset: s64, success: bool {
    if form == {
        case .STRING; #through;
        case .STRP;
            str, offset, success := parse_string_attribute(elf, form, data, offset_in);
            return offset, success;
        case .DATA1; #through;
        case .DATA2; #through;
        case .DATA4; #through;
        case .DATA8; #through;
        case .SEC_OFFSET; #through; 
        case .ADDR; #through;
        case .FLAG; #through;
        case .FLAG_PRESENT;
            value, offset, success := parse_uint_attribute(elf, form, data, offset_in);
            return offset, success;
        case;
            log_error("Couldn’t skip over unsupported attribute format: %\n", form);
            return offset_in, false;
    }
}

parse_line_program :: (data: [] u8) {
    log("Line program is % bytes big\n", data.count);
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

get_debug_string :: (elf: *Elf, offset: u64) -> result: string, success: bool {
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

    log("Found string \"%\"\n", str);

    return str, true;
}

#load "dwarf_enums.jai";
