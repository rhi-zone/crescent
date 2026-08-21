/* An object carrying a section named .tcov, the way any foreign producer
   would emit one: nothing about the content is special, the name is the whole
   point.  Merged into a link where tcc has already created its own .tcov (i.e.
   under -ftest-coverage), this is the collision 0009 refuses -- and it must be
   refused whichever side of the command line the object appears on. */
        .section .tcov,"aw",@progbits
        .globl tcov_foreign_marker
tcov_foreign_marker:
        .long 0xdeadbeef

        .text
        .globl foreign_value
foreign_value:
        movl $42, %eax
        ret
