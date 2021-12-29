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
    

    my_window = create_window(window_width, window_height, "SMASH!");

    window_width, window_height = Simp.get_render_dimensions(my_window);

    Simp.set_render_target(my_window);
    
    my_init_fonts();
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
                
                if should_reinit my_init_fonts();  // Resize the font for the new window size.
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

    button_theme: Button_Theme;  // This will have the default Button_Theme values.
    button_theme.font = button_font;
    button_theme.enable_variable_frame_thickness = true; 
    // 'k' is some resolution-adjusting unit of distance. Right now it is
    // 1/10 of the screen height, so, 108 pixels at 1920x1080.
    k := window_height * .1;

    text_theme: Text_Input_Theme;
    text_theme.font = button_font;
    
    r := get_rect(1*k, 4*k, 5*k, button_font.character_height*1.35);
    server_input.rect = r;
    draw(*server_input.input, r, *text_theme);
    
    r.w = 3*k;
    r.h = button_font.character_height * 2.0;
    r.y -= r.h + 0.2*k;

    button_theme.label_theme.alignment = .Center;
    pressed := button(r, "Connect", *button_theme);

    if pressed {
        log("We should probably connect to %…", get_result(server_input.input));
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

    //
    // Color Picker stuff.
    //
    {
        w := 3 * k;
        h := 4 * k;
        r = get_rect(window_width - w, 0, w, h);
        color_picker_theme := *default_overall_theme.color_picker_theme;
        applied := color_picker(r, *background_color, color_picker_theme);
        if applied {
            log("Applied color: %\n", background_color);
        }
    }

    
    draw_popups();  // This draws Subwindows as well.
    
    Simp.swap_buffers(my_window);
}

my_init_fonts :: () {
    pixel_height := window_height / 24;
    my_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
    assert(my_font != null);

    pixel_height /= 2;
    button_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
    assert(button_font != null);

    pixel_height = window_height / 7;
    title_font = Simp.get_font_at_size("data", "Miama.otf", pixel_height);

    pixel_height = window_height / 30;
    story_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
//    title_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);
}

Font :: Simp.Dynamic_Font;

my_font:     *Font;
button_font: *Font;
title_font:  *Font;
story_font:  *Font;

Simp  :: #import "Simp";
Input :: #import "Input";

#import "Window_Creation";

#import "Basic";
#import "Math";
#import "System";  // For get_path_of_running_executable. @Cleanup.
#import "String";  // For path_strip_filename. @Cleanup.


