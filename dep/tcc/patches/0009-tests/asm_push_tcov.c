/* .pushsection reaches the same reuse-by-name path as .section and must reach
   the same verdict; a fix that only covered .section would leave the rule
   trivially avoidable. */
int main(void) {
    __asm__(".pushsection .tcov\n\t.long 0x11223344\n\t.popsection\n");
    return 0;
}
