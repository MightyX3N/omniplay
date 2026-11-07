/* C / C++: compile omniplay.c into your game (or link omniplay_client.dll with -DOMNIPLAY_USE_DLL).
 *   gcc main.c ../../omniplay.c -o example        (Windows: x86_64-w64-mingw32-gcc ...) */
#include "../../omniplay.h"
#include <stdio.h>
#ifdef _WIN32
#  include <windows.h>
#  define sleep_ms(n) Sleep(n)
#else
#  include <unistd.h>
#  define sleep_ms(n) usleep((n) * 1000)
#endif

int main(void) {
    omniplay_set_game("C example");
    for (int i = 0; i < 200; i++) {
        OmniPlayValues v;
        if (omniplay_values(&v))
            printf("\r%5.1f km/h  %3.0f rpm  %s W  hill %.1f %%   ", v.speed_kmh, v.cadence,
                   v.power == v.power ? "yes" : "-", v.grade);
        else
            printf("\rOmniPlay isn't running                 ");
        fflush(stdout);
        omniplay_set_grade(i < 100 ? 3.0f : 0.0f / 0.0f); /* 3 % for 10 s, then flat */
        sleep_ms(100);
    }
    omniplay_release();
    printf("\n");
    return 0;
}
