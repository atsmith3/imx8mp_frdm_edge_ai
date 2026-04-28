/* Hardware loopback wiring NXP FRDM-IMX8MP J18 header (/dev/ttymxc2, UART3):
 *   TX  J18 Pin  8  (UART3_TXD, ECSPI1_MISO, GPIO5_IO8, ball AC20)
 *   RX  J18 Pin 10  (UART3_RXD, ECSPI1_MOSI, GPIO5_IO7, ball AF20)
 *   Connect Pin 8 <-> Pin 10 with a jumper wire.
 * Optional flow-control loopback (not required; test uses CLOCAL):
 *   RTS J18 Pin 11  (UART3_RTS, ECSPI1_SS0,  GPIO5_IO9, ball AE20)
 *   CTS J18 Pin  7  (UART3_CTS, ECSPI1_SCLK, GPIO5_IO6, ball AD20)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/select.h>
#include <errno.h>

#define TIMEOUT_SEC  2
#define TEST_MSG     "LOOPBACK_TEST_OK"
#define TEST_LEN     (sizeof(TEST_MSG) - 1)

static int open_and_configure(const char *dev)
{
    int fd = open(dev, O_RDWR | O_NOCTTY | O_NDELAY);
    if (fd < 0) { perror(dev); return -1; }
    fcntl(fd, F_SETFL, 0);

    struct termios tty;
    memset(&tty, 0, sizeof(tty));
    cfsetispeed(&tty, B115200);
    cfsetospeed(&tty, B115200);
    tty.c_cflag    = CS8 | CREAD | CLOCAL;
    tty.c_iflag    = 0;
    tty.c_oflag    = 0;
    tty.c_lflag    = 0;
    tty.c_cc[VMIN] = 1;
    tty.c_cc[VTIME]= 0;
    if (tcsetattr(fd, TCSAFLUSH, &tty) < 0) { perror("tcsetattr"); close(fd); return -1; }
    return fd;
}

int main(int argc, char *argv[])
{
    const char *dev = (argc > 1) ? argv[1] : "/dev/ttymxc2";

    int fd = open_and_configure(dev);
    if (fd < 0) return 1;

    printf("Device : %s\n", dev);
    printf("TX     : \"%s\" (%zu bytes)\n", TEST_MSG, TEST_LEN);
    fflush(stdout);

    /* flush any stale data */
    tcflush(fd, TCIOFLUSH);

    ssize_t written = write(fd, TEST_MSG, TEST_LEN);
    if (written != (ssize_t)TEST_LEN) {
        fprintf(stderr, "write failed: only %zd of %zu bytes sent\n", written, TEST_LEN);
        close(fd); return 1;
    }

    char rxbuf[64];
    size_t rxlen = 0;

    while (rxlen < TEST_LEN) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv = { .tv_sec = TIMEOUT_SEC, .tv_usec = 0 };

        int ret = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (ret == 0) {
            printf("RX     : timeout after %d s — received %zu/%zu bytes\n",
                   TIMEOUT_SEC, rxlen, TEST_LEN);
            printf("RESULT : FAIL (check jumper between J18 Pin 8 (TX) and Pin 10 (RX))\n");
            close(fd); return 1;
        }
        if (ret < 0) { perror("select"); close(fd); return 1; }

        ssize_t n = read(fd, rxbuf + rxlen, TEST_LEN - rxlen);
        if (n <= 0) { perror("read"); close(fd); return 1; }
        rxlen += (size_t)n;
    }

    rxbuf[rxlen] = '\0';
    printf("RX     : \"%s\" (%zu bytes)\n", rxbuf, rxlen);

    if (rxlen == TEST_LEN && memcmp(rxbuf, TEST_MSG, TEST_LEN) == 0) {
        printf("RESULT : PASS\n");
        close(fd); return 0;
    } else {
        printf("RESULT : FAIL (data mismatch)\n");
        close(fd); return 1;
    }
}
