#include <stdint.h>
#include <stdbool.h>

#include "console.h"

static void puthex(unsigned long val)
{
	int i, nibbles = sizeof(val)*2;
	char buf[sizeof(val)*2+1];

	for (i = nibbles-1;  i >= 0;  i--) {
		buf[i] = (val & 0xf) + '0';
		if (buf[i] > '9')
			buf[i] += ('a'-'0'-10);
		val >>= 4;
	}
	putstr(buf, nibbles);
}

#define HELLO_WORLD "Hello World\r\n"

int main(void)
{
	potato_uart_init();

	putstr(HELLO_WORLD, strlen(HELLO_WORLD));
	puthex(0);
	putchar(':');
	puthex(*(unsigned long *)0);
	putstr("\r\n", 2);
	puthex(8);
	putchar(':');
	puthex(*(unsigned long *)8);
	putstr("\r\n", 2);

	puthex(0x40000000);
	putchar(':');
	puthex(*(unsigned long *)0x40000000);
	putstr("\r\n", 2);
	puthex(0x40000008);
	putchar(':');
	puthex(*(unsigned long *)0x40000008);
	putstr("\r\n", 2);

	*(unsigned long *)0x40000000 = 0xabcdef0123456789;
	*(unsigned long *)0x40000008 = 0x9876543210fedcba;

	puthex(0x40000000);
	putchar(':');
	puthex(*(unsigned long *)0x40000000);
	putstr("\r\n", 2);
	puthex(0x40000008);
	putchar(':');
	puthex(*(unsigned long *)0x40000008);
	putstr("\r\n", 2);

	while (1) {
		unsigned char c = getchar();
		putchar(c);
	}
}
