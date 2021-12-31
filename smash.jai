#import "GetRect";  // Other imports are below, but the point of this example is to use GetRect so this #import goes here.

SCALE :: 1;  // I use this during development to quickly make the window real big.

my_window: Window_Type;
window_width  : s32 = 1280*SCALE;
window_height : s32 = 920*SCALE;

current_time: float64;
last\  _time: float64;

// Data values that we manipulate with the widgets:

server_address: string;

// Text_Input_And_Rect is a temporary situation that we'll probably modify.
Text_Input_And_Rect :: struct {
    input: Text_Input;
    rect:  Rect;
}

server_input: Text_Input_And_Rect;

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

show_connect_window := true;

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
                array_add(*log_messages, copy_string(network_result.error));
            case .CONNECTED;
                connection_status = .CONNECTED;
                array_add(*log_messages, sprint("Connected to %:%", network_result.server.name, network_result.server.port));
                message := New(Message_Init);
                message.version = 1;
                message.work_dir = copy_string("/home/raphael/speckflunder/jai/smash");
                array_add(*message.args, copy_string("./tracee"));
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


    if show_connect_window {
        do_connect_window();
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


connect_input_error: string;

do_connect_window :: () {
    r := get_rect(1*k, 4*k, 5*k, button_font.character_height*1.35);
    server_input.rect = r;
    draw(*server_input.input, r, *text_theme);
    
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
        parse_and_connect(get_result(server_input.input));
    }
}

parse_and_connect :: (server: string) {
    success, name_str, port_str := split_from_left(server, #char ":");
    port := DEFAULT_PORT;
    if success {
        port, success = to_integer(port_str);
        if !success || port > U16_MAX {
            set_connect_input_error(sprint("Invalid port: %", port_str));
            return;
        }
    }

    set_connect_input_error("");
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

    text_theme.font = button_font;
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
text_theme: Text_Input_Theme;

Simp  :: #import "Simp";
Input :: #import "Input";

#import "Window_Creation";

#import "Basic";
#import "Math";
#import "System";  // For get_path_of_running_executable. @Cleanup.
#import "String";  // For path_strip_filename. @Cleanup.

#load "common.jai";

#load "client_network.jai";
