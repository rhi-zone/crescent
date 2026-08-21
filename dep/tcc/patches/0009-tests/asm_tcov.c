/* The assembler's half of the same collision: .tcov already exists (tcc created
   it for this translation unit under -ftest-coverage) and a .section directive
   in the input names it.  find_section() reuses by name, so without the
   input-side gate this assembles into tcc's own coverage table. */
int main(void) {
    __asm__(".section .tcov\n\t.long 0x11223344\n\t.text\n");
    return 0;
}
