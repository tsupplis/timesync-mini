#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>


int main(int argc, char ** argv) {
    char * cmd;
    char ** arg; 
    char * path;
    int i;

    cmd="/boot/system/preferences/Time";
    arg=(char**)malloc(3*sizeof(char*));
    arg[0]=cmd;
    arg[1]="--update";
    arg[2]=0;
    path=getenv("PATH");
    path=path?path:":/boot/system/preferences;/bin:/usr/bin";
    while(1) {
        fprintf(stderr,"INF: Execute Time --update\n");
        switch(fork()) {
        case 0:
            setsid();
            close(0);
            close(1);
            close(2);
            fprintf(stderr,"INF: Exec %s %s ...\n",cmd,arg[0]);
            execvp(cmd,arg);
            fprintf(stderr,"ERR: Failed exec ...\n");
        case -1:
            fprintf(stderr,"ERR: Failed fork ...\n");
            break;
        default:
            break;
        }
        fprintf(stderr,"INF: Sleeping 2 minutes ...\n");
        sleep(60);
    }
}
