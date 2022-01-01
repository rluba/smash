#import "GetRect";  // Other imports are below, but the point of this example is to use GetRect so this #import goes here.

SCALE :: 1;  // I use this during development to quickly make the window real big.

my_window: Window_Type;
window_width  : s32 = 1280*SCALE;
window_height : s32 = 920*SCALE;

current_time: float64;
last\  _time: float64;

// Data values that we manipulate with the widgets:

server_address: string;

server_input: Text_Input;
command_input: Text_Input;
working_dir_input: Text_Input;
pending_args: [..] string;
pending_working_dir: string;


log_messages: [..] string;
log_scroll_value: float;

main :: () {
    #if OS == .WINDOWS {
        Windows :: #import "Windows";
        Windows.SetProcessDPIAware();

        // Windows is very bad at thread-switching by default unless you do this. Sad.
        Windows.timeBeginPeriod(1);
    }

    // So that we can load our font, set to path of running executable.
    path := path_strip_filename(get_path_of_running_executable());
    set_working_directory(path);

    client_network_init();
    
    my_window = create_window(window_width, window_height, "SMASH!");

    window_width, window_height = Simp.get_render_dimensions(my_window);

    Simp.set_render_target(my_window);
    
    my_init_fonts_and_themes();
    ui_init();

    set_text(*server_input.input, "localhost:8377");

    // @ToDo: Recent servers
    // set_auto_complete(*input_teas.input, auto_complete_teas, null);
    
    quit := false;
    while !quit {
        current_time = get_time();
        dt := cast(float)(current_time - last_time);
        Clamp(*dt, 0, 0.1);
        last_time = current_time;

        Input.update_window_events();

        for Input.get_window_resizes() {
            Simp.update_window(it.window);

            if it.window == my_window {
                should_reinit := (it.width != window_width) || (it.height != window_height);
                
                window_width  = it.width;
                window_height = it.height;
                
                if should_reinit my_init_fonts_and_themes();  // Resize the font for the new window size.
            }
        }
        
        for event: Input.events_this_frame {
            if event.type == .QUIT then quit = true;

            getrect_handle_event(event);

            if event.type == {
              case .KEYBOARD;
                if event.key_pressed && event.key_code == .ESCAPE {
                    active_widget_deactivate_all();
                }
              case .DRAG_AND_DROP_FILES;
                  // @ToDo?
            }
        }

        draw_one_frame(dt);
        
        reset_temporary_storage();
        sleep_milliseconds(10);
    }
}

background_color: Vector3 = .{.157, .157, .157};

