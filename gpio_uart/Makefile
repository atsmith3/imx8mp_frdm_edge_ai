CC      ?= aarch64-linux-gnu-gcc
CFLAGS  ?= -Wall -Wextra -O2
TARGET  = uart_loopback_test
SRC     = uart_loopback_test.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f $(TARGET)
