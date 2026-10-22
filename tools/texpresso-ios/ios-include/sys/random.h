/* iOS's SDK has no <sys/random.h>; MuPDF only wants getentropy() from it. */
#include <stdlib.h>
static inline int getentropy(void *buf, size_t len)
{
  arc4random_buf(buf, len);
  return 0;
}
