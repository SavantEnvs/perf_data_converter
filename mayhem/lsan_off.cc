// Disables LeakSanitizer at build time for the perf-to-profile backport target (SPEC §6 item 15):
// leaks aren't the class this fleet fuzzes for, and this repo's ASan build otherwise bundles LSan.
extern "C" int __lsan_is_turned_off() { return 1; }
