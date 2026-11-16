#include <stdio.h>
void ExecuteLua(const char *script) {
    FILE *f = fopen("/tmp/bozo_executed_scripts.txt", "w");
    if (f) { fprintf(f, "%s", script); fclose(f); }
}
