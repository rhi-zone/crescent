/* __TINYC__ must be the value upstream tinycc itself computes at the pinned
   commit. Upstream's VERSION there is "0.9.28rc", and upstream's own rule is
   "0.9.XX" -> 9XX, so 928. This is not a free choice: arithmetic comparisons
   like `#if __TINYC__ >= 927` appear in real third-party code, so the number
   has to mean what upstream means by it, not merely parse. */
#if __TINYC__ != 928
#error "__TINYC__ is not 928 (upstream 0.9.28rc)"
#endif

int main(void) { return 0; }
