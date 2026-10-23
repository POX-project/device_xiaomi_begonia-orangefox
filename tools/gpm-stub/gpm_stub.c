#include <gpm.h>
int Gpm_Open(Gpm_Connect *c, int f) { (void)c; (void)f; return -1; }
int Gpm_Close(void) { return 0; }
int Gpm_GetEvent(Gpm_Event *e) { (void)e; return -1; }
char *Gpm_GetLibVersion(int *where) { if (where) *where = 0; return "stub"; }
