typedef long long loff_t;

int fcntl(int fd, int cmd, ... /* arg */);
ssize_t splice(int fd_in, loff_t *off_in, int fd_out,
                      loff_t *off_out, size_t len, unsigned int flags);
ssize_t tee(int fd_in, int fd_out, size_t len, unsigned int flags);

static const int F_DUPFD = 0; /* Duplicate file descriptor.  */
static const int F_GETFD = 1; /* Get file descriptor flags.  */
static const int F_SETFD = 2; /* Set file descriptor flags.  */
static const int F_GETFL = 3; /* Get file status flags.  */
static const int F_SETFL = 4; /* Set file status flags.  */

static const int O_ACCMODE =      0003;
static const int O_RDONLY =         00;
static const int O_WRONLY =         01;
static const int O_RDWR =           02;
static const int O_CREAT =        0100; /* not fcntl */
static const int O_EXCL =         0200; /* not fcntl */
static const int O_NOCTTY =       0400; /* not fcntl */
static const int O_TRUNC =       01000; /* not fcntl */
static const int O_APPEND =      02000;
static const int O_NONBLOCK =    04000;
static const int O_NDELAY = O_NONBLOCK;
static const int O_SYNC =     04010000;
static const int O_FSYNC =      O_SYNC;
static const int O_ASYNC =      020000;
static const int O_NOFOLLOW =  0400000;
static const int O_CLOEXEC =  02000000;

static const int SPLICE_F_MOVE = 1;
static const int SPLICE_F_NONBLOCK = 2;
static const int SPLICE_F_MORE = 4;
static const int SPLICE_F_GIFT = 8;
