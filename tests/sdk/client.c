/* A game in its own process: reads OmniPlay's values and asks for a hill. */
#include "../../sdk/omniplay.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    OmniPlayValues v;
    char js[8192];
    unsigned seq = 0;
    for (int i = 0; i < 40 && !omniplay_values(&v); i++) usleep(50000);
    if (!omniplay_values(&v)) { printf("not running\n"); return 1; }
    int n = omniplay_state_json(js, sizeof js, &seq);
    printf("values %.1f %.0f %.0f %d %d %d json %d %s\n", v.speed_kmh, v.cadence, v.power, v.moving, v.gait, v.kind,
           n, strstr(js, "\"speed_kmh\"") ? "ok" : "bad");
    fflush(stdout);
    omniplay_set_game("C test \"game\"");
    omniplay_set_grade(4.5f);
    omniplay_take_input(1);
    for (int i = 0; i < 30; i++) { omniplay_values(&v); usleep(50000); } /* keep the heartbeat for 1.5 s */
    if (argc > 1 && !strcmp(argv[1], "release")) omniplay_release();
    return 0;
}
