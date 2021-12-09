main :: () {
    print("Before breaking\n");
    breakpoint();
    print("After breaking\n");
    for 0..5 {
        print("Iterating: %\n", it);
    }
    print("crashing…\n");
    // // Crashing by null function pointer.
    // fn: #type () -> int = xx cast(*void) 5;
    // fn();

    // Crashing by memory dereferencing
    // arr: [] int;
    // arr.data = xx 5;
    // arr.count = 1;
    // x := arr[0];
    print("DONE\n");
}

#import "Basic";
#import "Debug";
