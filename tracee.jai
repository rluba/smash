main :: () {
    print("Before breaking\n");
    breakpoint();
    print("After breaking\n");
    for 0..5 {
        print("Iterating: %\n", it);
    }
    print("DONE\n");
}

#import "Basic";
#import "Debug";