draw_one_frame :: (dt: float) {
    // Simp.update_window(my_window);
    Simp.clear_render_target(background_color.x, background_color.y, background_color.z, 1);

    x, y, width, height := get_dimensions(my_window, true);
    ui_per_frame_update(my_window, width, height, current_time);

    while true {
        network_result, success := try_get_next_network_result();
        if !success break;
        // @ToDo: Use details!
        if network_result.type == {
            case .ERROR;
                connection_status = .DISCONNECTED;
                connect_window.open = true;
                array_add(*log_messages, copy_string(network_result.error));
            case .CONNECTED;
                connection_status = .CONNECTED;
                connect_window.open = false;
                array_add(*log_messages, sprint("Connected to %:%", network_result.server.name, network_result.server.port));
                message := New(Message_Init);
                message.version = 1;
                message.work_dir = copy_string(pending_working_dir);
                for pending_args {
                    array_add(*message.args, copy_string(it));
                }
                client_network_send_message(message);
        }
        free_result(network_result);
    }

    status_text: string;
    if #complete connection_status == {
        case .DISCONNECTED;
            status_text = "Disconnected";
        case .CONNECTING;
            status_text = "Connecting…";
        case .CONNECTED;
            status_text = "Connected";
    }

    // @ToDo: Inputs in subwindows don’t work yet in GetRect!
    // {
    //     h := button_font.character_height*1.35;
    //     r := get_rect(20, 620, 4*k, h);
    //     draw(*server_input, r, *input_theme);
    //     r.y -= r.h + 0.2*k;
    //     draw(*command_input, r, *input_theme);
    //     r.y -= r.h + 0.2*k;
    //     draw(*working_dir_input, r, *input_theme);
    //     r.y -= r.h + 0.2*k;
    // }


    if connect_window.open {
        if !connect_window.draw {
            w := 5*k;
            h := 4*k;
            connect_window.rect = get_rect((window_width - w) / 2, (window_height - h) / 2, w, h);
            connect_window.title_text = "Connect";
            connect_window.draw = do_connect_window;
        }

        theme := default_overall_theme.subwindow_theme;

        subwindow_state := add_subwindow(*connect_window, *theme);
    }

    {
        h := button_font.character_height * 2.0;
        r := get_rect(0, window_height - h, 1.2*k, h);

        can_run := (connection_status == .CONNECTED);
        b_theme := ifx can_run then *button_theme else *disabled_button_theme;
        pressed := button(r, "Continue", b_theme, disable_over = !can_run, disable_press = !can_run);
        if pressed {
            send_run_command(.CONTINUE);
        }

        r.x += r.w + 0.2*k;
        pressed = button(r, "Step", b_theme, disable_over = !can_run, disable_press = !can_run);
        if pressed {
            send_run_command(.STEP);
        }
    }
    

    r: = get_rect(0, 0, xx window_width, button_font.character_height*1.2);
    status_theme: Label_Theme;
    status_theme.font = button_font;
    status_theme.text_color = .{.91, .86, .72, 1};
    status_theme.alignment = .Left;
    label(r, status_text, *status_theme);

    {
 	    theme := default_overall_theme.scrollable_region_theme;
 	    theme.region_background.shape.rounding_flags = 0;
 	    
        r.y += r.h;
        r.h = 2*k;
 	    
 	    region, inside := begin_scrollable_region(r, *theme);
 	    
 	    label_height := button_font.character_height * 1.1;
 	    s := inside;
 	    s.y = s.y + s.h - label_height;
 	    s.h = label_height;
 	    s.y += log_scroll_value;
 	    
        log_theme := status_theme;

        for log_messages {
            label(s, it, *log_theme);
            s.y -= floor(label_height * 1.1 + 0.5);
        }
        
 	    end_scrollable_region(region, s.x + s.w, s.y, *log_scroll_value);
    }

    
    //
    // Draw the title:
    //
    label_theme: Label_Theme;
    label_theme.font       = title_font;
    label_theme.text_color = .{.9, .5, .5, 1};
    label_height := title_font.character_height*1.5;
    r = get_rect(0, window_height - label_height, xx window_width, label_height);
    label(r, "SMASH!", *label_theme);

    ////
    //// Color Picker stuff.
    ////
    //{
    //    w := 3 * k;
    //    h := 4 * k;
    //    r = get_rect(window_width - w, 0, w, h);
    //    color_picker_theme := *default_overall_theme.color_picker_theme;
    //    applied := color_picker(r, *background_color, color_picker_theme);
    //    if applied {
    //        log("Applied color: %\n", background_color);
    //    }
    //}

    
    draw_popups();  // This draws Subwindows as well.
    
    Simp.swap_buffers(my_window);
}


connect_window: Subwindow_Info;

connect_input_error: string;

do_connect_window :: (rect: Rect, data: *void) {
    x_pad := 0.5*k;
    y_pad := 0.25*k;
    h := button_font.character_height*1.35;
    r := get_rect(rect.x + x_pad, rect.y + rect.h - y_pad - h, rect.w - 2*x_pad, h);
    draw(*server_input, r, *input_theme);
    
    r.y -= r.h + 0.2*k;
    draw(*command_input, r, *input_theme);
    r.y -= r.h + 0.2*k;
    draw(*working_dir_input, r, *input_theme);
    r.y -= r.h + 0.2*k;

    if connect_input_error {
        error_theme: Label_Theme;
        error_theme.font = button_font;
        error_theme.text_color = .{.91, .34, .25, 1};
        label(r, connect_input_error, *error_theme);
    }

    r.w = 3*k;
    r.h = button_font.character_height * 2.0;
    r.y -= r.h + 0.2*k;

    can_connect := (connection_status == .DISCONNECTED);
    b_theme := ifx can_connect then *button_theme else *disabled_button_theme;
    pressed := button(r, "Connect", b_theme, disable_over = !can_connect, disable_press = !can_connect);
    if pressed {
        parse_and_connect(get_result(server_input));
    }
}

