/* Single-threaded feasibility probe; not linked into TeXLocal. */
#include "synctex_parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static synctex_node_p exact(synctex_scanner_p scanner, const char *input, int line) {
    synctex_display_query(scanner, input, line, 0, 0);
    synctex_node_p node;
    while ((node = synctex_scanner_next_result(scanner))) {
        /* Upstream clamps requests beyond the last source line. */
        if (synctex_node_line(node) == line) return node;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    double started = now();
    synctex_scanner_p scanner = synctex_scanner_new_with_output_file(argv[1], NULL, 1);
    double parsed = now() - started;
    if (!scanner) {
        fprintf(stderr, "upstream could not parse %s\n", argv[1]);
        return 1;
    }
    const char *input = NULL;
    for (synctex_node_p node = synctex_scanner_input(scanner); node;
         node = synctex_node_sibling(node)) {
        const char *name = synctex_scanner_get_name(scanner, synctex_node_tag(node));
        printf("I\t%d\t%s\n", synctex_node_tag(node), name);
        /* Rust supplies the exact name recorded in the SyncTeX input. */
        if (synctex_scanner_get_tag(scanner, argv[2]) == synctex_node_tag(node)) input = name;
    }
    if (!input) {
        fprintf(stderr, "upstream has no input %s\n", argv[2]);
        synctex_scanner_free(scanner);
        return 3;
    }
    int lines = atoi(argv[3]);
    started = now();
    int found = 0;
    for (int repeat = 0; repeat < 20; ++repeat)
        for (int line = 1; line <= lines; ++line)
            if (exact(scanner, input, line)) ++found;
    double queried = now() - started;
    printf("T\t%.9f\t%.9f\t%d\n", parsed, queried / (20 * lines), found / 20);
    for (int line = 1; line <= lines; ++line) {
        synctex_node_p node = exact(scanner, input, line);
        if (!node) {
            printf("F\t%d\t0\n", line);
            continue;
        }
        int page = synctex_node_page(node);
        float h = synctex_node_box_visible_h(node);
        float depth = synctex_node_box_visible_depth(node);
        float v = synctex_node_box_visible_v(node) + depth;
        float width = synctex_node_box_visible_width(node);
        float height = synctex_node_box_visible_height(node) + depth;
        printf("F\t%d\t%d\t%.6f\t%.6f\t%.6f\t%.6f", line, page, h, v, width, height);
        synctex_edit_query(scanner, page, h + 5, v - height / 2);
        node = synctex_scanner_next_result(scanner);
        if (node) {
            const char *name = synctex_scanner_get_name(scanner, synctex_node_tag(node));
            printf("\t%s\t%d\n", name ? name : "", synctex_node_line(node));
        } else {
            printf("\t\t0\n");
        }
    }
    synctex_scanner_free(scanner);
    return 0;
}
