SECTIONS
{
	. = 0x80000000;
	_start = .;
	.text : { *(.text) *(.text.*) *(.rodata) *(.rodata.*) }
}