parse_and_connect :: (server: string) {
    command := get_result(command_input);
    if !command {
        set_connect_input_error("Please enter a command!");
        return;
    }

    args: [..] string;
    while command {
        arg: string;
        success: bool;
        arg, command, success = eat_next_argument(command);
        if !success {
            set_connect_input_error("Invalid command (invalid quotes?)");
            return;
        }
        array_add(*args, arg);
    }

    success, name_str, port_str := split_from_left(server, #char ":");
    port := DEFAULT_PORT;
    if success {
        port, success = to_integer(port_str);
        if !success || port > U16_MAX {
            set_connect_input_error(sprint("Invalid port: %", port_str));
            return;
        }
    }

    if !name_str {
        set_connect_input_error(copy_string("Please enter a server name"));
        return;
    }

    set_connect_input_error("");

    for pending_args    free(it);
    array_free(pending_args);
    free(pending_working_dir);

    pending_args = args;
    pending_working_dir = get_result(working_dir_input);

    client_network_connect(name_str, xx port);
}

send_run_command :: (type: Run_Type) {
    message := New(Message_Run);
    message.run_type = type;
    client_network_send_message(message);
}

set_connect_input_error :: (error: string) {
    free(connect_input_error);
    connect_input_error = error;
}

my_init_fonts_and_themes :: () {
    pixel_height := window_height / 24;
    my_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
    assert(my_font != null);

    pixel_height /= 2;
    button_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
    assert(button_font != null);

    pixel_height = window_height / 7;
    title_font = Simp.get_font_at_size("data", "OpenSans-Bold.ttf", pixel_height);

    pixel_height = window_height / 30;
    story_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
//    title_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);

    button_theme.font = button_font;
    button_theme.enable_variable_frame_thickness = true; 
    button_theme.label_theme.alignment = .Center;

    disabled_button_theme = button_theme;
    disabled_button_theme.text_color = .{.32, .32, .32, 1.0};
    disabled_button_theme.frame_color = .{.20, .20, .25, 1.0};

    // 'k' is some resolution-adjusting unit of distance. Right now it is
    // 1/10 of the screen height, so, 108 pixels at 1920x1080.
    k = window_height * .1;

    input_theme.font = button_font;
}

Font :: Simp.Dynamic_Font;

my_font:     *Font;
button_font: *Font;
title_font:  *Font;
story_font:  *Font;

// 'k' is some resolution-adjusting unit of distance. Right now it is
// 1/10 of the screen height, so, 108 pixels at 1920x1080.
k: float;
button_theme: Button_Theme;
disabled_button_theme: Button_Theme;
input_theme: Text_Input_Theme;

eat_next_argument :: (str: string, delimiter := #char " ") -> arg: string, remainder: string, success:bool {
	if !str.count	return "", "", false;

	num_quotes := 0;
	delim_pos := -1;
	for index: 0..str.count-1 {
		if str[index] == #char "\"" {
			num_quotes += 1;
		} else if str[index] == delimiter && num_quotes % 2 == 0 {
			delim_pos = index;
			break;
		}
	}
	arg, remainder: string;
	last := false;
	if delim_pos == -1 {
		arg = str;
		remainder = "";
		last = true;
	} else {
		arg = slice(str, 0, delim_pos);
		remainder = advance(str, delim_pos + 1);
	}

	if num_quotes == 0		return arg, remainder, true;

	if num_quotes % 2 != 0 {
        return "", str, false;
	}

	expected_len := arg.count - num_quotes;
	unquoted_arg := talloc_string(expected_len);
	unquoted_arg.count = 0;
	for index: 0..arg.count-1 {
		if arg[index] != #char "\""  {
            unquoted_arg.data[unquoted_arg.count] = arg[index];
            unquoted_arg.count += 1;
        }
	}
	return unquoted_arg, remainder, true;
}


Simp  :: #import "Simp";
Input :: #import "Input";

#import "Window_Creation";

#import "Basic";
#import "Math";
#import "System";  // For get_path_of_running_executable. @Cleanup.
#import "String";  // For path_strip_filename. @Cleanup.

#load "common.jai";

#load "client_network.jai";
