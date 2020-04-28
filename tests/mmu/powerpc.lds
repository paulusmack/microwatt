SECTIONS
{
	_start = .;
	. = 0;
	.head : {
		KEEP(*(.head))
	}
	. = 0x3000;
	.text : { *(.text) }
	. = 0x5000;
	.data : { *(.data) }
	.bss : { *(.bss) }
}
