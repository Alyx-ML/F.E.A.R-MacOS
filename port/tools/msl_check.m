// Compiles MSL files with the system Metal compiler (the same one the runtime uses).
#import <Metal/Metal.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "no Metal device\n"); return 2; }
        int bad = 0;
        for (int i = 1; i < argc; i++) {
            NSString *src = [NSString stringWithContentsOfFile:@(argv[i]) encoding:NSUTF8StringEncoding error:nil];
            NSError *e = nil;
            id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
            if (!lib || ![lib newFunctionWithName:@"gp_main"]) {
                bad++;
                if (bad <= 5) fprintf(stderr, "FAIL %s:\n%s\n", argv[i], e.localizedDescription.UTF8String);
            }
        }
        printf("%d files, %d failed\n", argc - 1, bad);
        return bad != 0;
    }
}
